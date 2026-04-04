const std = @import("std");
const static_queues = @import("static_queues");

test "intrusive nodes detach and reuse across list and queue handoff" {
    const intrusive = static_queues.intrusive;

    const Item = struct {
        value: u8,
        node: intrusive.Node = .{},
    };

    var a = Item{ .value = 1 };
    var b = Item{ .value = 2 };

    var list = intrusive.IntrusiveList(Item, "node").init();
    var queue = intrusive.IntrusiveMpscQueue(Item, "node").init();

    list.pushBack(&a);
    list.pushBack(&b);
    try std.testing.expectEqual(@as(usize, 2), list.len());

    const removed = list.popFront().?;
    try std.testing.expectEqual(@as(u8, 1), removed.value);
    try std.testing.expect(removed.node.prev == null);
    try std.testing.expect(removed.node.next == null);
    try std.testing.expectEqual(@as(usize, 1), list.len());

    try queue.trySend(removed);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    try std.testing.expectEqual(@as(usize, 1), list.len());

    const roundtrip = try queue.tryRecv();
    try std.testing.expect(roundtrip == removed);
    try std.testing.expectEqual(@as(u8, 1), roundtrip.value);
    try std.testing.expect(roundtrip.node.prev == null);
    try std.testing.expect(roundtrip.node.next == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expectError(error.WouldBlock, queue.tryRecv());

    list.pushBack(roundtrip);
    try std.testing.expectEqual(@as(usize, 2), list.len());
    try std.testing.expectEqual(@as(u8, 2), list.popFront().?.value);
    try std.testing.expectEqual(@as(u8, 1), list.popFront().?.value);
    try std.testing.expect(list.isEmpty());
}
