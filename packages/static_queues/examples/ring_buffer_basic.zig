const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var rb = try q.ring_buffer.RingBuffer(u8).init(std.heap.page_allocator, .{ .capacity = 4 });
    defer rb.deinit();
    try rb.tryPush(1);
    _ = try rb.tryPop();
    _ = std;
}
