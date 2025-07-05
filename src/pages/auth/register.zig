const std = @import("std");
const myzql = @import("myzql");
const ztl = @import("ztl");
const http = @import("../../http.zig");
const main = @import("../../main.zig");

const Conn = myzql.conn.Conn;
const ResultRow = myzql.result.ResultRow;
const TableTexts = myzql.result.TableTexts;
const TextElemIter = myzql.result.TextElemIter;
const PreparedStatement = myzql.result.PreparedStatement;
const QueryResult = myzql.result.QueryResult;
const BinaryResultRow = myzql.result.BinaryResultRow;
const TableStructs = myzql.result.TableStructs;
const ResultSet = myzql.result.ResultSet;

fn checkEmailExists(allocator: std.mem.Allocator, db: *Conn, email: []const u8) !bool {
    const prep_res = try db.prepare(
        allocator,
        "SELECT id FROM users WHERE email = ?",
    );
    defer prep_res.deinit(allocator); // Always deinit prepared statement resources
    const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

    const query_res = try db.executeRows(&prep_stmt, .{email});
    const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);

    // If next() returns a row, it means the email exists.
    return (try rows.iter().next() != null);
}

pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(password);
    var digest: [32]u8 = undefined;
    h.final(&digest);

    const hex_array = std.fmt.bytesToHex(digest[0..], .lower);
    const hex_slice = try allocator.dupe(u8, &hex_array);

    return hex_slice;
}

pub fn handleRegisterGet(_: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *main.Context = @ptrCast(@alignCast(ctx_ptr));

    var session = try ctx.getSession();
    if (session.data) |*d| {
        if (d.*.user_id) |user_id| {
            if (user_id > 0) {
                try res.setHeader("Location", "/dashboard");
                res.status_code = .found;
                return;
            }
        }
    } else {
        std.debug.print("NO SESSION CREATED\n", .{});
    }

    res.content_type = "text/html";

    const ErrorItem = struct {
        key: []const u8,
        message: []const u8,
    };

    const RegisterContext = struct {
        errors: ?[]const ErrorItem = null,
    };

    var template_context = RegisterContext{};

    var error_items = std.ArrayList(ErrorItem).init(ctx.allocator);
    defer error_items.deinit();

    if (session.data) |d| {
        if (d.errors_length) |len| {
            if (len > 0) {
                // Convert the raw error array into a list of ErrorItem structs
                for (d.errors[0..len]) |err_pair| {
                    try error_items.append(.{
                        .key = err_pair[0] orelse "unknown_key",
                        .message = err_pair[1] orelse "An unknown error occurred.",
                    });
                }
                template_context.errors = error_items.items;
                try session.clearErrors();
                session.markModified();
            }
        }
    }

    var template = ztl.Template(RegisterContext).init(ctx.allocator, template_context);
    defer template.deinit();

    var compile_error_report = ztl.CompileErrorReport{};

    // The templating language is erb-inspired
    const content = @embedFile("../../templates/register.html");
    template.compile(content, .{ .error_report = &compile_error_report }) catch |err| {
        try res.writer().print("{}\n", .{compile_error_report});
        return err;
    };

    // Write to any writer, here we're using an ArrayList
    var buf = std.ArrayList(u8).init(ctx.allocator);
    defer buf.deinit();

    var render_error_report = ztl.RenderErrorReport{};

    // The render method is thread-safe.
    template.render(buf.writer(), template_context, .{ .error_report = &render_error_report }) catch |err| {
        defer render_error_report.deinit();
        try res.writer().print("{}\n", .{render_error_report});
        return err;
    };

    try res.writer().print("{s}\n", .{buf.items});
}

pub fn handleRegisterPost(req: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *main.Context = @ptrCast(@alignCast(ctx_ptr));

    // Validation
    var errors = std.StringArrayHashMap([]const u8).init(ctx.allocator);
    defer errors.deinit();

    // Capture inputs from the request body
    const full_name_opt = req.body.get("full_name");
    const email_opt = req.body.get("email");
    const password_opt = req.body.get("password");
    const password_confirm_opt = req.body.get("password_confirm");

    if (full_name_opt) |full_name| {
        if (full_name.len < 1) {
            try errors.put("full_name", "Please enter a name");
        }
    } else {
        try errors.put("full_name", "Full name is required");
    }

    if (email_opt) |email| {
        if (email.len < 1) {
            try errors.put("email", "Please enter an email");
        }
        // Basic email format check (optional but recommended)
        // if (!std.ascii.isEmail(email)) { try errors.put("email", "Invalid email format"); }
    } else {
        try errors.put("email", "Email is required");
    }

    if (password_opt) |password| {
        if (password.len < 1) {
            try errors.put("password", "Please enter a password");
        }
    } else {
        try errors.put("password", "Password is required");
    }

    if (password_confirm_opt) |password_confirm| {
        if (password_confirm.len < 1) {
            try errors.put("password_confirm", "Please confirm the password");
        }
    } else {
        try errors.put("password_confirm", "Password confirmation is required");
    }

    if (password_opt) |password| {
        if (password_confirm_opt) |password_confirm| {
            if (password.len > 0 and password_confirm.len > 0) {
                if (!std.mem.eql(u8, password, password_confirm)) {
                    try errors.put("password_confirm", "Passwords do not match");
                }
            }
        }
    }

    if (errors.count() == 0) {
        // We can safely unwrap these now as the previous checks would have added errors
        // if they were missing or empty.
        const email = email_opt.?;

        const db = try ctx.getDb(); // Connect to DB only if necessary

        if (try checkEmailExists(ctx.allocator, db, email)) {
            try errors.put("email", "This email is already registered.");
        }
    }

    if (errors.count() > 0) {
        var session = try ctx.getSession();

        const data_ptr: *main.SessionData = try session.getData();

        // Clean up existing data
        if (data_ptr.errors_length) |i| {
            if (data_ptr.errors[i][0]) |s| { // <--- Safe to free if not null
                ctx.allocator.free(s);
            }
            if (data_ptr.errors[i][1]) |s| { // <--- Safe to free if not null
                ctx.allocator.free(s);
            }
        }
        data_ptr.errors_length = 0; // Reset the count since we're about to fill it again

        var i: usize = 0;
        var iterator = errors.iterator();
        while (iterator.next()) |entry| {
            // Bounds check: Ensure we don't exceed the embedded array size
            if (i >= data_ptr.errors.len) { // data.errors.len is 30
                std.log.warn("Session error array limit ({}) reached. Ignoring further errors.", .{data_ptr.errors.len});
                break;
            }

            // Get the actual slices by dereferencing the pointers from the iterator entry
            const key_slice = entry.key_ptr.*;
            const value_slice = entry.value_ptr.*;

            data_ptr.errors[i][0] = try ctx.allocator.dupe(u8, key_slice);

            data_ptr.errors[i][1] = try ctx.allocator.dupe(u8, value_slice);

            i += 1;
        }
        data_ptr.errors_length = @intCast(i); // Store the actual number of errors.
        session.markModified();

        res.status_code = .found;
        try res.setHeader("Location", "/auth/register");

        return;
    }

    // Database Connection
    const db = try ctx.getDb();

    const email = email_opt.?;
    const password = password_opt.?;

    const hashed_password = try hashPassword(ctx.allocator, password);
    defer ctx.allocator.free(hashed_password);

    const insert_sql = "INSERT INTO users (username, email, password_hash, role, created_at) " ++
        "VALUES (?, ?, ?, ?, NOW())";

    const prep_insert_res = try db.prepare(ctx.allocator, insert_sql);
    defer prep_insert_res.deinit(ctx.allocator);
    const prep_insert_stmt: PreparedStatement = try prep_insert_res.expect(.stmt);

    const user_role = "user";

    const insert_result = try db.execute(&prep_insert_stmt, .{
        email,
        email,
        hashed_password,
        user_role,
    });

    switch (insert_result) {
        .ok => |ok| {
            const new_user_id = ok.last_insert_id;
            std.debug.print("User registered successfully: {s} ID: {d}\n", .{ email, new_user_id });

            var session = try ctx.getSession();
            const data_ptr = try session.getData();
            data_ptr.user_id = new_user_id;
            data_ptr.username = try ctx.allocator.dupe(u8, email);
            session.markModified();

            res.status_code = .found;
            try res.setHeader("Location", "/dashboard");
        },
        .err => |err| {
            std.log.err("Database error during registration: {s}", .{err.error_message});

            var session = try ctx.getSession();
            try session.setError("form", "Could not register account. Please try again later.");
            res.status_code = .found;
            try res.setHeader("Location", "/auth/register");
        },
    }
}
