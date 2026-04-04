//! Deterministic ready-set scheduler and replayable decision recorder.
//!
//! Trace output intentionally records only the chosen ready-item id. The full
//! replay contract already persists `ScheduleDecision`, so duplicating
//! `chosen_index`, `ready_len`, and `chosen_value` in the trace would increase
//! per-step trace cost without improving replay fidelity.

const std = @import("std");
const seed_mod = @import("../seed.zig");
const trace = @import("../trace.zig");

/// Public scheduler operating errors.
pub const SchedulerError = error{
    InvalidConfig,
    InvalidInput,
    NoSpaceLeft,
    Mismatch,
};

/// Deterministic ready item.
pub const ReadyItem = struct {
    id: u32,
    value: u64 = 0,
};

/// Ready-set choice strategy.
pub const SchedulerStrategy = enum(u8) {
    first = 1,
    seeded = 2,
    pct_bias = 3,
};

/// Scheduler setup options.
pub const SchedulerConfig = struct {
    strategy: SchedulerStrategy = .seeded,
    pct_preemption_step: u32 = 0,
};

/// Stable schedule metadata suitable for persistence and replay tooling.
pub const ScheduleMetadata = struct {
    mode_label: []const u8,
    schedule_seed: ?seed_mod.Seed = null,
};

/// Recorded schedule decision used for replay.
pub const ScheduleDecision = struct {
    step_index: u32,
    chosen_index: u32,
    ready_len: u32,
    chosen_id: u32,
    chosen_value: u64,
};

/// Deterministic scheduler over a caller-owned ready buffer.
pub const Scheduler = struct {
    base_seed: seed_mod.Seed,
    config: SchedulerConfig,
    ready_storage: []ReadyItem,
    decision_storage: []ScheduleDecision,
    trace_buffer: ?*trace.TraceBuffer = null,
    ready_len: usize = 0,
    decision_count: usize = 0,

    /// Construct one scheduler over caller-owned ready and decision storage.
    pub fn init(
        base_seed: seed_mod.Seed,
        ready_storage: []ReadyItem,
        decision_storage: []ScheduleDecision,
        config: SchedulerConfig,
        trace_buffer: ?*trace.TraceBuffer,
    ) SchedulerError!Scheduler {
        if (ready_storage.len == 0) return error.InvalidConfig;
        return .{
            .base_seed = base_seed,
            .config = config,
            .ready_storage = ready_storage,
            .decision_storage = decision_storage,
            .trace_buffer = trace_buffer,
        };
    }

    /// Enqueue one ready item at the tail of the current ready set.
    pub fn enqueueReady(self: *Scheduler, ready_item: ReadyItem) SchedulerError!void {
        if (self.ready_len >= self.ready_storage.len) return error.NoSpaceLeft;
        self.ready_storage[self.ready_len] = ready_item;
        self.ready_len += 1;
        std.debug.assert(self.ready_len <= self.ready_storage.len);
    }

    /// Report whether at least one ready item is available to schedule.
    pub fn hasReady(self: *const Scheduler) bool {
        return self.ready_len != 0;
    }

    /// Report the current number of ready items.
    pub fn readyCount(self: *const Scheduler) usize {
        return self.ready_len;
    }

    /// Report how many more ready items can be enqueued without overflow.
    pub fn remainingReadyCapacity(self: *const Scheduler) usize {
        std.debug.assert(self.ready_len <= self.ready_storage.len);
        return self.ready_storage.len - self.ready_len;
    }

    /// View the prefix of decisions recorded so far.
    pub fn recordedDecisions(self: *const Scheduler) []const ScheduleDecision {
        return self.decision_storage[0..self.decision_count];
    }

    /// Validate that one next-decision recording would fit without mutating state.
    pub fn ensureNextDecisionCapacity(
        self: *const Scheduler,
        ready_len_total: usize,
    ) SchedulerError!void {
        if (ready_len_total == 0) return error.InvalidInput;
        if (ready_len_total > self.ready_storage.len) return error.NoSpaceLeft;
        if (self.decision_count >= self.decision_storage.len) return error.NoSpaceLeft;
        if (self.trace_buffer) |trace_buffer| {
            if (trace_buffer.freeSlots() == 0) return error.NoSpaceLeft;
        }
    }

    /// Choose the next ready item, record the decision, and remove it from the ready set.
    pub fn nextDecision(self: *Scheduler) SchedulerError!ScheduleDecision {
        try self.ensureNextDecisionCapacity(self.ready_len);

        const step_index: u32 = @intCast(self.decision_count);
        const chosen_index = try chooseReadyIndex(self.base_seed, step_index, self.config, self.ready_len);
        const ready_item = self.ready_storage[chosen_index];
        const decision = ScheduleDecision{
            .step_index = step_index,
            .chosen_index = @as(u32, @intCast(chosen_index)),
            .ready_len = @as(u32, @intCast(self.ready_len)),
            .chosen_id = ready_item.id,
            .chosen_value = ready_item.value,
        };

        try appendTrace(self.trace_buffer, decision);
        self.decision_storage[self.decision_count] = decision;
        self.decision_count += 1;
        removeReadyAt(self.ready_storage, &self.ready_len, chosen_index);
        return decision;
    }

    /// Apply one replayed decision against the current ready set.
    pub fn applyRecordedDecision(
        self: *Scheduler,
        recorded: ScheduleDecision,
    ) SchedulerError!ScheduleDecision {
        try self.ensureNextDecisionCapacity(self.ready_len);
        if (recorded.step_index != self.decision_count) return error.Mismatch;
        if (recorded.ready_len != self.ready_len) return error.Mismatch;
        if (recorded.chosen_index >= self.ready_len) return error.Mismatch;

        const chosen_index: usize = @intCast(recorded.chosen_index);
        const ready_item = self.ready_storage[chosen_index];
        if (ready_item.id != recorded.chosen_id) return error.Mismatch;
        if (ready_item.value != recorded.chosen_value) return error.Mismatch;

        try appendTrace(self.trace_buffer, recorded);
        self.decision_storage[self.decision_count] = recorded;
        self.decision_count += 1;
        removeReadyAt(self.ready_storage, &self.ready_len, chosen_index);
        return recorded;
    }
};

/// Describe the current scheduler mode in a form safe to persist in artifacts.
pub fn describeSchedule(base_seed: seed_mod.Seed, config: SchedulerConfig) ScheduleMetadata {
    return switch (config.strategy) {
        .first => .{
            .mode_label = "first",
            .schedule_seed = null,
        },
        .seeded => .{
            .mode_label = "seeded",
            .schedule_seed = base_seed,
        },
        .pct_bias => .{
            .mode_label = "pct_bias",
            .schedule_seed = base_seed,
        },
    };
}

fn chooseReadyIndex(
    base_seed: seed_mod.Seed,
    step_index: u32,
    config: SchedulerConfig,
    ready_len: usize,
) SchedulerError!usize {
    if (ready_len == 0) return error.InvalidInput;

    return switch (config.strategy) {
        .first => 0,
        .seeded => blk: {
            const stream_seed = seed_mod.splitSeed(base_seed, step_index);
            break :blk @as(usize, @intCast(stream_seed.value % ready_len));
        },
        .pct_bias => blk: {
            if (step_index != config.pct_preemption_step or ready_len == 1) break :blk 0;

            const stream_seed = seed_mod.splitSeed(base_seed, step_index);
            const alternate_len = ready_len - 1;
            std.debug.assert(alternate_len != 0);
            break :blk 1 + @as(usize, @intCast(stream_seed.value % alternate_len));
        },
    };
}

fn removeReadyAt(ready_storage: []ReadyItem, ready_len: *usize, chosen_index: usize) void {
    std.debug.assert(chosen_index < ready_len.*);

    var index = chosen_index;
    while (index + 1 < ready_len.*) : (index += 1) {
        ready_storage[index] = ready_storage[index + 1];
    }
    ready_len.* -= 1;
}

fn appendTrace(trace_buffer: ?*trace.TraceBuffer, decision: ScheduleDecision) SchedulerError!void {
    if (trace_buffer) |buffer| {
        buffer.append(.{
            .timestamp_ns = decision.step_index,
            .category = .decision,
            .label = "scheduler.decision",
            .value = decision.chosen_id,
        }) catch |err| switch (err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.NoSpaceLeft => return error.NoSpaceLeft,
        };
    }
}

test "scheduler produces deterministic decisions from the same seed" {
    // Method: Run two independent schedulers from the same seed and ready set
    // so the first chosen id proves deterministic stream splitting.
    var ready_a: [3]ReadyItem = undefined;
    var decisions_a: [3]ScheduleDecision = undefined;
    var scheduler_a = try Scheduler.init(.init(1234), &ready_a, &decisions_a, .{}, null);
    try scheduler_a.enqueueReady(.{ .id = 10 });
    try scheduler_a.enqueueReady(.{ .id = 20 });
    try scheduler_a.enqueueReady(.{ .id = 30 });

    var ready_b: [3]ReadyItem = undefined;
    var decisions_b: [3]ScheduleDecision = undefined;
    var scheduler_b = try Scheduler.init(.init(1234), &ready_b, &decisions_b, .{}, null);
    try scheduler_b.enqueueReady(.{ .id = 10 });
    try scheduler_b.enqueueReady(.{ .id = 20 });
    try scheduler_b.enqueueReady(.{ .id = 30 });

    const first_a = try scheduler_a.nextDecision();
    const first_b = try scheduler_b.nextDecision();
    try std.testing.expectEqual(first_a.chosen_id, first_b.chosen_id);
}

test "scheduler replays recorded decisions against the same ready set" {
    // Method: Record one decision and replay it against a matching ready set so
    // the replay contract is exercised independently of seed choice.
    var ready_record: [2]ReadyItem = undefined;
    var decisions_record: [2]ScheduleDecision = undefined;
    var recorder = try Scheduler.init(.init(7), &ready_record, &decisions_record, .{}, null);
    try recorder.enqueueReady(.{ .id = 1, .value = 100 });
    try recorder.enqueueReady(.{ .id = 2, .value = 200 });

    const recorded = try recorder.nextDecision();

    var ready_replay: [2]ReadyItem = undefined;
    var decisions_replay: [2]ScheduleDecision = undefined;
    var replayer = try Scheduler.init(.init(999), &ready_replay, &decisions_replay, .{}, null);
    try replayer.enqueueReady(.{ .id = 1, .value = 100 });
    try replayer.enqueueReady(.{ .id = 2, .value = 200 });

    const replayed = try replayer.applyRecordedDecision(recorded);
    try std.testing.expectEqual(recorded.chosen_id, replayed.chosen_id);
    try std.testing.expectEqual(@as(usize, 1), replayer.readyCount());
}

test "scheduler rejects replay mismatches" {
    // Method: Keep the recorded shape plausible while changing the chosen id so
    // mismatch detection is pinned to semantic replay validation.
    var ready_storage: [2]ReadyItem = undefined;
    var decision_storage: [1]ScheduleDecision = undefined;
    var scheduler = try Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    try scheduler.enqueueReady(.{ .id = 3, .value = 1 });
    try scheduler.enqueueReady(.{ .id = 4, .value = 2 });

    try std.testing.expectError(error.Mismatch, scheduler.applyRecordedDecision(.{
        .step_index = 0,
        .chosen_index = 1,
        .ready_len = 2,
        .chosen_id = 99,
        .chosen_value = 2,
    }));
}

test "scheduler rejects replay decisions for the wrong step index" {
    // Method: Reuse a valid one-item ready set and vary only the replay step
    // index so the step counter contract is checked directly.
    var ready_storage: [1]ReadyItem = undefined;
    var decision_storage: [1]ScheduleDecision = undefined;
    var scheduler = try Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    try scheduler.enqueueReady(.{ .id = 7, .value = 1 });

    try std.testing.expectError(error.Mismatch, scheduler.applyRecordedDecision(.{
        .step_index = 1,
        .chosen_index = 0,
        .ready_len = 1,
        .chosen_id = 7,
        .chosen_value = 1,
    }));
}

test "scheduler trace records only the chosen id" {
    // Method: Attach a trace buffer and schedule with `.first` so the emitted
    // trace payload can be asserted without seeded-choice variance.
    var ready_storage: [2]ReadyItem = undefined;
    var decision_storage: [2]ScheduleDecision = undefined;
    var trace_storage: [2]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 2 });
    var scheduler = try Scheduler.init(.init(1), &ready_storage, &decision_storage, .{
        .strategy = .first,
    }, &trace_buffer);
    try scheduler.enqueueReady(.{ .id = 7, .value = 100 });
    try scheduler.enqueueReady(.{ .id = 9, .value = 200 });

    const decision = try scheduler.nextDecision();
    const snapshot = trace_buffer.snapshot();

    try std.testing.expectEqual(@as(u32, 7), decision.chosen_id);
    try std.testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try std.testing.expectEqualStrings("scheduler.decision", snapshot.items[0].label);
    try std.testing.expectEqual(@as(u64, 7), snapshot.items[0].value);
}

test "scheduler leaves state unchanged when trace append fails" {
    // Method: Exhaust the trace buffer between two decisions so the second call
    // proves state rollback when trace recording cannot proceed.
    var ready_storage: [2]ReadyItem = undefined;
    var decision_storage: [2]ScheduleDecision = undefined;
    var trace_storage: [1]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 1 });
    var scheduler = try Scheduler.init(.init(1), &ready_storage, &decision_storage, .{
        .strategy = .first,
    }, &trace_buffer);
    try scheduler.enqueueReady(.{ .id = 1, .value = 10 });
    try scheduler.enqueueReady(.{ .id = 2, .value = 20 });

    _ = try scheduler.nextDecision();
    try std.testing.expectEqual(@as(usize, 1), scheduler.recordedDecisions().len);
    try std.testing.expectEqual(@as(usize, 1), scheduler.readyCount());

    try std.testing.expectError(error.NoSpaceLeft, scheduler.nextDecision());
    try std.testing.expectEqual(@as(usize, 1), scheduler.recordedDecisions().len);
    try std.testing.expectEqual(@as(usize, 1), scheduler.readyCount());

    trace_buffer.reset();
    const replayed = try scheduler.nextDecision();
    try std.testing.expectEqual(@as(u32, 2), replayed.chosen_id);
    try std.testing.expectEqual(@as(usize, 2), scheduler.recordedDecisions().len);
    try std.testing.expectEqual(@as(usize, 0), scheduler.readyCount());
}

test "describeSchedule reports persisted mode metadata" {
    const first_metadata = describeSchedule(.init(11), .{
        .strategy = .first,
    });
    const seeded_metadata = describeSchedule(.init(22), .{
        .strategy = .seeded,
    });
    const pct_metadata = describeSchedule(.init(33), .{
        .strategy = .pct_bias,
        .pct_preemption_step = 1,
    });

    try std.testing.expectEqualStrings("first", first_metadata.mode_label);
    try std.testing.expect(first_metadata.schedule_seed == null);
    try std.testing.expectEqualStrings("seeded", seeded_metadata.mode_label);
    try std.testing.expect(seeded_metadata.schedule_seed != null);
    try std.testing.expectEqual(@as(u64, 22), seeded_metadata.schedule_seed.?.value);
    try std.testing.expectEqualStrings("pct_bias", pct_metadata.mode_label);
    try std.testing.expect(pct_metadata.schedule_seed != null);
    try std.testing.expectEqual(@as(u64, 33), pct_metadata.schedule_seed.?.value);
}

test "pct bias chooses a non-first ready item only on its configured preemption step" {
    var ready_storage: [3]ReadyItem = undefined;
    var decision_storage: [3]ScheduleDecision = undefined;
    var pct_scheduler = try Scheduler.init(.init(19), &ready_storage, &decision_storage, .{
        .strategy = .pct_bias,
        .pct_preemption_step = 1,
    }, null);
    try pct_scheduler.enqueueReady(.{ .id = 10, .value = 1 });
    try pct_scheduler.enqueueReady(.{ .id = 20, .value = 2 });
    try pct_scheduler.enqueueReady(.{ .id = 30, .value = 3 });

    const first = try pct_scheduler.nextDecision();
    const second = try pct_scheduler.nextDecision();

    try std.testing.expectEqual(@as(u32, 10), first.chosen_id);
    try std.testing.expectEqual(@as(u32, 1), second.step_index);
    try std.testing.expect(second.chosen_index != 0);
    try std.testing.expect(second.chosen_id != 20);
}
