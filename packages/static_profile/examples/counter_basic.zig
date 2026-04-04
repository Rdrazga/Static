//! Demonstrates recording a named counter event alongside zone events
//! and exporting the combined timeline as Chrome trace JSON.
const std = @import("std");
const profile = @import("static_profile");

pub fn main() !void {
    var trace = try profile.trace.EnabledTrace.init(std.heap.page_allocator, 16);
    defer trace.deinit();

    const tok = try trace.beginZone("frame", 0, 1);
    try trace.recordCounter("triangles", 50, 1, 42_000);
    try trace.endZone(tok, 100);

    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    try trace.writeChromeTraceJson(&aw.writer);

    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}\n", .{out.items});
}
