const std = @import("std");
const memory = @import("static_memory");

pub fn main() !void {
    var pool: memory.pool.TypedPool(u32) = undefined;
    try memory.pool.TypedPool(u32).init(&pool, std.heap.page_allocator, 2);
    defer pool.deinit();

    const item = try pool.create();
    item.* = 42;
    try pool.destroy(item);
}
