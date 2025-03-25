const std = @import("std");
const myzql = @import("myzql");

pub const Request = struct {
    method: Method,
    path: []const u8,
    query: std.StringHashMap([]const u8),
};

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    UNKNOWN,

    pub fn fromStr(s: []const u8) Method {
        return if (std.mem.eql(u8, s, "GET")) {
            return .GET;
        } else if (std.mem.eql(u8, s, "POST")) {
            return .POST;
        } else if (std.mem.eql(u8, s, "PUT")) {
            return .PUT;
        } else if (std.mem.eql(u8, s, "PATCH")) {
            return .PATCH;
        } else if (std.mem.eql(u8, s, "DELETE")) {
            return .DELETE;
        } else .UNKNOWN;
    }
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status_code: u16 = 200,
    content_type: []const u8 = "text/plain",
    headers: std.ArrayList(Header),
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .headers = std.ArrayList(Header).init(allocator),
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: Response) void {
        self.headers.deinit();
        self.buffer.deinit();
    }

    pub fn writer(self: *Response) @TypeOf(self.buffer.writer()) {
        return self.buffer.writer();
    }

    pub fn setHeader(self: *Response, key: []const u8, value: []const u8) !void {
        return self.headers.append(.{ .key = key, .value = value });
    }

    pub fn redirect(self: *Response, location: []const u8) !void {
        try self.redirectWithCode(location, 302);
    }

    pub fn redirectWithCode(self: *Response, location: []const u8, status_code: u16) !void {
        self.status_code = status_code;
        try self.setHeader("Location", location);
    }

    pub fn send(self: *Response) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Status: {d} \r\n", .{self.status_code});
        for (self.headers.items) |header| {
            try stdout.print("{s}: {s}\r\n", .{ header.key, header.value });
        }
        try stdout.print("Zig: 0.14.0\r\n", .{});
        try stdout.print("Content-Type: {s}\r\n", .{self.content_type});
        try stdout.print("\r\n", .{});

        try stdout.writeAll(self.buffer.items);
    }
};

pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: *const fn (*Request, *Response, *anyopaque) anyerror!void,
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
                try route.handler(req, res, ctx);
                return true; // Found a matching route
            }
        }
        return false; // No matching route found
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
