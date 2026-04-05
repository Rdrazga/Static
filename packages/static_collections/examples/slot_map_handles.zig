const std = @import("std");
const c = @import("static_collections");

pub fn main() !void {
    var sm = try c.slot_map.SlotMap(u8).init(std.heap.page_allocator, .{ .budget = null });
    defer sm.deinit();

    const h = try sm.insert(7);
    _ = sm.get(h);
    _ = try sm.remove(h);
    _ = std;
}
