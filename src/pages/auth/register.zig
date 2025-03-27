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

pub fn handleRegisterGet(_: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *main.Context = @ptrCast(@alignCast(ctx_ptr));

    res.content_type = "text/html";

    const Product = struct {
        name: []const u8,
    };

    var template = ztl.Template(void).init(ctx.allocator, {});
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
    template.render(buf.writer(), .{ .products = [_]Product{
        .{ .name = "Keemun" },
        .{ .name = "Silver Needle" },
    } }, .{ .error_report = &render_error_report }) catch |err| {
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

    if (req.body.get("full_name")) |full_name| {
        if (full_name.len < 1) {
            try errors.put("full_name", "Please enter a name");
        }
    }
    if (req.body.get("email")) |email| {
        if (email.len < 1) {
            try errors.put("email", "Please enter an email");
        }
    }
    if (req.body.get("password")) |password| {
        if (password.len < 1) {
            try errors.put("password", "Please enter a password");
        }
    }
    if (req.body.get("password_confirm")) |password_confirm| {
        if (password_confirm.len < 1) {
            try errors.put("password_confirm", "Please confirm the password");
        }
    }
    if (req.body.get("password")) |password| {
        if (req.body.get("password_confirm")) |password_confirm| {
            if (std.mem.eql(u8, password, password_confirm)) {
                try errors.put("password_confirm", "Passwords do not match");
            }
        }
    }

    // Database Connection
    const db = try ctx.getDb();

    if (req.query.get("username")) |username| {
        try res.writer().print("User Path: {s}\n", .{username});
        if (req.query.get("foo")) |val| {
            try res.writer().print("foo = {s}\n", .{val});
        } else {
            try res.writer().print("`foo` parameter not found\n", .{});
        }

        const User = struct {
            id: c_uint,
            username: []const u8,
            email: []const u8,
            created_at: []const u8,
        };

        const prep_res = try db.prepare(
            ctx.allocator,
            "SELECT id, username, email, DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s') AS created_at FROM users WHERE username = ?",
        );
        defer prep_res.deinit(ctx.allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

        const query_res = try db.executeRows(&prep_stmt, .{username});
        const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);
        const rows_iter = rows.iter();
        while (try rows_iter.next()) |row| {
            var user: User = undefined;
            try row.scan(&user);
            try res.writer().print("Hello user id: {d} {s}\n", .{ user.id, user.created_at });
        }
    } else {
        try res.writer().print("No username specified\n", .{});
    }
}