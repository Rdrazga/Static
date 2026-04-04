const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var queue = try q.spsc.SpscQueue(u8).init(std.heap.page_allocator, .{ .capacity = 2 });
    defer queue.deinit();

    try queue.trySend(10);
    try queue.trySend(20);
    _ = try queue.tryRecv();
}
