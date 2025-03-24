const std = @import("std");
const myzql = @import("myzql");
const config: Config = @import("config.zon");
const http = @import("http.zig");

const Config = struct {
    username: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    host: [4]u8,
    port: u16,
};

const Context = struct {
    allocator: std.mem.Allocator,
    client: *Conn,
};

const Conn = myzql.conn.Conn;
const ResultRow = myzql.result.ResultRow;
const TableTexts = myzql.result.TableTexts;
const TextElemIter = myzql.result.TextElemIter;
const PreparedStatement = myzql.result.PreparedStatement;
const QueryResult = myzql.result.QueryResult;
const BinaryResultRow = myzql.result.BinaryResultRow;
const TableStructs = myzql.result.TableStructs;
const ResultSet = myzql.result.ResultSet;

fn handleHome(_: *http.Request, res: *http.Response, _: *anyopaque) !void {
    try res.writer().print("Home Page\n", .{});
}

fn handleAbout(_: *http.Request, res: *http.Response, _: *anyopaque) !void {
    try res.writer().print("About Page\n", .{});
}

fn handleUserPrefix(req: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *Context = @ptrCast(@alignCast(ctx_ptr));

    try res.writer().print("User Path: {s}\n", .{req.path[6..]});
    if (req.query.get("foo")) |val| {
        try res.writer().print("foo = {s}\n", .{val});
    }

    const User = struct {
        id: c_uint,
        username: []const u8,
        email: []const u8,
        created_at: []const u8,
    };

    const prep_res = try ctx.client.prepare(
        ctx.allocator,
        "SELECT id, username, email, DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s') AS created_at FROM users WHERE username = ?",
    );
    defer prep_res.deinit(ctx.allocator);
    const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

    const query_res = try ctx.client.executeRows(&prep_stmt, .{req.path[6..]});
    const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);
    const rows_iter = rows.iter();
    while (try rows_iter.next()) |row| {
        var person: User = undefined;
        try row.scan(&person);
        try res.writer().print("Hello user id: {d} {s}\n", .{ person.id, person.created_at });
    }
}

fn handlePostApi(_: *http.Request, res: *http.Response, _: *anyopaque) !void {
    const writer = res.writer();
    try writer.print("Received POST /api\n", .{});

    const content_length_str = http.getEnv("CONTENT_LENGTH") orelse "0";
    const content_length = std.fmt.parseInt(usize, content_length_str, 10) catch 0;

    if (content_length > 0) {
        const stdin = std.io.getStdIn().reader();
        var buf: [1024]u8 = undefined;
        const body = buf[0..@min(content_length, buf.len)];
        _ = try stdin.readAll(body);
        try writer.print("Body: {s}\n", .{body});
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //-- Routes
    var route_list = std.ArrayList(http.Route).init(std.heap.page_allocator);
    defer route_list.deinit();

    try route_list.append(.{ .method = .GET, .path = "/", .handler = &handleHome });
    try route_list.append(.{ .method = .GET, .path = "/about", .handler = &handleAbout });
    try route_list.append(.{ .method = .GET, .path = "/user/:username", .handler = &handleUserPrefix });
    try route_list.append(.{ .method = .GET, .path = "/api", .handler = &handlePostApi });

    //-- Database
    var client = try Conn.init(
        allocator,
        &.{
            .username = config.username,
            .password = config.password,
            .database = config.database,
            .address = std.net.Address.initIp4(config.host, config.port),
        },
    );
    defer client.deinit();

    // Connection and Authentication
    try client.ping();

    const method_str = http.getEnv("REQUEST_METHOD") orelse "";
    const path = http.getEnv("PATH_INFO") orelse "/";
    const query_raw = http.getEnv("QUERY_STRING") orelse "";

    const method = http.Method.fromStr(method_str);
    const query = try http.parseQuery(query_raw, allocator);

    var res = http.Response.init(allocator);
    defer res.buffer.deinit();

    var router = http.RouteSet{ .routes = route_list };
    const ctx = Context{ .allocator = allocator, .client = &client };
    var req = http.Request{ .method = method, .path = path, .query = query };

    if (!try router.handle(&req, &res, @constCast(&ctx))) {
        try res.writer().print("404 Not Found: {s}\n", .{path});
    }

    try res.send();
}
