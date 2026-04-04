//! Bounded deterministic storage-completion simulator over logical time.

const std = @import("std");
const trace = @import("../trace.zig");
const clock = @import("clock.zig");
const mailbox = @import("mailbox.zig");

pub const CompletionStatus = enum(u8) {
    success = 1,
    failed = 2,
};

pub const StorageLaneError = error{
    InvalidConfig,
    InvalidInput,
    NoSpaceLeft,
};

pub const StorageLaneConfig = struct {
    default_delay: clock.LogicalDuration,
};

pub fn OperationResult(comptime T: type) type {
    return struct {
        request_id: u32,
        status: CompletionStatus,
        value: T,
    };
}

pub fn PendingCompletion(comptime T: type) type {
    return struct {
        due_time: clock.LogicalTime,
        result: OperationResult(T),
    };
}

pub const CompletionResult = struct {
    success_count: u32 = 0,
    failure_count: u32 = 0,
};

pub fn StorageLane(comptime T: type) type {
    return struct {
        const Self = @This();
        const Result = OperationResult(T);
        const Pending = PendingCompletion(T);

        config: StorageLaneConfig,
        storage: []Pending,
        pending_count: usize = 0,

        pub fn init(
            storage: []Pending,
            config: StorageLaneConfig,
        ) StorageLaneError!Self {
            if (storage.len == 0) return error.InvalidConfig;
            return .{
                .config = config,
                .storage = storage,
            };
        }

        pub fn submitSuccess(
            self: *Self,
            now: clock.LogicalTime,
            request_id: u32,
            value: T,
        ) StorageLaneError!void {
            return self.submitAfter(now, self.config.default_delay, .{
                .request_id = request_id,
                .status = .success,
                .value = value,
            });
        }

        pub fn submitFailure(
            self: *Self,
            now: clock.LogicalTime,
            request_id: u32,
            value: T,
        ) StorageLaneError!void {
            return self.submitAfter(now, self.config.default_delay, .{
                .request_id = request_id,
                .status = .failed,
                .value = value,
            });
        }

        pub fn submitAfter(
            self: *Self,
            now: clock.LogicalTime,
            delay: clock.LogicalDuration,
            result: Result,
        ) StorageLaneError!void {
            if (result.request_id == 0) return error.InvalidInput;
            if (self.pending_count >= self.storage.len) return error.NoSpaceLeft;
            const due_time = now.add(delay) catch return error.InvalidInput;
            self.storage[self.pending_count] = .{
                .due_time = due_time,
                .result = result,
            };
            self.pending_count += 1;
        }

        pub fn deliverDueToMailbox(
            self: *Self,
            now: clock.LogicalTime,
            completion_mailbox: *mailbox.Mailbox(Result),
            trace_buffer: ?*trace.TraceBuffer,
        ) (StorageLaneError || mailbox.MailboxError || trace.TraceAppendError)!CompletionResult {
            var delivered: CompletionResult = .{};
            var index: usize = 0;
            while (index < self.pending_count) {
                const pending = self.storage[index];
                if (pending.due_time.tick > now.tick) {
                    index += 1;
                    continue;
                }

                try completion_mailbox.send(pending.result);
                try appendCompletionTrace(trace_buffer, now, pending.result);
                switch (pending.result.status) {
                    .success => delivered.success_count += 1,
                    .failed => delivered.failure_count += 1,
                }
                removePendingAt(self.storage, &self.pending_count, index);
            }
            return delivered;
        }

        pub fn pendingItems(self: *const Self) []const Pending {
            return self.storage[0..self.pending_count];
        }
    };
}

fn appendCompletionTrace(
    trace_buffer: ?*trace.TraceBuffer,
    timestamp: clock.LogicalTime,
    result: anytype,
) trace.TraceAppendError!void {
    if (trace_buffer) |buffer| {
        try buffer.append(.{
            .timestamp_ns = timestamp.tick,
            .category = .check,
            .label = switch (result.status) {
                .success => "storage_lane.success",
                .failed => "storage_lane.failed",
            },
            .value = result.request_id,
            .lineage = .{
                .surface_label = "storage_lane",
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

test "storage lane delivers success and failure completions after delay" {
    var storage: [4]PendingCompletion(u32) = undefined;
    var lane = try StorageLane(u32).init(&storage, .{
        .default_delay = .init(2),
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(std.testing.allocator, .{
        .capacity = 4,
    });
    defer completions.deinit();

    try lane.submitSuccess(.init(0), 11, 200);
    try lane.submitFailure(.init(0), 12, 500);
    try std.testing.expectEqual(@as(usize, 2), lane.pendingItems().len);

    const early = try lane.deliverDueToMailbox(.init(1), &completions, null);
    try std.testing.expectEqual(@as(u32, 0), early.success_count);
    try std.testing.expectEqual(@as(u32, 0), early.failure_count);

    const delivered = try lane.deliverDueToMailbox(.init(2), &completions, null);
    try std.testing.expectEqual(@as(u32, 1), delivered.success_count);
    try std.testing.expectEqual(@as(u32, 1), delivered.failure_count);
    try std.testing.expectEqual(@as(usize, 0), lane.pendingItems().len);

    const first = try completions.recv();
    const second = try completions.recv();
    try std.testing.expectEqual(CompletionStatus.success, first.status);
    try std.testing.expectEqual(CompletionStatus.failed, second.status);
}
