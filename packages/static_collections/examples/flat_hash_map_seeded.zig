const std = @import("std");
const c = @import("static_collections");

pub fn main() !void {
    const Ctx = struct {};
    var m = try c.flat_hash_map.FlatHashMap(u32, u32, Ctx).init(std.heap.page_allocator, .{
        .seed = 0xC0FFEE,
    });
    defer m.deinit();
    try m.put(1, 100);
    _ = m.get(1);
    _ = std;
}
