const std = @import("std");

const ztl = @import("ztl");

const http = @import("../../http.zig");
const main = @import("../../main.zig");

pub fn handleDashboardGet(_: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    // Cast the opaque context pointer back to our Context struct.
    const ctx: *main.Context = @ptrCast(@alignCast(ctx_ptr));

    // Get the session object from the context. This should not fail if sessionPreflight
    // has run successfully before this handler.
    const s = try ctx.getSession();

    // Get the SessionData from the session object. This will allocate and
    // initialize the SessionData if it's currently null.
    const data = try s.getData();

    // Define the context struct for the dashboard template.
    // This struct defines what variables will be available inside your HTML template.
    const DashboardContext = struct {
        username: ?[]const u8,
        user_id: ?u64,
        session_id: []const u8,
    };

    // Initialize the template context with data from the session.
    const template_context = DashboardContext{
        .username = data.username,
        .user_id = data.user_id,
        .session_id = s.id, // s.id is already []u8, which can coerce to []const u8
    };

    // Set the response content type to HTML.
    res.content_type = "text/html";

    // Initialize the ztl template with the DashboardContext type.
    var template = ztl.Template(DashboardContext).init(ctx.allocator, template_context);
    defer template.deinit();

    var compile_error_report = ztl.CompileErrorReport{};

    // Embed the HTML template file. Make sure the path is correct relative to this .zig file.
    const content_template = @embedFile("../../templates/user/dashboard.html");
    template.compile(content_template, .{ .error_report = &compile_error_report }) catch |err| {
        std.debug.print("Template compile error: {any}\n", .{err});
        try res.writer().print("{}\n", .{compile_error_report});
        return err;
    };

    // Create an ArrayList to buffer the rendered HTML output.
    var buf = std.ArrayList(u8).init(ctx.allocator);
    defer buf.deinit();

    var render_error_report = ztl.RenderErrorReport{};

    // Render the template using the prepared context.
    template.render(buf.writer(), template_context, .{ .error_report = &render_error_report }) catch |err| {
        std.debug.print("Template render error: {any}\n", .{err});
        defer render_error_report.deinit();
        try res.writer().print("{}\n", .{render_error_report});
        return err;
    };

    // Send the buffered HTML content as the response.
    try res.writer().print("{s}\n", .{buf.items});
}
