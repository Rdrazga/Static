const std = @import("std");
const memory = @import("static_memory");

pub fn main() !void {
    var arena = try memory.arena.Arena.init(std.heap.page_allocator, 4096);
    defer arena.deinit();
    _ = try arena.allocator().alloc(u8, 128);
    arena.reset();
    _ = std;
}
