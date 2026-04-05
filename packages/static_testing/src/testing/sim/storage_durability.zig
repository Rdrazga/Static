//! Bounded deterministic storage-durability simulator over logical time.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const trace = @import("../trace.zig");
const clock = @import("clock.zig");
const mailbox = @import("mailbox.zig");

pub const OperationKind = enum(u8) {
    write = 1,
    read = 2,
};

pub const CompletionStatus = enum(u8) {
    success = 1,
    missing = 2,
    corrupted = 3,
};

pub const CrashBehavior = enum(u8) {
    keep_pending_writes = 1,
    drop_pending_writes = 2,
};

pub const RecoverabilityPolicy = enum(u8) {
    keep_faults_after_recover = 1,
    stabilize_after_recover = 2,
};

pub const WritePlacementPolicy = union(enum(u8)) {
    none,
    fixed_slot: u32,
};

pub const WritePersistencePolicy = enum(u8) {
    durable = 1,
    acknowledge_without_store = 2,
};

pub fn CorruptionPolicy(comptime T: type) type {
    return union(enum(u8)) {
        none,
        fixed_value: T,
    };
}

pub const StorageDurabilityError = error{
    InvalidConfig,
    InvalidInput,
    NoSpaceLeft,
    Unavailable,
};

pub fn StorageDurabilityConfig(comptime T: type) type {
    return struct {
        write_delay: clock.LogicalDuration,
        read_delay: clock.LogicalDuration,
        crash_behavior: CrashBehavior = .drop_pending_writes,
        recoverability_policy: RecoverabilityPolicy = .keep_faults_after_recover,
        write_placement: WritePlacementPolicy = .none,
        write_persistence: WritePersistencePolicy = .durable,
        write_corruption: CorruptionPolicy(T) = .none,
        read_corruption: CorruptionPolicy(T) = .none,
    };
}

pub fn StoredValue(comptime T: type) type {
    return struct {
        slot_id: u32,
        value: T,
    };
}

pub fn OperationResult(comptime T: type) type {
    return struct {
        request_id: u32,
        kind: OperationKind,
        status: CompletionStatus,
        slot_id: u32,
        value: ?T = null,
    };
}

pub fn PendingOperation(comptime T: type) type {
    return struct {
        due_time: clock.LogicalTime,
        request_id: u32,
        kind: OperationKind,
        slot_id: u32,
        value: ?T = null,
    };
}

pub fn RecordedState(comptime T: type) type {
    return struct {
        pending: []const PendingOperation(T),
        stored: []const StoredValue(T),
        crashed: bool,
        stabilized_after_recover: bool,
    };
}

pub const DeliverySummary = struct {
    write_success_count: u32 = 0,
    read_success_count: u32 = 0,
    missing_count: u32 = 0,
    corrupted_count: u32 = 0,
};

pub fn StorageDurability(comptime T: type) type {
    return struct {
        const Self = @This();
        const Config = StorageDurabilityConfig(T);
        const Pending = PendingOperation(T);
        const Result = OperationResult(T);
        const Stored = StoredValue(T);

        config: Config,
        pending_storage: []Pending,
        stored_storage: []Stored,
        pending_count: usize = 0,
        stored_count: usize = 0,
        crashed: bool = false,
        stabilized_after_recover: bool = false,

        pub fn init(
            pending_storage: []Pending,
            stored_storage: []Stored,
            config: Config,
        ) StorageDurabilityError!Self {
            if (pending_storage.len == 0) return error.InvalidConfig;
            if (stored_storage.len == 0) return error.InvalidConfig;
            try validateConfig(config);
            return .{
                .config = config,
                .pending_storage = pending_storage,
                .stored_storage = stored_storage,
            };
        }

        pub fn submitWrite(
            self: *Self,
            now: clock.LogicalTime,
            request_id: u32,
            slot_id: u32,
            value: T,
        ) StorageDurabilityError!void {
            try self.submitAfter(now, self.config.write_delay, .{
                .request_id = request_id,
                .kind = .write,
                .slot_id = slot_id,
                .value = value,
            });
        }

        pub fn submitRead(
            self: *Self,
            now: clock.LogicalTime,
            request_id: u32,
            slot_id: u32,
        ) StorageDurabilityError!void {
            try self.submitAfter(now, self.config.read_delay, .{
                .request_id = request_id,
                .kind = .read,
                .slot_id = slot_id,
                .value = null,
            });
        }

        pub fn submitAfter(
            self: *Self,
            now: clock.LogicalTime,
            delay: clock.LogicalDuration,
            operation: struct {
                request_id: u32,
                kind: OperationKind,
                slot_id: u32,
                value: ?T,
            },
        ) StorageDurabilityError!void {
            if (self.crashed) return error.Unavailable;
            if (operation.request_id == 0) return error.InvalidInput;
            if (operation.slot_id == 0) return error.InvalidInput;
            switch (operation.kind) {
                .write => if (operation.value == null) return error.InvalidInput,
                .read => if (operation.value != null) return error.InvalidInput,
            }
            if (self.pending_count >= self.pending_storage.len) return error.NoSpaceLeft;

            const due_time = now.add(delay) catch return error.InvalidInput;
            self.pending_storage[self.pending_count] = .{
                .due_time = due_time,
                .request_id = operation.request_id,
                .kind = operation.kind,
                .slot_id = operation.slot_id,
                .value = operation.value,
            };
            self.pending_count += 1;
        }

        pub fn crash(
            self: *Self,
            now: clock.LogicalTime,
            trace_buffer: ?*trace.TraceBuffer,
        ) trace.TraceAppendError!u32 {
            self.crashed = true;
            self.stabilized_after_recover = false;
            const dropped_write_count = if (self.config.crash_behavior == .drop_pending_writes)
                self.dropPendingWrites()
            else
                0;
            try appendCrashTrace(trace_buffer, now, dropped_write_count);
            return dropped_write_count;
        }

        pub fn recover(
            self: *Self,
            now: clock.LogicalTime,
            trace_buffer: ?*trace.TraceBuffer,
        ) trace.TraceAppendError!void {
            const was_crashed = self.crashed;
            self.crashed = false;
            if (was_crashed and self.config.recoverability_policy == .stabilize_after_recover) {
                self.stabilized_after_recover = true;
            }
            try appendRecoverTrace(trace_buffer, now);
        }

        pub fn deliverDueToMailbox(
            self: *Self,
            now: clock.LogicalTime,
            completion_mailbox: *mailbox.Mailbox(Result),
            trace_buffer: ?*trace.TraceBuffer,
        ) (StorageDurabilityError || mailbox.MailboxError || trace.TraceAppendError)!DeliverySummary {
            var summary: DeliverySummary = .{};
            if (self.crashed) return summary;

            var index: usize = 0;
            while (index < self.pending_count) {
                const pending = self.pending_storage[index];
                if (pending.due_time.tick > now.tick) {
                    index += 1;
                    continue;
                }

                try ensureDeliveryCanProceed(trace_buffer, completion_mailbox);
                const result = try self.materializeResult(pending);
                try completion_mailbox.send(result);
                try appendResultTrace(trace_buffer, now, result);
                switch (result.kind) {
                    .write => switch (result.status) {
                        .success => summary.write_success_count += 1,
                        .missing => unreachable,
                        .corrupted => summary.corrupted_count += 1,
                    },
                    .read => switch (result.status) {
                        .success => summary.read_success_count += 1,
                        .missing => summary.missing_count += 1,
                        .corrupted => summary.corrupted_count += 1,
                    },
                }
                removePendingAt(self.pending_storage, &self.pending_count, index);
            }

            return summary;
        }

        pub fn pendingItems(self: *const Self) []const Pending {
            return self.pending_storage[0..self.pending_count];
        }

        pub fn storedItems(self: *const Self) []const Stored {
            return self.stored_storage[0..self.stored_count];
        }

        pub fn recordState(
            self: *const Self,
            pending_out: []Pending,
            stored_out: []Stored,
        ) StorageDurabilityError!RecordedState(T) {
            if (pending_out.len < self.pending_count) return error.NoSpaceLeft;
            if (stored_out.len < self.stored_count) return error.NoSpaceLeft;

            std.mem.copyForwards(Pending, pending_out[0..self.pending_count], self.pending_storage[0..self.pending_count]);
            std.mem.copyForwards(Stored, stored_out[0..self.stored_count], self.stored_storage[0..self.stored_count]);
            return .{
                .pending = pending_out[0..self.pending_count],
                .stored = stored_out[0..self.stored_count],
                .crashed = self.crashed,
                .stabilized_after_recover = self.stabilized_after_recover,
            };
        }

        pub fn replayRecordedState(
            self: *Self,
            recorded: RecordedState(T),
        ) StorageDurabilityError!void {
            if (self.pending_count != 0 or self.stored_count != 0 or self.crashed or self.stabilized_after_recover) {
                return error.InvalidInput;
            }
            if (recorded.pending.len > self.pending_storage.len) return error.NoSpaceLeft;
            if (recorded.stored.len > self.stored_storage.len) return error.NoSpaceLeft;
            try validateRecordedState(self.config, recorded);

            for (recorded.pending, 0..) |pending, index| {
                self.pending_storage[index] = pending;
            }
            for (recorded.stored, 0..) |stored, index| {
                self.stored_storage[index] = stored;
            }
            self.pending_count = recorded.pending.len;
            self.stored_count = recorded.stored.len;
            self.crashed = recorded.crashed;
            self.stabilized_after_recover = recorded.stabilized_after_recover;
        }

        pub fn isCrashed(self: *const Self) bool {
            return self.crashed;
        }

        fn materializeResult(
            self: *Self,
            pending: Pending,
        ) StorageDurabilityError!Result {
            return switch (pending.kind) {
                .write => self.materializeWriteResult(pending),
                .read => self.materializeReadResult(pending),
            };
        }

        fn materializeWriteResult(
            self: *Self,
            pending: Pending,
        ) StorageDurabilityError!Result {
            const write_persistence = self.effectiveWritePersistence();
            const write_corruption = self.effectiveWriteCorruption();
            const stored_slot_id = self.effectiveWriteSlotId(pending.slot_id);
            const stored_value = switch (write_corruption) {
                .none => pending.value.?,
                .fixed_value => |value| value,
            };
            if (write_persistence == .durable) {
                const slot_index = self.findStoredSlotIndex(stored_slot_id);
                if (slot_index) |index| {
                    self.stored_storage[index].value = stored_value;
                } else {
                    if (self.stored_count >= self.stored_storage.len) return error.NoSpaceLeft;
                    self.stored_storage[self.stored_count] = .{
                        .slot_id = stored_slot_id,
                        .value = stored_value,
                    };
                    self.stored_count += 1;
                }
            }
            return .{
                .request_id = pending.request_id,
                .kind = .write,
                .status = if (write_persistence == .acknowledge_without_store)
                    .success
                else if (write_corruption == .none and stored_slot_id == pending.slot_id)
                    .success
                else
                    .corrupted,
                .slot_id = pending.slot_id,
                .value = stored_value,
            };
        }

        fn materializeReadResult(
            self: *Self,
            pending: Pending,
        ) Result {
            const slot_index = self.findStoredSlotIndex(pending.slot_id) orelse return .{
                .request_id = pending.request_id,
                .kind = .read,
                .status = .missing,
                .slot_id = pending.slot_id,
                .value = null,
            };
            const stored_value = self.stored_storage[slot_index].value;
            return switch (self.effectiveReadCorruption()) {
                .none => .{
                    .request_id = pending.request_id,
                    .kind = .read,
                    .status = .success,
                    .slot_id = pending.slot_id,
                    .value = stored_value,
                },
                .fixed_value => |value| .{
                    .request_id = pending.request_id,
                    .kind = .read,
                    .status = .corrupted,
                    .slot_id = pending.slot_id,
                    .value = value,
                },
            };
        }

        fn effectiveWriteCorruption(self: *const Self) CorruptionPolicy(T) {
            if (self.stabilizedAfterRecover()) return .none;
            return self.config.write_corruption;
        }

        fn effectiveWritePersistence(self: *const Self) WritePersistencePolicy {
            if (self.stabilizedAfterRecover()) return .durable;
            return self.config.write_persistence;
        }

        fn effectiveWriteSlotId(self: *const Self, requested_slot_id: u32) u32 {
            if (self.stabilizedAfterRecover()) return requested_slot_id;
            return switch (self.config.write_placement) {
                .none => requested_slot_id,
                .fixed_slot => |slot_id| slot_id,
            };
        }

        fn effectiveReadCorruption(self: *const Self) CorruptionPolicy(T) {
            if (self.stabilizedAfterRecover()) return .none;
            return self.config.read_corruption;
        }

        fn stabilizedAfterRecover(self: *const Self) bool {
            return self.stabilized_after_recover and
                self.config.recoverability_policy == .stabilize_after_recover;
        }

        fn dropPendingWrites(self: *Self) u32 {
            var dropped_count: u32 = 0;
            var read_index: usize = 0;
            while (read_index < self.pending_count) {
                if (self.pending_storage[read_index].kind == .write) {
                    removePendingAt(self.pending_storage, &self.pending_count, read_index);
                    dropped_count += 1;
                    continue;
                }
                read_index += 1;
            }
            return dropped_count;
        }

        fn findStoredSlotIndex(self: *const Self, slot_id: u32) ?usize {
            for (self.stored_storage[0..self.stored_count], 0..) |stored, index| {
                if (stored.slot_id == slot_id) return index;
            }
            return null;
        }
    };
}

fn validateConfig(config: anytype) StorageDurabilityError!void {
    switch (config.write_placement) {
        .none => {},
        .fixed_slot => |slot_id| {
            if (slot_id == 0) return error.InvalidConfig;
        },
    }
}

fn validateRecordedState(
    config: anytype,
    recorded: anytype,
) StorageDurabilityError!void {
    if (recorded.crashed and recorded.stabilized_after_recover) return error.InvalidInput;
    if (recorded.stabilized_after_recover and config.recoverability_policy != .stabilize_after_recover) {
        return error.InvalidInput;
    }
    for (recorded.pending) |pending| {
        if (pending.request_id == 0) return error.InvalidInput;
        if (pending.slot_id == 0) return error.InvalidInput;
        switch (pending.kind) {
            .write => if (pending.value == null) return error.InvalidInput,
            .read => if (pending.value != null) return error.InvalidInput,
        }
    }
    for (recorded.stored) |stored| {
        if (stored.slot_id == 0) return error.InvalidInput;
    }
}

fn appendCrashTrace(
    trace_buffer: ?*trace.TraceBuffer,
    timestamp: clock.LogicalTime,
    dropped_write_count: u32,
) trace.TraceAppendError!void {
    if (trace_buffer) |buffer| {
        try buffer.append(.{
            .timestamp_ns = timestamp.tick,
            .category = .decision,
            .label = "storage_durability.crash",
            .value = dropped_write_count,
            .lineage = .{
                .surface_label = "storage_durability",
            },
        });
    }
}

fn appendRecoverTrace(
    trace_buffer: ?*trace.TraceBuffer,
    timestamp: clock.LogicalTime,
) trace.TraceAppendError!void {
    if (trace_buffer) |buffer| {
        try buffer.append(.{
            .timestamp_ns = timestamp.tick,
            .category = .decision,
            .label = "storage_durability.recover",
            .value = 1,
            .lineage = .{
                .surface_label = "storage_durability",
            },
        });
    }
}

fn appendResultTrace(
    trace_buffer: ?*trace.TraceBuffer,
    timestamp: clock.LogicalTime,
    result: anytype,
) trace.TraceAppendError!void {
    if (trace_buffer) |buffer| {
        try buffer.append(.{
            .timestamp_ns = timestamp.tick,
            .category = .check,
            .label = switch (result.kind) {
                .write => switch (result.status) {
                    .success => "storage_durability.write.success",
                    .missing => unreachable,
                    .corrupted => "storage_durability.write.corrupted",
                },
                .read => switch (result.status) {
                    .success => "storage_durability.read.success",
                    .missing => "storage_durability.read.missing",
                    .corrupted => "storage_durability.read.corrupted",
                },
            },
            .value = result.slot_id,
            .lineage = .{
                .correlation_id = result.request_id,
                .surface_label = "storage_durability",
            },
        });
    }
}

fn ensureDeliveryCanProceed(
    trace_buffer: ?*trace.TraceBuffer,
    completion_mailbox: anytype,
) (trace.TraceAppendError || mailbox.MailboxError)!void {
    if (trace_buffer) |buffer| {
        if (buffer.freeSlots() == 0) return error.NoSpaceLeft;
    }
    if (completion_mailbox.freeSlots() == 0) return error.NoSpaceLeft;
}

fn removePendingAt(
    storage: anytype,
    pending_count: *usize,
    index: usize,
) void {
    assert(index < pending_count.*);
    var cursor = index;
    while (cursor + 1 < pending_count.*) : (cursor += 1) {
        storage[cursor] = storage[cursor + 1];
    }
    pending_count.* -= 1;
}

test "storage durability drops pending writes across crash and allows recovery" {
    var pending_storage: [4]PendingOperation(u32) = undefined;
    var stored_storage: [4]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .crash_behavior = .drop_pending_writes,
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 4,
    });
    defer completions.deinit();

    try simulator.submitWrite(.init(0), 1, 9, 111);
    try testing.expectEqual(@as(usize, 1), simulator.pendingItems().len);

    try testing.expectEqual(@as(u32, 1), try simulator.crash(.init(0), null));
    try testing.expect(simulator.isCrashed());
    try testing.expectEqual(@as(usize, 0), simulator.pendingItems().len);
    try testing.expectError(error.Unavailable, simulator.submitRead(.init(0), 2, 9));

    try simulator.recover(.init(1), null);
    try testing.expect(!simulator.isCrashed());

    try simulator.submitRead(.init(1), 3, 9);
    const delivered = try simulator.deliverDueToMailbox(.init(2), &completions, null);
    try testing.expectEqual(@as(u32, 1), delivered.missing_count);
    const missing = try completions.recv();
    try testing.expectEqual(OperationKind.read, missing.kind);
    try testing.expectEqual(CompletionStatus.missing, missing.status);
    try testing.expect(missing.value == null);
}

test "storage durability supports write and read corruption policies" {
    var pending_storage: [4]PendingOperation(u32) = undefined;
    var stored_storage: [4]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .write_corruption = .{ .fixed_value = 7 },
        .read_corruption = .{ .fixed_value = 9 },
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 4,
    });
    defer completions.deinit();

    try simulator.submitWrite(.init(0), 1, 4, 100);
    const writes = try simulator.deliverDueToMailbox(.init(1), &completions, null);
    try testing.expectEqual(@as(u32, 1), writes.corrupted_count);
    const write_result = try completions.recv();
    try testing.expectEqual(CompletionStatus.corrupted, write_result.status);
    try testing.expectEqual(@as(u32, 7), write_result.value.?);

    try simulator.submitRead(.init(1), 2, 4);
    const reads = try simulator.deliverDueToMailbox(.init(2), &completions, null);
    try testing.expectEqual(@as(u32, 1), reads.corrupted_count);
    const read_result = try completions.recv();
    try testing.expectEqual(OperationKind.read, read_result.kind);
    try testing.expectEqual(CompletionStatus.corrupted, read_result.status);
    try testing.expectEqual(@as(u32, 9), read_result.value.?);
}

test "storage durability can stabilize reads and writes after recover" {
    var pending_storage: [6]PendingOperation(u32) = undefined;
    var stored_storage: [4]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 7 },
        .read_corruption = .{ .fixed_value = 9 },
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 6,
    });
    defer completions.deinit();

    try simulator.submitWrite(.init(0), 1, 4, 100);
    _ = try simulator.deliverDueToMailbox(.init(1), &completions, null);
    const fault_phase_write = try completions.recv();
    try testing.expectEqual(CompletionStatus.corrupted, fault_phase_write.status);
    try testing.expectEqual(@as(u32, 7), fault_phase_write.value.?);

    _ = try simulator.crash(.init(1), null);
    try simulator.recover(.init(2), null);

    try simulator.submitWrite(.init(2), 2, 4, 200);
    _ = try simulator.deliverDueToMailbox(.init(3), &completions, null);
    const repair_write = try completions.recv();
    try testing.expectEqual(CompletionStatus.success, repair_write.status);
    try testing.expectEqual(@as(u32, 200), repair_write.value.?);

    try simulator.submitRead(.init(3), 3, 4);
    _ = try simulator.deliverDueToMailbox(.init(4), &completions, null);
    const repair_read = try completions.recv();
    try testing.expectEqual(OperationKind.read, repair_read.kind);
    try testing.expectEqual(CompletionStatus.success, repair_read.status);
    try testing.expectEqual(@as(u32, 200), repair_read.value.?);
}

test "storage durability does not stabilize faults before the first crash" {
    var pending_storage: [6]PendingOperation(u32) = undefined;
    var stored_storage: [4]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 7 },
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 6,
    });
    defer completions.deinit();

    try simulator.recover(.init(0), null);
    try simulator.submitWrite(.init(0), 1, 4, 100);
    _ = try simulator.deliverDueToMailbox(.init(1), &completions, null);
    const fault_phase_write = try completions.recv();
    try testing.expectEqual(CompletionStatus.corrupted, fault_phase_write.status);
    try testing.expectEqual(@as(u32, 7), fault_phase_write.value.?);

    _ = try simulator.crash(.init(1), null);
    try simulator.recover(.init(2), null);
    try simulator.submitWrite(.init(2), 2, 4, 200);
    _ = try simulator.deliverDueToMailbox(.init(3), &completions, null);
    const repair_write = try completions.recv();
    try testing.expectEqual(CompletionStatus.success, repair_write.status);
    try testing.expectEqual(@as(u32, 200), repair_write.value.?);
}

test "storage durability supports misdirected write placement faults and repair-phase stabilization" {
    var pending_storage: [8]PendingOperation(u32) = undefined;
    var stored_storage: [4]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_placement = .{ .fixed_slot = 9 },
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 8,
    });
    defer completions.deinit();

    try simulator.submitWrite(.init(0), 1, 4, 100);
    const fault_summary = try simulator.deliverDueToMailbox(.init(1), &completions, null);
    try testing.expectEqual(@as(u32, 1), fault_summary.corrupted_count);
    const fault_write = try completions.recv();
    try testing.expectEqual(CompletionStatus.corrupted, fault_write.status);
    try testing.expectEqual(@as(u32, 100), fault_write.value.?);
    try testing.expectEqual(@as(usize, 1), simulator.storedItems().len);
    try testing.expectEqual(@as(u32, 9), simulator.storedItems()[0].slot_id);
    try testing.expectEqual(@as(u32, 100), simulator.storedItems()[0].value);

    try simulator.submitRead(.init(1), 2, 4);
    const missing_summary = try simulator.deliverDueToMailbox(.init(2), &completions, null);
    try testing.expectEqual(@as(u32, 1), missing_summary.missing_count);
    try testing.expectEqual(CompletionStatus.missing, (try completions.recv()).status);

    try simulator.submitRead(.init(2), 3, 9);
    const redirected_summary = try simulator.deliverDueToMailbox(.init(3), &completions, null);
    try testing.expectEqual(@as(u32, 1), redirected_summary.read_success_count);
    const redirected_read = try completions.recv();
    try testing.expectEqual(CompletionStatus.success, redirected_read.status);
    try testing.expectEqual(@as(u32, 100), redirected_read.value.?);

    _ = try simulator.crash(.init(3), null);
    try simulator.recover(.init(4), null);
    try simulator.submitWrite(.init(4), 4, 4, 222);
    const repair_summary = try simulator.deliverDueToMailbox(.init(5), &completions, null);
    try testing.expectEqual(@as(u32, 1), repair_summary.write_success_count);
    const repair_write = try completions.recv();
    try testing.expectEqual(CompletionStatus.success, repair_write.status);
    try testing.expectEqual(@as(u32, 222), repair_write.value.?);

    try simulator.submitRead(.init(5), 5, 4);
    const repair_read_summary = try simulator.deliverDueToMailbox(.init(6), &completions, null);
    try testing.expectEqual(@as(u32, 1), repair_read_summary.read_success_count);
    const repair_read = try completions.recv();
    try testing.expectEqual(CompletionStatus.success, repair_read.status);
    try testing.expectEqual(@as(u32, 222), repair_read.value.?);
}

test "storage durability supports acknowledged-but-not-durable writes and repair-phase stabilization" {
    var pending_storage: [8]PendingOperation(u32) = undefined;
    var stored_storage: [4]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_persistence = .acknowledge_without_store,
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 8,
    });
    defer completions.deinit();

    try simulator.submitWrite(.init(0), 1, 4, 100);
    const omission_summary = try simulator.deliverDueToMailbox(.init(1), &completions, null);
    try testing.expectEqual(@as(u32, 1), omission_summary.write_success_count);
    const omitted_write = try completions.recv();
    try testing.expectEqual(CompletionStatus.success, omitted_write.status);
    try testing.expectEqual(@as(u32, 100), omitted_write.value.?);
    try testing.expectEqual(@as(usize, 0), simulator.storedItems().len);

    try simulator.submitRead(.init(1), 2, 4);
    const missing_summary = try simulator.deliverDueToMailbox(.init(2), &completions, null);
    try testing.expectEqual(@as(u32, 1), missing_summary.missing_count);
    try testing.expectEqual(CompletionStatus.missing, (try completions.recv()).status);

    _ = try simulator.crash(.init(2), null);
    try simulator.recover(.init(3), null);
    try simulator.submitWrite(.init(3), 3, 4, 222);
    const repair_summary = try simulator.deliverDueToMailbox(.init(4), &completions, null);
    try testing.expectEqual(@as(u32, 1), repair_summary.write_success_count);
    const repair_write = try completions.recv();
    try testing.expectEqual(CompletionStatus.success, repair_write.status);
    try testing.expectEqual(@as(u32, 222), repair_write.value.?);
    try testing.expectEqual(@as(usize, 1), simulator.storedItems().len);
    try testing.expectEqual(@as(u32, 222), simulator.storedItems()[0].value);

    try simulator.submitRead(.init(4), 4, 4);
    const repair_read_summary = try simulator.deliverDueToMailbox(.init(5), &completions, null);
    try testing.expectEqual(@as(u32, 1), repair_read_summary.read_success_count);
    const repair_read = try completions.recv();
    try testing.expectEqual(CompletionStatus.success, repair_read.status);
    try testing.expectEqual(@as(u32, 222), repair_read.value.?);
}

test "storage durability can record and replay pending operations plus stored state" {
    var source_pending_storage: [6]PendingOperation(u32) = undefined;
    var source_stored_storage: [4]StoredValue(u32) = undefined;
    var source = try StorageDurability(u32).init(&source_pending_storage, &source_stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 7 },
        .read_corruption = .{ .fixed_value = 9 },
    });
    var source_completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 6,
    });
    defer source_completions.deinit();

    try source.submitWrite(.init(0), 1, 4, 100);
    _ = try source.deliverDueToMailbox(.init(1), &source_completions, null);
    const initial_write = try source_completions.recv();
    try testing.expectEqual(CompletionStatus.corrupted, initial_write.status);
    try testing.expectEqual(@as(u32, 7), initial_write.value.?);

    _ = try source.crash(.init(1), null);
    try source.recover(.init(2), null);
    try source.submitWrite(.init(2), 2, 8, 222);
    try source.submitRead(.init(2), 3, 4);

    var recorded_pending: [6]PendingOperation(u32) = undefined;
    var recorded_stored: [4]StoredValue(u32) = undefined;
    const recorded = try source.recordState(&recorded_pending, &recorded_stored);
    try testing.expectEqual(@as(usize, 2), recorded.pending.len);
    try testing.expectEqual(@as(usize, 1), recorded.stored.len);
    try testing.expect(!recorded.crashed);
    try testing.expect(recorded.stabilized_after_recover);
    try testing.expectEqual(@as(u32, 7), recorded.stored[0].value);

    var replay_pending_storage: [6]PendingOperation(u32) = undefined;
    var replay_stored_storage: [4]StoredValue(u32) = undefined;
    var replay = try StorageDurability(u32).init(&replay_pending_storage, &replay_stored_storage, .{
        .write_delay = .init(5),
        .read_delay = .init(5),
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 700 },
        .read_corruption = .{ .fixed_value = 900 },
    });
    try replay.replayRecordedState(recorded);
    try testing.expect(!replay.isCrashed());

    var replay_completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 6,
    });
    defer replay_completions.deinit();
    const replay_summary = try replay.deliverDueToMailbox(.init(3), &replay_completions, null);
    try testing.expectEqual(@as(u32, 1), replay_summary.write_success_count);
    try testing.expectEqual(@as(u32, 1), replay_summary.read_success_count);

    const replay_write = try replay_completions.recv();
    try testing.expectEqual(OperationKind.write, replay_write.kind);
    try testing.expectEqual(CompletionStatus.success, replay_write.status);
    try testing.expectEqual(@as(u32, 222), replay_write.value.?);

    const replay_read = try replay_completions.recv();
    try testing.expectEqual(OperationKind.read, replay_read.kind);
    try testing.expectEqual(CompletionStatus.success, replay_read.status);
    try testing.expectEqual(@as(u32, 7), replay_read.value.?);
}

test "storage durability traces crash recover and operation outcomes" {
    var pending_storage: [4]PendingOperation(u32) = undefined;
    var stored_storage: [4]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 4,
    });
    defer completions.deinit();
    var trace_storage: [8]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 8 });

    try simulator.submitWrite(.init(0), 1, 8, 55);
    _ = try simulator.crash(.init(0), &trace_buffer);
    try simulator.recover(.init(1), &trace_buffer);
    try simulator.submitWrite(.init(1), 2, 8, 66);
    _ = try simulator.deliverDueToMailbox(.init(2), &completions, &trace_buffer);

    const snapshot = trace_buffer.snapshot();
    try testing.expectEqualStrings("storage_durability.crash", snapshot.items[0].label);
    try testing.expectEqualStrings("storage_durability.recover", snapshot.items[1].label);
    try testing.expectEqualStrings("storage_durability.write.success", snapshot.items[2].label);
}

test "storage durability replay rejects non-empty state and invalid recorded inputs" {
    var pending_storage: [3]PendingOperation(u32) = undefined;
    var stored_storage: [2]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
    });
    try simulator.submitWrite(.init(0), 1, 4, 55);

    const valid_recorded = RecordedState(u32){
        .pending = &[_]PendingOperation(u32){
            .{
                .due_time = .init(1),
                .request_id = 1,
                .kind = .write,
                .slot_id = 4,
                .value = 55,
            },
        },
        .stored = &[_]StoredValue(u32){},
        .crashed = false,
        .stabilized_after_recover = false,
    };
    try testing.expectError(error.InvalidInput, simulator.replayRecordedState(valid_recorded));

    var empty_pending_storage: [1]PendingOperation(u32) = undefined;
    var empty_stored_storage: [1]StoredValue(u32) = undefined;
    var empty = try StorageDurability(u32).init(&empty_pending_storage, &empty_stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
    });
    const invalid_recorded = RecordedState(u32){
        .pending = &[_]PendingOperation(u32){
            .{
                .due_time = .init(1),
                .request_id = 0,
                .kind = .write,
                .slot_id = 4,
                .value = 55,
            },
        },
        .stored = &[_]StoredValue(u32){},
        .crashed = false,
        .stabilized_after_recover = false,
    };
    try testing.expectError(error.InvalidInput, empty.replayRecordedState(invalid_recorded));

    const invalid_stabilized = RecordedState(u32){
        .pending = &[_]PendingOperation(u32){},
        .stored = &[_]StoredValue(u32){},
        .crashed = false,
        .stabilized_after_recover = true,
    };
    try testing.expectError(error.InvalidInput, empty.replayRecordedState(invalid_stabilized));

    var too_small_pending: [0]PendingOperation(u32) = .{};
    var too_small_stored: [0]StoredValue(u32) = .{};
    try testing.expectError(error.NoSpaceLeft, simulator.recordState(&too_small_pending, &too_small_stored));
}

test "storage durability rejects read submissions that carry a payload" {
    var pending_storage: [2]PendingOperation(u32) = undefined;
    var stored_storage: [2]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
    });

    try testing.expectError(error.InvalidInput, simulator.submitAfter(.init(0), .init(1), .{
        .request_id = 1,
        .kind = .read,
        .slot_id = 4,
        .value = 99,
    }));
    try testing.expectEqual(@as(usize, 0), simulator.pendingItems().len);
}

test "storage durability leaves operations pending when trace capacity is exhausted" {
    var pending_storage: [4]PendingOperation(u32) = undefined;
    var stored_storage: [4]StoredValue(u32) = undefined;
    var simulator = try StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
    });
    var completions = try mailbox.Mailbox(OperationResult(u32)).init(testing.allocator, .{
        .capacity = 4,
    });
    defer completions.deinit();
    var trace_storage: [1]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 1 });
    try trace_buffer.append(.{
        .timestamp_ns = 0,
        .category = .info,
        .label = "prefill",
        .value = 0,
    });

    try simulator.submitWrite(.init(0), 1, 8, 55);
    try testing.expectError(
        error.NoSpaceLeft,
        simulator.deliverDueToMailbox(.init(1), &completions, &trace_buffer),
    );
    try testing.expectEqual(@as(usize, 1), simulator.pendingItems().len);
    try testing.expectEqual(@as(usize, 0), completions.len());
    try testing.expectEqual(@as(usize, 0), simulator.storedItems().len);

    trace_buffer.reset();
    const delivered = try simulator.deliverDueToMailbox(.init(1), &completions, &trace_buffer);
    try testing.expectEqual(@as(u32, 1), delivered.write_success_count);
    try testing.expectEqual(@as(usize, 0), simulator.pendingItems().len);
    try testing.expectEqual(@as(usize, 1), simulator.storedItems().len);
    try testing.expectEqual(CompletionStatus.success, (try completions.recv()).status);
}

test "storage durability rejects invalid write placement config" {
    var pending_storage: [1]PendingOperation(u32) = undefined;
    var stored_storage: [1]StoredValue(u32) = undefined;
    try testing.expectError(error.InvalidConfig, StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .write_placement = .{ .fixed_slot = 0 },
    }));
}
