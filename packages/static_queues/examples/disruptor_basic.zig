const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var disruptor = try q.disruptor.Disruptor(u8).init(std.heap.page_allocator, .{
        .capacity = 8,
        .consumers_max = 2,
    });
    defer disruptor.deinit();

    const first = try disruptor.addConsumer();
    const second = try disruptor.addConsumer();

    try disruptor.trySend(42);
    _ = try disruptor.tryRecv(first);
    _ = try disruptor.tryRecv(second);
}
