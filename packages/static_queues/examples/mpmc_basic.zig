const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var queue = try q.mpmc.MpmcQueue(u8).init(std.heap.page_allocator, .{ .capacity = 2 });
    defer queue.deinit();

    try queue.trySend(9);
    _ = try queue.tryRecv();
}
