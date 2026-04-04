const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var deque = try q.work_stealing_deque.WorkStealingDeque(u8).init(std.heap.page_allocator, .{
        .capacity = 8,
    });
    defer deque.deinit();

    try deque.pushBottom(5);
    _ = try deque.stealTop();
}
