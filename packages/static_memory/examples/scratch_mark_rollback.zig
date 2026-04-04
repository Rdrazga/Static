const std = @import("std");
const memory = @import("static_memory");

pub fn main() !void {
    var scratch = try memory.scratch.Scratch.init(std.heap.page_allocator, 256);
    defer scratch.deinit();

    _ = try scratch.allocator().alloc(u8, 16);
    const mark = scratch.mark();
    _ = try scratch.allocator().alloc(u8, 32);
    scratch.rollback(mark);
}
