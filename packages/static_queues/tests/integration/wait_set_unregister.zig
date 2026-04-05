const std = @import("std");
const testing = std.testing;
const static_queues = @import("static_queues");

const WaitSet = static_queues.wait_set.WaitSet(u8, 2);
const Channel = static_queues.channel.Channel(u8);

test "wait set unregister removes the source from selection" {
    var wait_set = WaitSet.init(.{});

    var c1 = try Channel.init(testing.allocator, .{ .capacity = 1 });
    defer c1.deinit();
    var c2 = try Channel.init(testing.allocator, .{ .capacity = 1 });
    defer c2.deinit();

    const idx1 = try wait_set.registerChannel(&c1);
    const idx2 = try wait_set.registerChannel(&c2);
    try testing.expect(idx1 != idx2);

    try testing.expectError(error.InvalidIndex, wait_set.unregister(2));
    try testing.expectError(error.InvalidIndex, wait_set.unregister(3));

    try wait_set.unregister(idx1);
    try c1.trySend(7);
    try c2.trySend(9);

    const selected = try wait_set.tryRecvAny();
    try testing.expectEqual(idx2, selected.source_index);
    try testing.expectEqual(@as(u8, 9), selected.value);
}
