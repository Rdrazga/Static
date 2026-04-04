//! Bounded deterministic retry/backpressure helper over logical time.

const std = @import("std");
const trace = @import("../trace.zig");
const clock = @import("clock.zig");
const mailbox = @import("mailbox.zig");

pub const RetryQueueError = error{
    InvalidConfig,
    InvalidInput,
    NoSpaceLeft,
};

pub const RetryQueueConfig = struct {
    backoff: clock.LogicalDuration,
    max_attempts: u32,
};

pub const RetryDecision = enum(u8) {
    queued = 1,
    exhausted = 2,
};

pub fn RetryEnvelope(comptime T: type) type {
    return struct {
        request_id: u32,
        attempt: u32,
        payload: T,
    };
}

pub fn PendingRetry(comptime T: type) type {
    return struct {
        due_time: clock.LogicalTime,
        envelope: RetryEnvelope(T),
    };
}

pub fn RetryQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Envelope = RetryEnvelope(T);
        const Pending = PendingRetry(T);

        config: RetryQueueConfig,
        storage: []Pending,
        pending_count: usize = 0,

        pub fn init(
            storage: []Pending,
            config: RetryQueueConfig,
        ) RetryQueueError!Self {
            if (storage.len == 0) return error.InvalidConfig;
            if (config.max_attempts == 0) return error.InvalidConfig;
            return .{
                .config = config,
                .storage = storage,
            };
        }

        pub fn scheduleNext(
            self: *Self,
            now: clock.LogicalTime,
            current_attempt: u32,
            request_id: u32,
            payload: T,
        ) RetryQueueError!RetryDecision {
            if (request_id == 0) return error.InvalidInput;
            const next_attempt = current_attempt + 1;
            if (next_attempt > self.config.max_attempts) return .exhausted;
            if (self.pending_count >= self.storage.len) return error.NoSpaceLeft;

            const due_time = now.add(self.config.backoff) catch return error.InvalidInput;
            self.storage[self.pending_count] = .{
                .due_time = due_time,
                .envelope = .{
                    .request_id = request_id,
                    .attempt = next_attempt,
                    .payload = payload,
                },
            };
            self.pending_count += 1;
            return .queued;
        }

        pub fn emitDueToMailbox(
            self: *Self,
            now: clock.LogicalTime,
            retry_mailbox: *mailbox.Mailbox(Envelope),
            trace_buffer: ?*trace.TraceBuffer,
        ) (RetryQueueError || mailbox.MailboxError || trace.TraceAppendError)!u32 {
            var emitted_count: u32 = 0;
            var index: usize = 0;
            while (index < self.pending_count) {
                const pending = self.storage[index];
                if (pending.due_time.tick > now.tick) {
                    index += 1;
                    continue;
                }

                try retry_mailbox.send(pending.envelope);
                try appendRetryTrace(trace_buffer, now, pending.envelope);
                emitted_count += 1;
                removePendingAt(self.storage, &self.pending_count, index);
            }
            return emitted_count;
        }

        pub fn pendingItems(self: *const Self) []const Pending {
            return self.storage[0..self.pending_count];
        }
    };
}

fn appendRetryTrace(
    trace_buffer: ?*trace.TraceBuffer,
    timestamp: clock.LogicalTime,
    envelope: anytype,
) trace.TraceAppendError!void {
    if (trace_buffer) |buffer| {
        try buffer.append(.{
            .timestamp_ns = timestamp.tick,
            .category = .input,
            .label = "retry_queue.emit",
            .value = envelope.request_id,
            .lineage = .{
                .correlation_id = envelope.attempt,
                .surface_label = "retry_queue",
            },
        });
    }
}

fn removePendingAt(
    storage: anytype,
    pending_count: *usize,
    index: usize,
) void {
    std.debug.assert(index < pending_count.*);
    var cursor = index;
    while (cursor + 1 < pending_count.*) : (cursor += 1) {
        storage[cursor] = storage[cursor + 1];
    }
    pending_count.* -= 1;
}

test "retry queue emits bounded retries after backoff and enforces max attempts" {
    var storage: [4]PendingRetry(u32) = undefined;
    var queue = try RetryQueue(u32).init(&storage, .{
        .backoff = .init(2),
        .max_attempts = 2,
    });
    var retries = try mailbox.Mailbox(RetryEnvelope(u32)).init(std.testing.allocator, .{
        .capacity = 4,
    });
    defer retries.deinit();

    try std.testing.expectEqual(RetryDecision.queued, try queue.scheduleNext(.init(0), 0, 7, 90));
    try std.testing.expectEqual(@as(usize, 1), queue.pendingItems().len);
    try std.testing.expectEqual(@as(u32, 0), try queue.emitDueToMailbox(.init(1), &retries, null));
    try std.testing.expectEqual(@as(u32, 1), try queue.emitDueToMailbox(.init(2), &retries, null));

    const retry = try retries.recv();
    try std.testing.expectEqual(@as(u32, 1), retry.attempt);
    try std.testing.expectEqual(@as(u32, 7), retry.request_id);

    try std.testing.expectEqual(RetryDecision.exhausted, try queue.scheduleNext(.init(2), 2, 7, 90));
}
