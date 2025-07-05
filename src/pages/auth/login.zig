const std = @import("std");
const myzql = @import("myzql");
const ztl = @import("ztl");
const http = @import("../../http.zig");
const main = @import("../../main.zig");

// Import the password hashing function from your register logic.
// If it's in a different file, adjust the path.
const hashPassword = @import("./register.zig").hashPassword;

// Type aliases for convenience
const Conn = myzql.conn.Conn;
const PreparedStatement = myzql.result.PreparedStatement;
const ResultSet = myzql.result.ResultSet;
const BinaryResultRow = myzql.result.BinaryResultRow;

// A struct to hold the essential user data for authentication.
const UserAuthData = struct {
    id: u64,
    password_hash: [64]u8,
};

// Custom error for when a user isn't found in the database.
const UserError = error{
    UserNotFound,
};

/// Fetches a user's ID and hashed password from the database by their email.
/// Returns UserError.UserNotFound if no user with that email exists.
fn fetchUserByEmail(allocator: std.mem.Allocator, db: *Conn, email: []const u8) !UserAuthData {
    const prep_res = try db.prepare(
        allocator,
        "SELECT id, password_hash FROM users WHERE email = ? LIMIT 1",
    );
    defer prep_res.deinit(allocator);
    const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

    const query_res = try db.executeRows(&prep_stmt, .{email});
    const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);

    if (try rows.iter().next()) |row| {
        const RowStruct = struct {
            id: u64,
            // The field is named `password_hash`
            password_hash: []const u8,
        };

        var result_row: RowStruct = undefined;

        try row.scan(&result_row);

        // CORRECTED: Use the correct field name `password_hash`
        if (result_row.password_hash.len != 64) {
            std.log.err("User {s} has an invalid password hash length in DB: expected 64, got {d}", .{
                email,
                result_row.password_hash.len,
            });
            return error.InvalidHashLength;
        }

        var hash_array: [64]u8 = undefined;
        // CORRECTED: Use the correct field name `password_hash` here too
        @memcpy(&hash_array, result_row.password_hash);

        return UserAuthData{
            .id = result_row.id,
            .password_hash = hash_array,
        };
    } else {
        return UserError.UserNotFound;
    }
}

/// Handles GET requests to /auth/login.
/// Renders the login page.
pub fn handleLoginGet(_: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *main.Context = @ptrCast(@alignCast(ctx_ptr));
    var session = try ctx.getSession();

    // If user is already logged in, redirect them to the dashboard.
    if (session.data) |d| {
        if (d.user_id) |user_id| {
            if (user_id > 0) {
                try res.setHeader("Location", "/dashboard");
                res.status_code = .found;
                return;
            }
        }
    }

    // Define a context for the template to pass errors.
    const LoginContext = struct {
        // We will store a general error message with the key "form"
        form_error: ?[]const u8 = null,
    };
    var template_context = LoginContext{};

    // Check session for errors left by a failed POST attempt.
    if (session.data) |d| {
        if (d.errors_length) |len| {
            if (len > 0) {
                // Find the error with the key "form".
                for (d.errors[0..len]) |err_pair| {
                    if (std.mem.eql(u8, err_pair[0].?, "form")) {
                        template_context.form_error = err_pair[1];
                        break;
                    }
                }
                // Clear errors from session after displaying them.
                try session.clearErrors();
                session.markModified();
            }
        }
    }

    res.content_type = "text/html";

    var template = ztl.Template(LoginContext).init(ctx.allocator, template_context);
    defer template.deinit();

    var compile_error_report = ztl.CompileErrorReport{};
    const content = @embedFile("../../templates/login.html");
    template.compile(content, .{ .error_report = &compile_error_report }) catch |err| {
        try res.writer().print("{}\n", .{compile_error_report});
        return err;
    };

    var buf = std.ArrayList(u8).init(ctx.allocator);
    defer buf.deinit();

    var render_error_report = ztl.RenderErrorReport{};
    template.render(buf.writer(), template_context, .{ .error_report = &render_error_report }) catch |err| {
        defer render_error_report.deinit();
        try res.writer().print("{}\n", .{render_error_report});
        return err;
    };

    try res.writer().print("{s}", .{buf.items});
}

/// Handles POST requests from the login form.
/// Processes credentials and logs the user in.
pub fn handleLoginPost(req: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *main.Context = @ptrCast(@alignCast(ctx_ptr));
    var session = try ctx.getSession();

    const email_opt = req.body.get("email");
    const password_opt = req.body.get("password");

    // Basic validation
    if (email_opt == null or password_opt == null or email_opt.?.len == 0 or password_opt.?.len == 0) {
        try session.setError("form", "Email and password are required.");
        res.status_code = .found;
        try res.setHeader("Location", "/auth/login");
        return;
    }

    const email = email_opt.?;
    const password = password_opt.?;

    const db = try ctx.getDb();

    const hashed_password_slice = try hashPassword(ctx.allocator, password);
    defer ctx.allocator.free(hashed_password_slice);

    var hashed_password_array: [64]u8 = undefined;
    if (hashed_password_slice.len != 64) {
        // This case should ideally not happen if hashPassword is correct, but it's safe to check.
        return error.HashingFailed;
    }
    @memcpy(&hashed_password_array, hashed_password_slice);

    // Fetch the user from the database.
    const user_auth_data = fetchUserByEmail(ctx.allocator, db, email) catch |err| {
        // If user is not found, or any other DB error occurs, return a generic error.
        // This prevents attackers from knowing which emails are registered.
        if (err == error.UserNotFound) {
            std.debug.print("Login attempt failed for non-existent email: {s}\n", .{email});
        } else {
            std.debug.print("Database error during login for email {s}: {any}\n", .{ email, err });
        }
        try session.setError("form", "Invalid email or password.");
        res.status_code = .found;
        try res.setHeader("Location", "/auth/login");
        return;
    };

    // Compare the hashes. Use a constant-time comparison to prevent timing attacks.
    if (!std.crypto.timing_safe.eql([64]u8, hashed_password_array, user_auth_data.password_hash)) {
        // Passwords do not match.
        std.debug.print("Login attempt failed for user {s} due to incorrect password.\n", .{email});
        try session.setError("form", "Invalid email or password.");
        res.status_code = .found;
        try res.setHeader("Location", "/auth/login");
        return;
    }

    // --- Login Successful ---
    std.debug.print("User {s} logged in successfully.\n", .{email});

    const data_ptr = try session.getData();

    // Clear any old errors and set new session data.
    try session.clearErrors();
    data_ptr.user_id = user_auth_data.id;
    // Free old username if it exists before assigning new one.
    if (data_ptr.username) |old_name| ctx.allocator.free(old_name);
    data_ptr.username = try ctx.allocator.dupe(u8, email);

    session.markModified();

    // Redirect to the dashboard.
    res.status_code = .found;
    try res.setHeader("Location", "/dashboard");
}
