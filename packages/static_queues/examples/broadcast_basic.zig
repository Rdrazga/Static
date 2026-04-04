const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var broadcast = try q.broadcast.Broadcast(u8).init(std.heap.page_allocator, .{
        .capacity = 4,
        .consumers_max = 2,
    });
    defer broadcast.deinit();

    const reader = try broadcast.addConsumer();
    try broadcast.trySend(42);
    _ = try broadcast.tryRecv(reader);
}
