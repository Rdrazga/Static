pub const any_try_queue = @import("any_try_queue.zig");
pub const any_channel = @import("any_channel.zig");
pub const any_registered_fanout_ring = @import("any_registered_fanout_ring.zig");

const std = @import("std");
const testing = std.testing;
const spsc_mod = @import("../queues/spsc.zig");
const channel_mod = @import("../queues/channel.zig");
const spsc_channel_mod = @import("../queues/spsc_channel.zig");
const broadcast_mod = @import("../queues/broadcast.zig");

test "AnyTryQueue wraps a concrete try queue view" {
    var queue = try spsc_mod.SpscQueue(u16).init(testing.allocator, .{ .capacity = 2 });
    defer queue.deinit();

    var any_queue = any_try_queue.AnyTryQueue(
        u16,
        .spsc,
        error{WouldBlock},
        error{WouldBlock},
    ).from(&queue);

    try any_queue.trySend(1);
    try testing.expectEqual(@as(u16, 1), try any_queue.tryRecv());
}

test "AnyRegisteredFanoutRing wraps concrete fanout view" {
    var fanout = try broadcast_mod.Broadcast(u16).init(testing.allocator, .{
        .capacity = 4,
        .consumers_max = 2,
    });
    defer fanout.deinit();

    var any_fanout = any_registered_fanout_ring.AnyRegisteredFanoutRing(
        u16,
        error{WouldBlock},
        error{WouldBlock},
    ).from(&fanout);
    _ = try any_fanout.addConsumer();
}

test "AnyChannel is only used when blocking wait is enabled" {
    const C = channel_mod.Channel(u16);
    if (!C.supports_blocking_wait) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 2 });
    defer channel.deinit();

    const TimedWaitError = error{ Closed, Cancelled, Timeout, Unsupported };
    var any_channel_view = any_channel.AnyChannel(
        u16,
        error{ WouldBlock, Closed },
        error{ WouldBlock, Closed },
        error{ Closed, Cancelled },
        error{ Closed, Cancelled },
        TimedWaitError,
        TimedWaitError,
    ).from(&channel);

    try any_channel_view.trySend(3);
    try testing.expectEqual(@as(u16, 3), try any_channel_view.tryRecv());
    try any_channel_view.sendTimeout(4, null, std.time.ns_per_s);
    try testing.expectEqual(@as(u16, 4), try any_channel_view.recvTimeout(null, std.time.ns_per_s));
}

test "AnyChannel also covers SpscChannel blocking wait contracts" {
    const C = spsc_channel_mod.SpscChannel(u16);
    if (!C.supports_blocking_wait) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 2 });
    defer channel.deinit();

    const TimedWaitError = error{ Closed, Cancelled, Timeout, Unsupported };
    var any_channel_view = any_channel.AnyChannel(
        u16,
        error{ WouldBlock, Closed },
        error{ WouldBlock, Closed },
        error{ Closed, Cancelled },
        error{ Closed, Cancelled },
        TimedWaitError,
        TimedWaitError,
    ).from(&channel);

    try any_channel_view.trySend(5);
    try testing.expectEqual(@as(u16, 5), try any_channel_view.tryRecv());
    try any_channel_view.sendTimeout(6, null, std.time.ns_per_s);
    try testing.expectEqual(@as(u16, 6), try any_channel_view.recvTimeout(null, std.time.ns_per_s));
}

test {
    _ = any_try_queue;
    _ = any_channel;
    _ = any_registered_fanout_ring;
}
