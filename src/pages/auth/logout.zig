const std = @import("std");
const http = @import("../../http.zig");
const main = @import("../../main.zig");

pub fn handleRegisterGet(_: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    const ctx: *main.Context = @ptrCast(@alignCast(ctx_ptr));

    var session = try ctx.getSession();
    session.markDeleted();

    try res.setHeader("Location", "/auth/login");
}
