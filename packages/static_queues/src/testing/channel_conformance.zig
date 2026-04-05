const std = @import("std");
const testing = std.testing;
const sync = @import("static_sync");
const concepts = @import("../concepts/root.zig");

pub fn runChannelConformance(comptime C: type, allocator: std.mem.Allocator, capacity: usize) !void {
    concepts.channel.requireChannel(C, C.Element);

    var channel = try C.init(allocator, .{ .capacity = capacity });
    defer channel.deinit();

    try channel.trySend(@as(C.Element, 1));
    try channel.trySend(@as(C.Element, 2));
    try testing.expectError(error.WouldBlock, channel.trySend(@as(C.Element, 3)));

    try testing.expectEqual(@as(C.Element, 1), try channel.tryRecv());
    channel.close();

    try testing.expectError(error.Closed, channel.trySend(@as(C.Element, 9)));
    try testing.expectEqual(@as(C.Element, 2), try channel.tryRecv());
    try testing.expectError(error.Closed, channel.tryRecv());

    if (@hasDecl(C, "trySendBatch") and @hasDecl(C, "tryRecvBatch")) {
        var batch_channel = try C.init(allocator, .{ .capacity = capacity });
        defer batch_channel.deinit();

        const batch_values = [_]C.Element{ @as(C.Element, 11), @as(C.Element, 12), @as(C.Element, 13) };
        const sent_count = try batch_channel.trySendBatch(&batch_values);
        try testing.expect(sent_count <= batch_values.len);

        var out: [3]C.Element = undefined;
        const recv_count = try batch_channel.tryRecvBatch(&out);
        try testing.expect(recv_count <= sent_count);

        if (@hasDecl(C, "ChannelBatchOptions") and @hasDecl(C, "trySendBatchWith") and @hasDecl(C, "tryRecvBatchWith")) {
            const wake_mode_batch: C.BatchWakeMode = if (C.supports_blocking_wait) .single else .progress;
            const wake_mode_close: C.BatchWakeMode = if (C.supports_blocking_wait) .broadcast else .progress;

            const empty_send = try batch_channel.trySendBatchWith(batch_values[0..0], .{
                .items_max = 1,
                .wake_mode = wake_mode_batch,
            });
            try testing.expectEqual(@as(usize, 0), empty_send);

            const empty_recv = try batch_channel.tryRecvBatchWith(out[0..0], .{
                .items_max = 1,
                .wake_mode = wake_mode_batch,
            });
            try testing.expectEqual(@as(usize, 0), empty_recv);

            const bounded_sent = try batch_channel.trySendBatchWith(&batch_values, .{
                .items_max = 1,
                .wake_mode = wake_mode_batch,
            });
            try testing.expect(bounded_sent <= 1);

            var bounded_out: [3]C.Element = undefined;
            const bounded_recv = try batch_channel.tryRecvBatchWith(&bounded_out, .{
                .items_max = 1,
                .wake_mode = wake_mode_batch,
            });
            try testing.expect(bounded_recv <= 1);
            try testing.expect(bounded_recv <= bounded_sent);

            batch_channel.close();

            const empty_send_closed = try batch_channel.trySendBatchWith(batch_values[0..0], .{
                .items_max = 1,
                .wake_mode = wake_mode_close,
            });
            try testing.expectEqual(@as(usize, 0), empty_send_closed);

            const empty_recv_closed = try batch_channel.tryRecvBatchWith(out[0..0], .{
                .items_max = 1,
                .wake_mode = wake_mode_close,
            });
            try testing.expectEqual(@as(usize, 0), empty_recv_closed);

            try testing.expectError(error.Closed, batch_channel.trySendBatchWith(&batch_values, .{
                .items_max = 1,
                .wake_mode = wake_mode_batch,
            }));

            while (true) {
                var recv_one: [1]C.Element = undefined;
                _ = batch_channel.tryRecvBatchWith(&recv_one, .{
                    .items_max = 1,
                    .wake_mode = wake_mode_batch,
                }) catch |err| switch (err) {
                    error.Closed => break,
                };
            }
        }
    }

    if (C.supports_blocking_wait) {
        var cancellable_channel = try C.init(allocator, .{ .capacity = capacity });
        defer cancellable_channel.deinit();

        var cancel_source = sync.cancel.CancelSource{};
        cancel_source.cancel();
        const token = cancel_source.token();

        try testing.expectError(error.Cancelled, cancellable_channel.send(@as(C.Element, 4), token));
        try testing.expectError(error.Cancelled, cancellable_channel.recv(token));
    }

    if (@hasDecl(C, "sendTimeout") and @hasDecl(C, "recvTimeout")) {
        var timed_channel = try C.init(allocator, .{ .capacity = 1 });
        defer timed_channel.deinit();

        try timed_channel.trySend(@as(C.Element, 5));
        try testing.expectError(error.Timeout, timed_channel.sendTimeout(@as(C.Element, 7), null, 0));

        _ = try timed_channel.tryRecv();
        try testing.expectError(error.Timeout, timed_channel.recvTimeout(null, 0));
    }
}
