
const buildConfig = @cImport({
    @cInclude("config.h");
});

const fcgi = @cImport({
    if (buildConfig.IS_FCGI == 1) {
        @cInclude("fcgiapp.h");
    }
});

pub const IOProvider = union(enum) {
    cgi: void,
    fcgi: *const fcgi.FCGX_Request,

    pub fn getEnv(self: IOProvider, key: [:0]const u8) ?[]const u8 {
        return switch (self) {
            .cgi => http.getEnv(key),
            .fcgi => |req| {
                const val = fcgi.FCGX_GetParam(key.ptr, req.envp);
                if (val == null) return null;
                return std.mem.sliceTo(val, 0);
            },
        };
    }

    pub fn reader(self: IOProvider) std.io.AnyReader {
        return switch (self) {
            .cgi => std.io.getStdIn().reader(),
            .fcgi => |req| .{ .context = FcgiStreamReader{ .stream = req.in } },
        };
    }

    pub fn writer(self: IOProvider) std.io.AnyWriter {
        return switch (self) {
            .cgi => std.io.getStdOut().writer(),
            .fcgi => |req| .{ .context = FcgiStreamWriter{ .stream = req.out } },
        };
    }

    pub fn finish(self: IOProvider) void {
        switch (self) {
            .cgi => {},
            .fcgi => |req| fcgi.FCGX_Finish_r(@constCast(req)),
        }
    }
};

const FcgiStreamReader = struct {
    stream: *fcgi.FCGX_Stream,
    pub fn read(self: @This(), buffer: []u8) anyerror!usize {
        const n = fcgi.FCGX_GetStr(buffer.ptr, @intCast(buffer.len), self.stream);
        if (n < 0) return error.FcgiReadError;
        return @intCast(n);
    }
};

const FcgiStreamWriter = struct {
    stream: *fcgi.FCGX_Stream,
    pub fn write(self: @This(), bytes: []const u8) anyerror!usize {
        const n = fcgi.FCGX_PutStr(bytes.ptr, @intCast(bytes.len), self.stream);
        if (n < 0) return error.FcgiWriteError;
        return @intCast(n);
    }
};
