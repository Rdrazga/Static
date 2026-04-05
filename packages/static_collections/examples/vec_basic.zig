const std = @import("std");
const c = @import("static_collections");

pub fn main() !void {
    var v = try c.vec.Vec(u8).init(std.heap.page_allocator, .{ .initial_capacity = 4, .budget = null });
    defer v.deinit();
    try v.append(1);
    try v.append(2);
    _ = v.items();
    _ = std;
}
