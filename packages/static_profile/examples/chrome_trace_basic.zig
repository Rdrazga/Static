const std = @import("std");
const profile = @import("static_profile");

pub fn main() !void {
    var trace = try profile.trace.EnabledTrace.init(std.heap.page_allocator, 8);
    defer trace.deinit();

    const tok = try trace.beginZone("startup", 10, 1);
    try trace.endZone(tok, 20);

    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    try trace.writeChromeTraceJson(&aw.writer);

    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}\n", .{out.items});
}
