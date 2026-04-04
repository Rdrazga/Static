const std = @import("std");
const concepts = @import("../concepts/root.zig");

pub fn runRegisteredFanoutRingConformance(comptime F: type, allocator: std.mem.Allocator, capacity: usize, consumers_max: usize) !void {
    const T = F.Element;
    concepts.registered_fanout_ring.requireRegisteredFanoutRing(F, T);

    var fanout = try F.init(allocator, .{
        .capacity = capacity,
        .consumers_max = consumers_max,
    });
    defer fanout.deinit();

    const consumer_a = try fanout.addConsumer();
    const consumer_b = try fanout.addConsumer();

    try fanout.trySend(@as(T, 11));
    try fanout.trySend(@as(T, 22));

    try std.testing.expectEqual(@as(T, 11), try fanout.tryRecv(consumer_a));
    try std.testing.expectEqual(@as(T, 22), try fanout.tryRecv(consumer_a));
    try std.testing.expectEqual(@as(T, 11), try fanout.tryRecv(consumer_b));
    try std.testing.expectEqual(@as(T, 22), try fanout.tryRecv(consumer_b));

    try std.testing.expectEqual(@as(usize, 0), fanout.pending(consumer_a));
    try std.testing.expectEqual(@as(usize, 0), fanout.pending(consumer_b));
    try std.testing.expectError(error.WouldBlock, fanout.tryRecv(consumer_a));

    if (consumers_max == 2) {
        try std.testing.expectError(error.NoSpaceLeft, fanout.addConsumer());
    }
}
