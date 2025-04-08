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
const ztl = @import("ztl");

const http = @import("http.zig");
const session = @import("session.zig");
// Pages
const register = @import("pages/auth/register.zig");
const userIndex = @import("pages/user/index.zig");

// Configuration
const buildConfig = @cImport({
    @cInclude("config.h");
});

pub const Config = struct {
    username: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    host: [:0]const u8,
    port: u16,
};

const config: Config = switch (buildConfig.DEPLOYMENT) {
    1 => @import("config.prod.zon"), // Matches prod = 1
    //2 => @import("config.dev.zon"),   // Matches dev = 2
    //3 => @import("config.stage.zon"), // Matches stage = 3
    0 => @import("config.local.zon"), // Matches local = 0
    else => {
        @compileError("Unknown integer value for DEPLOYMENT in config.h");
        // Or default: @import("config.default.zon"),
    },
};

pub const SessionData = struct {
    user_id: ?u64,
    errors_length: ?u16,
    errors: [30][2][]const u8,
};

pub const ContextError = error{
    SessionNotInitialized, // If middleware didn't run or failed silently
    DBConnectionFailed,
    DNSNotFound, // From getDb
    // Add other context-specific errors if needed
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    db: ?*Conn,
    config: *const Config,
    session: ?*session.Session(SessionData) = null,

    pub fn getDb(self: *Context) !*Conn {
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

    pub fn getSession(self: *Context) !*session.Session(SessionData) {
        // Assumes middleware has successfully run and populated self.session
        return self.session orelse ContextError.SessionNotInitialized;
    }

    pub fn saveSession(self: *Context) !void {
        if (self.session) |s| {
            std.debug.print("Trying to save session\n", .{});
            try s.save();
        }
    }

    pub fn deinit(self: *const Context) void {
        if (self.db) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        if (self.session) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
    }
};

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
    res.status_code = .unauthorized;
    try res.writer().print("Unauthorized\n", .{});
    return false;
}

fn sessionPreflight(req: *const http.Request, _: *http.Response, ctx_ptr: *anyopaque) !bool {
    const ctx: *Context = @ptrCast(@alignCast(ctx_ptr));

    // If session already loaded (e.g., by another middleware), do nothing
    if (ctx.session != null) {
        std.debug.print("Session already created\n", .{});
        return true;
    }

    var loaded_session: ?*session.Session(SessionData) = null;
    const allocator = ctx.allocator;

    // Ensure cleanup if subsequent steps fail after potential allocation
    errdefer if (loaded_session) |s| {
        s.deinit();
        allocator.destroy(s);
    };

    if (req.cookies.get(session.SESSION_COOKIE_NAME)) |session_id_from_cookie| {
        const load_result = session.Session(SessionData).load(allocator, session_id_from_cookie);

        if (load_result) |maybe_session| {
            // Success path
            loaded_session = maybe_session;
            if (loaded_session) |s| {
                std.debug.print("Middleware loaded session: {s}\n", .{s.id});
            } else {
                std.debug.print("Middleware: Load returned null (e.g., file not found), will create new.\n", .{});
            }
        } else |err| {
            switch (err) {
                error.SessionFileOpenFailed, error.SessionFileReadFailed, error.SessionPathAllocationFailed, error.SessionDataAllocationFailed => {
                    std.debug.print("Non-critical session load error ({s}), proceeding to create new. Err: {any}\n", .{ session_id_from_cookie, err });
                },
                else => return err,
            }
        }
    }

    if (loaded_session == null) {
        loaded_session = try session.Session(SessionData).createNew(allocator);
        std.debug.print("Middleware created new session: {s}\n", .{loaded_session.?.id});
    }

    ctx.session = loaded_session;

    return true;
}

fn sessionPostflight(_: *const http.Request, res: *http.Response, ctx_ptr: *anyopaque) !bool {
    const ctx: *Context = @ptrCast(@alignCast(ctx_ptr));
    const s = try ctx.getSession();
    if (s.is_new) {
        std.debug.print("DEBUG: Cookie Name: {s}\n", .{session.SESSION_COOKIE_NAME});
        std.debug.print("DEBUG: Session ID: {s}\n", .{s.id});
        const cookie_str = try std.fmt.allocPrint(
            ctx.allocator,
            "{s} = {s}; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400",
            .{ session.SESSION_COOKIE_NAME, s.id },
        );
        defer ctx.allocator.free(cookie_str);

        try res.setHeader("Set-Cookie", cookie_str);
    } else {
        std.debug.print("SESSION IS NO NEW, NOT USING SET-COOKIE!!!!\n", .{});
    }

    //-- Save session - already checks if present / modified
    try ctx.saveSession();

    std.debug.print("Session written - Post Flight Complete!\n", .{});

    return true;
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

    var session_preflights = std.ArrayList(http.Flight).init(allocator);
    try session_preflights.append(&sessionPreflight);
    defer session_preflights.deinit();

    var session_postflights = std.ArrayList(http.Flight).init(allocator);
    try session_postflights.append(&sessionPostflight);
    defer session_postflights.deinit();

    var auth_flights = std.ArrayList(http.Flight).init(allocator);
    try auth_flights.append(&sessionPreflight);
    try auth_flights.append(&authMiddleware);
    defer auth_flights.deinit();

    try route_list.append(.{ .method = .GET, .path = "/", .handler = &handleHome });
    try route_list.append(.{ .method = .GET, .path = "/about", .handler = &handleAbout });
    try route_list.append(.{ .method = .GET, .path = "/template", .handler = &handleTemplate });
    try route_list.append(.{ .method = .GET, .path = "/redirect", .handler = &handleRedirect });
    try route_list.append(.{ .method = .GET, .path = "/user/:username", .handler = &userIndex.handleUserPrefix });
    try route_list.append(.{ .method = .GET, .path = "/api", .handler = &handlePostApi });
    try route_list.append(.{
        .method = .GET,
        .path = "/auth/register",
        .handler = &register.handleRegisterGet,
        .preFlights = session_preflights,
        .postFlights = session_postflights,
    });
    try route_list.append(.{
        .method = .POST,
        .path = "/auth/register",
        .handler = &register.handleRegisterPost,
        .preFlights = session_preflights,
        .postFlights = session_postflights,
    });

    const method_str = http.getEnv("REQUEST_METHOD") orelse "";
    const path = http.getEnv("PATH_INFO") orelse "/";
    const query_raw = http.getEnv("QUERY_STRING") orelse "";
    const content_type = http.getEnv("CONTENT_TYPE") orelse "";
    const content_length_str = http.getEnv("CONTENT_LENGTH") orelse "0";
    const content_length = try std.fmt.parseInt(usize, content_length_str, 10);

    const method: std.http.Method = @enumFromInt(std.http.Method.parse(method_str));
    const query = try http.parseQuery(query_raw, allocator);
    const headers = try http.parseCgiHeaders(allocator);
    var cookies = std.StringHashMap([]const u8).init(allocator);
    defer cookies.deinit();
    const cookie_headers_result = headers.getAll("Cookie");
    if (cookie_headers_result) |cookie_headers| {
        defer cookie_headers.deinit();

        for (cookie_headers.items) |cookie_header| {
            try http.parseCookie(&cookies, cookie_header);
        }
    } else |err| {
        std.debug.print("Could not get cookie headers: {any}\n", .{err});
    }

    //-- Parse POST - application/x-www-form-urlencoded
    var body = std.StringHashMap([]const u8).init(allocator);
    defer body.deinit();

    if (method == .POST and content_length > 0 and std.ascii.startsWithIgnoreCase(content_type, "application/x-www-form-urlencoded")) {
        const body_buffer = try allocator.alloc(u8, content_length);
        defer allocator.free(body_buffer);

        const stdin = std.io.getStdIn().reader();
        _ = try stdin.readAll(body_buffer);

        body.deinit(); // Clean up previous StringHashMap

        body = try http.parseQuery(body_buffer, allocator);
    }

    var res = http.Response.init(allocator);
    defer res.deinit();

    var router = http.RouteSet{ .routes = route_list };
    const ctx = Context{ .allocator = gpa_allocator, .db = null, .config = &config };
    defer ctx.deinit();
    var req = http.Request{ .method = method, .path = path, .query = query, .headers = headers, .cookies = cookies, .body = body };

    if (!try router.handle(&req, &res, @constCast(&ctx))) {
        try res.writer().print("404 Not Found: {s}\n", .{path});
    }

    std.debug.print("Response Completed, sending now\n", .{});

    try res.send();
}
