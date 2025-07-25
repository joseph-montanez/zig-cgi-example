const std = @import("std");
const myzql = @import("myzql");
const cgi = @import("cgi.zig");

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Header),

    pub fn init(allocator: std.mem.Allocator) Headers {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(Header).init(allocator),
        };
    }

    pub fn deinit(self: *Headers) void {
        for (self.items.items) |header| {
            self.allocator.free(header.key);
            self.allocator.free(header.value);
        }
        self.items.deinit();
    }

    pub fn add(self: *Headers, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value); // Must free value if append fails

        const new_header = Header{
            .key = owned_key,
            .value = owned_value,
        };

        try self.items.append(new_header);
    }

    pub fn get(self: Headers, key: []const u8) ?[]const u8 {
        for (self.items.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.key, key)) {
                return header.value;
            }
        }
        return null;
    }

    pub fn getAll(self: Headers, key: []const u8) !std.ArrayList([]const u8) {
        var results = std.ArrayList([]const u8).init(self.allocator);
        errdefer results.deinit(); // Ensure results list is cleaned up on error

        for (self.items.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.key, key)) {
                try results.append(header.value);
            }
        }
        return results;
    }

    pub fn contains(self: Headers, key: []const u8) bool {
        for (self.items.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.key, key)) {
                return true;
            }
        }
        return false;
    }
};

pub const Request = struct {
    method: std.http.Method,
    path: []const u8,
    headers: Headers,
    cookies: std.StringHashMap([]const u8),
    query: std.StringHashMap([]const u8),
    body: std.StringHashMap([]const u8),
};

pub const Response = struct {
    status_code: std.http.Status = std.http.Status.ok,
    content_type: []const u8 = "text/plain",
    headers: Headers,
    buffer: std.ArrayList(u8),
    dest_writer: std.io.AnyWriter,

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .headers = Headers.init(allocator),
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.buffer.deinit();
    }

    pub fn writer(self: *Response) @TypeOf(self.buffer.writer()) {
        return self.buffer.writer();
    }

    pub fn setHeader(self: *Response, key: []const u8, value: []const u8) !void {
        return try self.headers.add(key, value);
    }

    pub fn redirect(self: *Response, location: []const u8) !void {
        try self.redirectWithCode(location, .temporary_redirect);
    }

    pub fn redirectWithCode(self: *Response, location: []const u8, status_code: std.http.Status) !void {
        self.status_code = status_code;
        try self.setHeader("Location", location);
    }

    pub fn send(self: *Response) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Status: {d} \r\n", .{@intFromEnum(self.status_code)});

        for (self.headers.items.items) |header| {
            try stdout.print("{s}: {s}\r\n", .{ header.key, header.value });
        }
        try stdout.print("Zig: 0.14.0\r\n", .{});
        try stdout.print("Content-Type: {s}\r\n", .{self.content_type});

        try stdout.print("\r\n", .{});

        try stdout.writeAll(self.buffer.items);
    }
};

pub const Flight = *const fn (*Request, *Response, *anyopaque) anyerror!bool;

pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: *const fn (*Request, *Response, *anyopaque) anyerror!void,
    preFlights: ?std.ArrayList(Flight) = null,
    postFlights: ?std.ArrayList(Flight) = null,
};

pub const RouteSet = struct {
    routes: std.ArrayList(Route),

    pub fn handle(self: *RouteSet, req: *Request, res: *Response, ctx: *anyopaque) !bool {
        for (self.routes.items) |route| {
            var req_segments = std.ArrayList([]const u8).init(std.heap.page_allocator);
            defer req_segments.deinit();
            var route_segments = std.ArrayList([]const u8).init(std.heap.page_allocator);
            defer route_segments.deinit();

            var req_iter = std.mem.tokenizeSequence(u8, req.path, "/");
            while (req_iter.next()) |segment| {
                try req_segments.append(segment);
            }

            var route_iter = std.mem.tokenizeSequence(u8, route.path, "/");
            while (route_iter.next()) |segment| {
                try route_segments.append(segment);
            }

            if (req_segments.items.len != route_segments.items.len) {
                continue; // Different number of segments, can't match
            }

            var is_match = true;
            for (req_segments.items, 0..) |req_seg, i| {
                const route_seg = route_segments.items[i];

                if (std.mem.startsWith(u8, route_seg, ":")) {
                    // Parameter segment.  Extract parameter name.
                    const param_name = route_seg[1..]; // Remove the ':'
                    try req.query.put(param_name, req_seg); // Add to query params
                } else if (!std.mem.eql(u8, req_seg, route_seg)) {
                    is_match = false; // Segments don't match, and it's not a parameter
                    break;
                }
            }

            if (is_match and route.method == req.method) {
                if (route.preFlights) |preFlights| {
                    for (preFlights.items) |flight| {
                        if (!(try flight(req, res, ctx))) {
                            return true;
                        }
                    }
                }

                try route.handler(req, res, ctx);

                if (route.postFlights) |postFlights| {
                    for (postFlights.items) |flight| {
                        if (!(try flight(req, res, ctx))) {
                            return true;
                        }
                    }
                }

                return true;
            }
        }
        return false;
    }
};

pub fn getEnv(key: []const u8) ?[]const u8 {
    for (std.os.environ) |entry| {
        const line = std.mem.span(entry);
        if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == '=') {
            return line[(key.len + 1)..];
        }
    }
    return null;
}

pub fn urlDecode(src: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result = try allocator.alloc(u8, src.len);
    var i: usize = 0;
    var j: usize = 0;

    while (i < src.len) {
        if (src[i] == '%') {
            if (i + 2 < src.len) {
                const hi = std.fmt.charToDigit(src[i + 1], 16) catch break;
                const lo = std.fmt.charToDigit(src[i + 2], 16) catch break;
                result[j] = @intCast((hi << 4) | lo);
                i += 3;
                j += 1;
            } else break;
        } else if (src[i] == '+') {
            result[j] = ' ';
            i += 1;
            j += 1;
        } else {
            result[j] = src[i];
            i += 1;
            j += 1;
        }
    }
    return result[0..j];
}

pub fn parseQuery(query: []const u8, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    var it = std.mem.tokenizeAny(u8, query, "&");

    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_idx| {
            const raw_key = pair[0..eq_idx];
            const raw_val = pair[(eq_idx + 1)..];
            const key = try urlDecode(raw_key, allocator);
            const val = try urlDecode(raw_val, allocator);
            try map.put(key, val);
        } else {
            const key = try urlDecode(pair, allocator);
            try map.put(key, "");
        }
    }

    return map;
}

pub fn parseCgiHeaders(allocator: std.mem.Allocator) !Headers {
    var headers = Headers.init(allocator);
    errdefer headers.deinit();

    const header_prefix = "HTTP_";
    var env_vars = std.process.getEnvMap(allocator) catch unreachable;
    defer env_vars.deinit();

    var iter = env_vars.iterator();

    while (iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, header_prefix)) {
            // Extract the header name (remove "HTTP_" and convert to lowercase).
            const cgi_name = entry.key_ptr.*;
            const header_name = cgi_name[header_prefix.len..];

            // Convert underscores to hyphens and lowercase to canonical form.
            var canonical_name_buf: [128]u8 = undefined; // Buffer for name conversion
            var canonical_name: []u8 = undefined;
            {
                var writer = std.io.fixedBufferStream(&canonical_name_buf);
                for (header_name) |char| {
                    if (char == '_') {
                        try writer.writer().writeByte('-');
                    } else {
                        try writer.writer().writeByte(std.ascii.toLower(char));
                    }
                }
                canonical_name = writer.getWritten();
            }

            // Add the header to our Headers struct.
            const header_value = entry.value_ptr.*;
            try headers.add(canonical_name, header_value);
        }
    }
    // Special case for CONTENT_TYPE and CONTENT_LENGTH (no HTTP_ prefix).
    if (env_vars.get("CONTENT_TYPE")) |content_type| {
        try headers.add("content-type", content_type);
    }
    if (env_vars.get("CONTENT_LENGTH")) |content_length| {
        try headers.add("content-length", content_length);
    }

    return headers;
}

pub fn parseCookie(cookies: *std.StringHashMap([]const u8), cookie_header: []const u8) !void {
    var cookie_iter = std.mem.tokenizeSequence(u8, cookie_header, "; ");

    while (cookie_iter.next()) |cookie| {
        const trimmed_cookie = std.mem.trim(u8, cookie, " ");

        const equals_index = std.mem.indexOf(u8, trimmed_cookie, "=");
        if (equals_index) |index| {
            const cookie_name = trimmed_cookie[0..index];
            const cookie_value = trimmed_cookie[index + 1 ..];

            try cookies.put(cookie_name, cookie_value);
        }
    }
}

pub fn parseRequest(allocator: std.mem.Allocator, io: cgi.IOProvider) !Request {
    const method_str = io.getEnv("REQUEST_METHOD") orelse "GET";
    const path = io.getEnv("PATH_INFO") orelse "/";
    const query_raw = io.getEnv("QUERY_STRING") orelse "";
    const content_type = io.getEnv("CONTENT_TYPE") orelse "";
    const content_length_str = io.getEnv("CONTENT_LENGTH") orelse "0";
    const content_length = try std.fmt.parseInt(usize, content_length_str, 10);

    const headers = try parseCgiHeaders(allocator); // Assuming parseCgiHeaders is adapted to use the IOProvider as well, or you use a different method for FCGI
    const query = try parseQuery(query_raw, allocator);

    var cookies = std.StringHashMap([]const u8).init(allocator);
    if (headers.get("Cookie")) |cookie_header| {
        try parseCookie(&cookies, cookie_header);
    }

    var body_map = std.StringHashMap([]const u8).init(allocator);
    if (std.ascii.startsWithIgnoreCase(content_type, "application/x-www-form-urlencoded")) {
        if (content_length > 0) {
            const body_buffer = try allocator.alloc(u8, content_length);
            defer allocator.free(body_buffer);
            _ = try io.reader().readAll(body_buffer);
            body_map = try parseQuery(body_buffer, allocator);
        }
    }

    return Request{
        .method = std.http.Method.parse(method_str) catch .GET,
        .path = path,
        .headers = headers,
        .cookies = cookies,
        .query = query,
        .body = body_map,
    };
}
