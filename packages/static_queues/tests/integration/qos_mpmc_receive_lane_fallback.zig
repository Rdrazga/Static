const std = @import("std");
const testing = std.testing;
const static_queues = @import("static_queues");

test "qos mpmc weighted receive falls back to the next lane when the current lane is empty" {
    const Q = static_queues.qos_mpmc.QosMpmcQueue(u8, 2);
    var q = try Q.init(testing.allocator, .{
        .lane_capacity = 2,
        .lane_weights_recv = .{ 2, 1 },
        .scheduling_policy = .weighted_round_robin,
    });
    defer q.deinit();

    try q.trySend(0, 10);
    try q.trySend(1, 20);

    try testing.expectEqual(@as(u8, 10), try q.tryRecv());
    try testing.expectEqual(@as(u8, 20), try q.tryRecv());

    try q.trySend(0, 30);
    try testing.expectEqual(@as(u8, 30), try q.tryRecv());
}
