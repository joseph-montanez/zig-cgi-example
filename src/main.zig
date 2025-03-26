const std = @import("std");
const myzql = @import("myzql");
const ztl = @import("ztl");
const config: Config = @import("config.zon");
const http = @import("http.zig");

const Config = struct {
    username: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    host: [:0]const u8,
    port: u16,
};

const Context = struct {
    allocator: std.mem.Allocator,
    db: ?*Conn,
    config: *const Config,

    fn getDb(self: *Context) !*Conn {
        if (self.db) |conn| {
            return conn;
        }

        // Perform DNS lookup
        var address_list = try std.net.getAddressList(self.allocator, self.config.host, self.config.port);
        defer address_list.deinit();

        if (address_list.addrs.len == 0) {
            std.debug.print("Error: Could not resolve hostname '{s}'\n", .{self.config.host});
            return error.DNSNotFound;
        }
        const db_address = address_list.addrs[0];

        const db_config = myzql.config.Config{
            .username = self.config.username,
            .password = self.config.password,
            .database = self.config.database,
            .address = db_address,
        };

        const client_ptr = try self.allocator.create(Conn);
        errdefer self.allocator.destroy(client_ptr);

        client_ptr.* = try Conn.init(self.allocator, &db_config);

        try client_ptr.ping();

        self.db = client_ptr;
        return client_ptr;
    }

    fn deinit(self: *Context) void {
        if (self.db_conn) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
            self.db_conn = null;
        }
    }
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

//-- Middlewares
fn authMiddleware(req: *http.Request, res: *http.Response, ctx: *anyopaque) !bool {
    _ = ctx; // Possibly use the context
    const auth_header = req.headers.get("Authorization");
    if (auth_header) |header| {
        if (std.mem.eql(u8, header, "Bearer mysecrettoken")) {
            return true;
        }
    }

    // Authorization failed
    res.status_code = 401;
    try res.writer().print("Unauthorized\n", .{});
    return false;
}

//-- Route Handlers

fn handleHome(_: *http.Request, res: *http.Response, _: *anyopaque) !void {
    const content = @embedFile("home.html");
    res.content_type = "text/html";
    try res.writer().print(content, .{});
}

fn handleAbout(_: *http.Request, res: *http.Response, _: *anyopaque) !void {
    try res.writer().print("About Page\n", .{});
}

fn handleRedirect(_: *http.Request, res: *http.Response, _: *anyopaque) !void {
    try res.redirect("/about");
}

fn handleTemplate(_: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *Context = @ptrCast(@alignCast(ctx_ptr));

    const Product = struct {
        name: []const u8,
    };

    var template = ztl.Template(void).init(ctx.allocator, {});
    defer template.deinit();

    var compile_error_report = ztl.CompileErrorReport{};

    // The templating language is erb-inspired
    template.compile(
        \\ <h2>Products</h2>
        \\ <% foreach (@products) |product| { -%>
        \\     <%= escape product["name"] %>
        \\ <% } %>
    , .{ .error_report = &compile_error_report }) catch |err| {
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

fn handleUserPrefix(req: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *Context = @ptrCast(@alignCast(ctx_ptr));

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //-- Routes
    var route_list = std.ArrayList(http.Route).init(allocator);
    defer route_list.deinit();

    var no_middleware = std.ArrayList(http.Middleware).init(allocator);
    defer no_middleware.deinit();

    var auth_middleware = std.ArrayList(http.Middleware).init(allocator);
    try auth_middleware.append(&authMiddleware);
    defer auth_middleware.deinit();

    try route_list.append(.{ .method = .GET, .path = "/", .handler = &handleHome, .middleware = no_middleware});
    try route_list.append(.{ .method = .GET, .path = "/about", .handler = &handleAbout, .middleware = no_middleware });
    try route_list.append(.{ .method = .GET, .path = "/template", .handler = &handleTemplate, .middleware = no_middleware });
    try route_list.append(.{ .method = .GET, .path = "/redirect", .handler = &handleRedirect, .middleware = no_middleware });
    try route_list.append(.{ .method = .GET, .path = "/user/:username", .handler = &handleUserPrefix, .middleware = no_middleware });
    try route_list.append(.{ .method = .GET, .path = "/api", .handler = &handlePostApi, .middleware = no_middleware });

    const method_str = http.getEnv("REQUEST_METHOD") orelse "";
    const path = http.getEnv("PATH_INFO") orelse "/";
    const query_raw = http.getEnv("QUERY_STRING") orelse "";

    const method = http.Method.fromStr(method_str);
    const query = try http.parseQuery(query_raw, allocator);
    const headers = try http.parseCgiHeaders(allocator);

    var res = http.Response.init(allocator);
    defer res.deinit();

    var router = http.RouteSet{ .routes = route_list };
    const ctx = Context{ .allocator = allocator, .db = null, .config = &config };
    var req = http.Request{ .method = method, .path = path, .query = query, .headers = headers };

    if (!try router.handle(&req, &res, @constCast(&ctx))) {
        try res.writer().print("404 Not Found: {s}\n", .{path});
    }

    try res.send();
}