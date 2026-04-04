const std = @import("std");
const concepts = @import("../concepts/root.zig");

fn trySendBatchCount(comptime Q: type, queue: *Q, values: []const Q.Element) !usize {
    const return_type = @TypeOf(queue.trySendBatch(values));
    if (comptime @typeInfo(return_type) == .error_union) {
        return try queue.trySendBatch(values);
    }
    return queue.trySendBatch(values);
}

fn tryRecvBatchCount(comptime Q: type, queue: *Q, out: []Q.Element) !usize {
    const return_type = @TypeOf(queue.tryRecvBatch(out));
    if (comptime @typeInfo(return_type) == .error_union) {
        return try queue.tryRecvBatch(out);
    }
    return queue.tryRecvBatch(out);
}

fn trySendBatchWithCount(
    comptime Q: type,
    queue: *Q,
    values: []const Q.Element,
    options: Q.BatchLimitOptions,
) !usize {
    const return_type = @TypeOf(queue.trySendBatchWith(values, options));
    if (comptime @typeInfo(return_type) == .error_union) {
        return try queue.trySendBatchWith(values, options);
    }
    return queue.trySendBatchWith(values, options);
}

fn tryRecvBatchWithCount(
    comptime Q: type,
    queue: *Q,
    out: []Q.Element,
    options: Q.BatchLimitOptions,
) !usize {
    const return_type = @TypeOf(queue.tryRecvBatchWith(out, options));
    if (comptime @typeInfo(return_type) == .error_union) {
        return try queue.tryRecvBatchWith(out, options);
    }
    return queue.tryRecvBatchWith(out, options);
}

pub fn runTryQueueConformance(comptime Q: type, allocator: std.mem.Allocator, capacity: usize) !void {
    const T = Q.Element;
    concepts.try_queue.requireTryQueue(Q, T);

    var queue = try Q.init(allocator, .{ .capacity = capacity });
    defer queue.deinit();

    try std.testing.expectEqual(capacity, queue.capacity());
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expect(queue.isEmpty());

    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        const value: T = @as(T, @intCast(i + 1));
        try queue.trySend(value);
        try std.testing.expect(queue.len() <= queue.capacity());
    }

    try std.testing.expectError(error.WouldBlock, queue.trySend(@as(T, @intCast(capacity + 1))));

    i = 0;
    while (i < capacity) : (i += 1) {
        const expected: T = @as(T, @intCast(i + 1));
        try std.testing.expectEqual(expected, try queue.tryRecv());
        try std.testing.expect(queue.len() <= queue.capacity());
    }

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectError(error.WouldBlock, queue.tryRecv());

    if (@hasDecl(Q, "trySendBatch") and @hasDecl(Q, "tryRecvBatch")) {
        const batch_values = [_]T{ @as(T, 7), @as(T, 8), @as(T, 9) };
        const sent_count = try trySendBatchCount(Q, &queue, &batch_values);
        try std.testing.expect(sent_count <= batch_values.len);

        var out: [3]T = undefined;
        const recv_count = try tryRecvBatchCount(Q, &queue, &out);
        try std.testing.expect(recv_count <= sent_count);

        while (true) {
            _ = queue.tryRecv() catch |err| switch (err) {
                error.WouldBlock => break,
            };
        }

        if (@hasDecl(Q, "BatchLimitOptions") and @hasDecl(Q, "trySendBatchWith") and @hasDecl(Q, "tryRecvBatchWith")) {
            const empty_send = try trySendBatchWithCount(Q, &queue, batch_values[0..0], .{
                .items_max = 1,
            });
            try std.testing.expectEqual(@as(usize, 0), empty_send);

            const empty_recv = try tryRecvBatchWithCount(Q, &queue, out[0..0], .{
                .items_max = 1,
            });
            try std.testing.expectEqual(@as(usize, 0), empty_recv);

            const bounded_sent = try trySendBatchWithCount(Q, &queue, &batch_values, .{
                .items_max = 1,
            });
            try std.testing.expect(bounded_sent <= 1);

            var bounded_out: [3]T = undefined;
            const bounded_recv = try tryRecvBatchWithCount(Q, &queue, &bounded_out, .{
                .items_max = 1,
            });
            try std.testing.expect(bounded_recv <= 1);
            try std.testing.expect(bounded_recv <= bounded_sent);
        }
    }
}
