const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var pq = try q.priority_queue.PriorityQueueDefault(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 4, .budget = null },
        .{},
    );
    defer pq.deinit();

    try pq.tryPush(9);
    try pq.tryPush(2);
    try pq.tryPush(7);
    try pq.tryPush(1);

    while (!pq.isEmpty()) {
        const value = try pq.tryPop();
        std.debug.print("{d}\n", .{value});
    }
}
