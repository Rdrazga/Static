const std = @import("std");
const concepts = @import("../concepts/root.zig");

pub fn runWorkStealingDequeConformance(comptime D: type, allocator: std.mem.Allocator, capacity: usize) !void {
    const T = D.Element;
    concepts.work_stealing_deque.requireWorkStealingDeque(D, T);

    var deque = try D.init(allocator, .{ .capacity = capacity });
    defer deque.deinit();

    try deque.pushBottom(@as(T, 1));
    try deque.pushBottom(@as(T, 2));
    try std.testing.expectEqual(@as(T, 1), try deque.stealTop());
    try std.testing.expectEqual(@as(T, 2), try deque.popBottom());
    try std.testing.expectError(error.WouldBlock, deque.popBottom());

    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        try deque.pushBottom(@as(T, @intCast(i)));
    }
    try std.testing.expectError(error.WouldBlock, deque.pushBottom(@as(T, 9)));
}
