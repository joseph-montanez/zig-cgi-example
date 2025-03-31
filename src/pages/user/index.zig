const std = @import("std");

// Third Party
const myzql = @import("myzql");
const Conn = myzql.conn.Conn;
const ResultRow = myzql.result.ResultRow;
const TableTexts = myzql.result.TableTexts;
const TextElemIter = myzql.result.TextElemIter;
const PreparedStatement = myzql.result.PreparedStatement;
const QueryResult = myzql.result.QueryResult;
const BinaryResultRow = myzql.result.BinaryResultRow;
const TableStructs = myzql.result.TableStructs;
const ResultSet = myzql.result.ResultSet;

const http = @import("../../http.zig");
const main = @import("../../main.zig");

pub fn handleUserPrefix(req: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *main.Context = @ptrCast(@alignCast(ctx_ptr));

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

        // Database Connection
        const db = try ctx.getDb();
        const prep_res = try db.prepare(allocator,
            "SELECT id, username, email, DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s') AS created_at FROM users WHERE username = ?",
        );
        defer prep_res.deinit(allocator);
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