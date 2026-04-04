const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    const Job = struct { id: u32 };

    var queue = try q.mpsc.MpscQueue(Job).init(std.heap.page_allocator, .{ .capacity = 2 });
    defer queue.deinit();

    try queue.trySend(.{ .id = 7 });
    const job = try queue.tryRecv();
    _ = job;
}
