const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var queue = try q.spsc.SpscQueue(u8).init(std.heap.page_allocator, .{ .capacity = 4 });
    defer queue.deinit();

    try queue.trySend(0xAA);
    _ = try queue.tryRecv();
}
