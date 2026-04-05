//! Event-driven deterministic simulation coordinator.
//!
//! The event loop composes four primitives:
//! - logical time;
//! - delayed ready-item delivery;
//! - deterministic ready-set scheduling; and
//! - deterministic fault scripts.
//!
//! Fault scripts are observational in the current phase. Due faults contribute
//! to the step result and optional trace output, but they do not yet mutate
//! timer or scheduler behavior directly.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const trace = @import("../trace.zig");
const clock = @import("clock.zig");
const scheduler = @import("scheduler.zig");
const timer_queue = @import("timer_queue.zig");
const fault_script = @import("fault_script.zig");

/// Public event loop operating errors.
pub const EventLoopError = error{
    InvalidConfig,
} || clock.SimClockError || timer_queue.TimerQueueError || scheduler.SchedulerError || fault_script.FaultScriptError;

/// Explicit stop reasons for bounded simulation runs.
pub const StopReason = enum(u8) {
    reached_target_time = 1,
    step_budget_exhausted = 2,
    idle = 3,
};

/// Event loop setup options.
pub const EventLoopConfig = struct {
    step_budget_max: u32,
};

/// Result of one explicit simulation step.
pub const StepResult = struct {
    progress_made: bool,
    time_advanced: bool,
    ready_enqueued_count: u32,
    fault_count: u32,
    decision: ?scheduler.ScheduleDecision,
};

/// Result of a bounded multi-step run.
pub const RunResult = struct {
    steps_run: u32,
    reason: StopReason,
};

/// Event loop over timer-delivered scheduler items.
pub const EventLoop = struct {
    config: EventLoopConfig,
    sim_clock: *clock.SimClock,
    scheduler: *scheduler.Scheduler,
    timer_queue: *timer_queue.TimerQueue(scheduler.ReadyItem),
    fault_script: *fault_script.FaultScript,
    trace_buffer: ?*trace.TraceBuffer,

    pub fn init(
        config: EventLoopConfig,
        sim_clock: *clock.SimClock,
        sim_scheduler: *scheduler.Scheduler,
        sim_timer_queue: *timer_queue.TimerQueue(scheduler.ReadyItem),
        sim_fault_script: *fault_script.FaultScript,
        trace_buffer: ?*trace.TraceBuffer,
    ) EventLoopError!EventLoop {
        if (config.step_budget_max == 0) return error.InvalidConfig;
        return .{
            .config = config,
            .sim_clock = sim_clock,
            .scheduler = sim_scheduler,
            .timer_queue = sim_timer_queue,
            .fault_script = sim_fault_script,
            .trace_buffer = trace_buffer,
        };
    }

    pub fn step(
        self: *EventLoop,
        timer_buffer: []scheduler.ReadyItem,
    ) EventLoopError!StepResult {
        const now_time = self.sim_clock.now();
        const due_faults = self.fault_script.peekDueAt(now_time);
        const due_timer_count = self.timer_queue.dueCountUpTo(now_time);
        if (due_timer_count > timer_buffer.len) return error.NoSpaceLeft;
        if (due_timer_count > self.scheduler.remainingReadyCapacity()) return error.NoSpaceLeft;

        const ready_total = self.scheduler.readyCount() + due_timer_count;
        const jump_target_time = if (ready_total == 0)
            self.nextDueTimeAfterDueFaults(now_time)
        else
            null;

        const event_trace_count: usize = if (self.trace_buffer != null)
            due_faults.len + @as(usize, if (jump_target_time != null) 1 else 0)
        else
            0;
        const decision_trace_count: usize = if (ready_total != 0 and self.scheduler.trace_buffer != null) 1 else 0;
        try ensureTraceCapacity(self, event_trace_count, decision_trace_count);
        if (ready_total != 0) {
            try self.scheduler.ensureNextDecisionCapacity(ready_total);
        }

        try appendFaultTrace(self.trace_buffer, due_faults);
        const consumed_faults = self.fault_script.nextFaultsAt(now_time);
        assert(consumed_faults.len == due_faults.len);

        const ready_enqueued_count = if (due_timer_count == 0)
            @as(u32, 0)
        else
            try self.timer_queue.drainDue(timer_buffer);
        assert(ready_enqueued_count == @as(u32, @intCast(due_timer_count)));

        var ready_index: usize = 0;
        while (ready_index < ready_enqueued_count) : (ready_index += 1) {
            self.scheduler.enqueueReady(timer_buffer[ready_index]) catch unreachable;
        }

        if (ready_total != 0) {
            const decision = self.scheduler.nextDecision() catch unreachable;
            return .{
                .progress_made = true,
                .time_advanced = false,
                .ready_enqueued_count = ready_enqueued_count,
                .fault_count = @as(u32, @intCast(due_faults.len)),
                .decision = decision,
            };
        }

        if (jump_target_time) |target_time| {
            try appendJumpTrace(self.trace_buffer, target_time);
            const jumped_time = self.sim_clock.jumpTo(target_time) catch unreachable;
            assert(jumped_time.tick == target_time.tick);
            return .{
                .progress_made = true,
                .time_advanced = true,
                .ready_enqueued_count = ready_enqueued_count,
                .fault_count = @as(u32, @intCast(due_faults.len)),
                .decision = null,
            };
        }

        return .{
            .progress_made = due_faults.len != 0 or ready_enqueued_count != 0,
            .time_advanced = false,
            .ready_enqueued_count = ready_enqueued_count,
            .fault_count = @as(u32, @intCast(due_faults.len)),
            .decision = null,
        };
    }

    pub fn runForSteps(
        self: *EventLoop,
        steps_max: u32,
        timer_buffer: []scheduler.ReadyItem,
    ) EventLoopError!RunResult {
        const step_limit = @min(steps_max, self.config.step_budget_max);
        var steps_run: u32 = 0;
        while (steps_run < step_limit) : (steps_run += 1) {
            const step_result = try self.step(timer_buffer);
            if (!step_result.progress_made) {
                return .{
                    .steps_run = steps_run,
                    .reason = .idle,
                };
            }
        }
        return .{
            .steps_run = step_limit,
            .reason = .step_budget_exhausted,
        };
    }

    pub fn runUntil(
        self: *EventLoop,
        target_time: clock.LogicalTime,
        timer_buffer: []scheduler.ReadyItem,
    ) EventLoopError!RunResult {
        if (target_time.tick < self.sim_clock.now().tick) return error.InvalidInput;

        var steps_run: u32 = 0;
        while (self.sim_clock.now().tick < target_time.tick and steps_run < self.config.step_budget_max) : (steps_run += 1) {
            const step_result = try self.step(timer_buffer);
            if (!step_result.progress_made) {
                return .{
                    .steps_run = steps_run,
                    .reason = .idle,
                };
            }
        }

        if (self.sim_clock.now().tick >= target_time.tick) {
            return .{
                .steps_run = steps_run,
                .reason = .reached_target_time,
            };
        }
        return .{
            .steps_run = steps_run,
            .reason = .step_budget_exhausted,
        };
    }

    fn nextDueTimeAfterDueFaults(self: *const EventLoop, now_time: clock.LogicalTime) ?clock.LogicalTime {
        const timer_due_time = self.timer_queue.nextDueTime();
        const fault_due_time = self.fault_script.peekNextTimeAfter(now_time);
        const next_due_time = minDueTime(timer_due_time, fault_due_time);
        if (next_due_time == null) return null;
        assert(next_due_time.?.tick > now_time.tick);
        return next_due_time;
    }
};

fn minDueTime(
    a: ?clock.LogicalTime,
    b: ?clock.LogicalTime,
) ?clock.LogicalTime {
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.tick <= b.?.tick) a else b;
}

fn appendFaultTrace(trace_buffer: ?*trace.TraceBuffer, faults: []const fault_script.FaultEvent) EventLoopError!void {
    if (trace_buffer == null) return;

    for (faults) |fault| {
        trace_buffer.?.append(.{
            .timestamp_ns = fault.time.tick,
            .category = .check,
            .label = "event_loop.fault",
            .value = fault.target_id,
        }) catch |err| switch (err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.NoSpaceLeft => return error.NoSpaceLeft,
        };
    }
}

fn ensureTraceCapacity(
    sim_loop: *const EventLoop,
    event_trace_count: usize,
    decision_trace_count: usize,
) EventLoopError!void {
    if (sim_loop.trace_buffer) |event_trace_buffer| {
        if (sim_loop.scheduler.trace_buffer) |decision_trace_buffer| {
            if (event_trace_buffer == decision_trace_buffer) {
                const combined_trace_count = event_trace_count + decision_trace_count;
                assert(combined_trace_count >= event_trace_count);
                if (event_trace_buffer.freeSlots() < combined_trace_count) return error.NoSpaceLeft;
                return;
            }
        }

        if (event_trace_buffer.freeSlots() < event_trace_count) return error.NoSpaceLeft;
    } else {
        assert(event_trace_count == 0);
    }

    if (sim_loop.scheduler.trace_buffer) |decision_trace_buffer| {
        if (decision_trace_buffer.freeSlots() < decision_trace_count) return error.NoSpaceLeft;
    } else {
        assert(decision_trace_count == 0);
    }
}

fn appendJumpTrace(
    trace_buffer: ?*trace.TraceBuffer,
    target_time: clock.LogicalTime,
) EventLoopError!void {
    if (trace_buffer == null) return;

    trace_buffer.?.append(.{
        .timestamp_ns = target_time.tick,
        .category = .info,
        .label = "event_loop.jump",
        .value = target_time.tick,
    }) catch |err| switch (err) {
        error.InvalidConfig => return error.InvalidConfig,
        error.NoSpaceLeft => return error.NoSpaceLeft,
    };
}

test "event loop delivers timers in order and schedules due work" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 8,
        .timers_max = 8,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [4]scheduler.ReadyItem = undefined;
    var decision_storage: [4]scheduler.ScheduleDecision = undefined;
    var sim_scheduler = try scheduler.Scheduler.init(.init(9), &ready_storage, &decision_storage, .{
        .strategy = .first,
    }, null);

    const events = [_]fault_script.FaultEvent{};
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 8 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, null);

    _ = try timer_queue_value.scheduleAfter(.{ .id = 1 }, .init(2));
    _ = try timer_queue_value.scheduleAfter(.{ .id = 2 }, .init(3));

    var timer_buffer: [4]scheduler.ReadyItem = undefined;
    try testing.expect((try loop.step(&timer_buffer)).time_advanced);
    const first_ready = try loop.step(&timer_buffer);
    try testing.expect(first_ready.decision != null);
    try testing.expectEqual(@as(u32, 1), first_ready.decision.?.chosen_id);

    try testing.expect((try loop.step(&timer_buffer)).time_advanced);
    const second_ready = try loop.step(&timer_buffer);
    try testing.expect(second_ready.decision != null);
    try testing.expectEqual(@as(u32, 2), second_ready.decision.?.chosen_id);
}

test "event loop stops on explicit step budget" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 8,
        .timers_max = 4,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [1]scheduler.ReadyItem = undefined;
    var decision_storage: [1]scheduler.ScheduleDecision = undefined;
    var sim_scheduler = try scheduler.Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    const events = [_]fault_script.FaultEvent{};
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 1 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, null);

    _ = try timer_queue_value.scheduleAfter(.{ .id = 9 }, .init(5));
    var timer_buffer: [2]scheduler.ReadyItem = undefined;
    const result = try loop.runForSteps(1, &timer_buffer);
    try testing.expectEqual(StopReason.step_budget_exhausted, result.reason);
}

test "event loop faults are observational and do not block scheduling" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 8,
        .timers_max = 2,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [2]scheduler.ReadyItem = undefined;
    var decision_storage: [2]scheduler.ScheduleDecision = undefined;
    var trace_storage: [4]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{
        .max_events = 4,
    });
    var sim_scheduler = try scheduler.Scheduler.init(.init(5), &ready_storage, &decision_storage, .{
        .strategy = .first,
    }, null);
    try sim_scheduler.enqueueReady(.{ .id = 17, .value = 99 });

    const events = [_]fault_script.FaultEvent{
        .{ .time = .init(0), .kind = .drop, .target_id = 17 },
    };
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 4 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, &trace_buffer);

    var timer_buffer: [2]scheduler.ReadyItem = undefined;
    const result = try loop.step(&timer_buffer);
    const snapshot = trace_buffer.snapshot();

    try testing.expectEqual(@as(u32, 1), result.fault_count);
    try testing.expect(result.decision != null);
    try testing.expectEqual(@as(u32, 17), result.decision.?.chosen_id);
    try testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try testing.expectEqualStrings("event_loop.fault", snapshot.items[0].label);
}

test "event loop runForSteps respects configured step budget" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 8,
        .timers_max = 2,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [1]scheduler.ReadyItem = undefined;
    var decision_storage: [1]scheduler.ScheduleDecision = undefined;
    var sim_scheduler = try scheduler.Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    const events = [_]fault_script.FaultEvent{};
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 1 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, null);

    _ = try timer_queue_value.scheduleAfter(.{ .id = 9 }, .init(5));
    var timer_buffer: [2]scheduler.ReadyItem = undefined;
    const result = try loop.runForSteps(3, &timer_buffer);

    try testing.expectEqual(@as(u32, 1), result.steps_run);
    try testing.expectEqual(StopReason.step_budget_exhausted, result.reason);
}

test "event loop reports idle when no timers faults or ready work exist" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 4,
        .timers_max = 1,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [1]scheduler.ReadyItem = undefined;
    var decision_storage: [1]scheduler.ScheduleDecision = undefined;
    var sim_scheduler = try scheduler.Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    const events = [_]fault_script.FaultEvent{};
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 2 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, null);

    var timer_buffer: [1]scheduler.ReadyItem = undefined;
    const result = try loop.runForSteps(2, &timer_buffer);

    try testing.expectEqual(@as(u32, 0), result.steps_run);
    try testing.expectEqual(StopReason.idle, result.reason);
}

test "event loop runUntil rejects backward targets" {
    var sim_clock = clock.SimClock.init(.init(5));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 4,
        .timers_max = 1,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [1]scheduler.ReadyItem = undefined;
    var decision_storage: [1]scheduler.ScheduleDecision = undefined;
    var sim_scheduler = try scheduler.Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    const events = [_]fault_script.FaultEvent{};
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 2 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, null);

    var timer_buffer: [1]scheduler.ReadyItem = undefined;
    try testing.expectError(error.InvalidInput, loop.runUntil(.init(4), &timer_buffer));
}

test "event loop traces due faults before jumping to the next timer" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 8,
        .timers_max = 2,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [1]scheduler.ReadyItem = undefined;
    var decision_storage: [1]scheduler.ScheduleDecision = undefined;
    var trace_storage: [4]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 4 });
    var sim_scheduler = try scheduler.Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    const events = [_]fault_script.FaultEvent{
        .{ .time = .init(0), .kind = .drop, .target_id = 9 },
    };
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 4 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, &trace_buffer);

    _ = try timer_queue_value.scheduleAfter(.{ .id = 1 }, .init(2));

    var timer_buffer: [1]scheduler.ReadyItem = undefined;
    const step_result = try loop.step(&timer_buffer);
    const snapshot = trace_buffer.snapshot();

    try testing.expect(step_result.time_advanced);
    try testing.expectEqual(@as(u32, 1), step_result.fault_count);
    try testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try testing.expectEqualStrings("event_loop.fault", snapshot.items[0].label);
    try testing.expectEqualStrings("event_loop.jump", snapshot.items[1].label);
    try testing.expectEqual(@as(u64, 2), snapshot.items[1].value);
}

test "event loop leaves fault cursors and time unchanged when fault tracing fails" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 4,
        .timers_max = 1,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [1]scheduler.ReadyItem = undefined;
    var decision_storage: [1]scheduler.ScheduleDecision = undefined;
    var sim_scheduler = try scheduler.Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    var trace_storage: [1]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 1 });
    try trace_buffer.append(.{
        .timestamp_ns = 0,
        .category = .info,
        .label = "preexisting",
    });

    const events = [_]fault_script.FaultEvent{
        .{ .time = .init(0), .kind = .drop, .target_id = 1 },
    };
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 2 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, &trace_buffer);

    var timer_buffer: [1]scheduler.ReadyItem = undefined;
    try testing.expectError(error.NoSpaceLeft, loop.step(&timer_buffer));
    try testing.expectEqual(@as(usize, 0), sim_fault_script.next_index);
    try testing.expectEqual(@as(u64, 0), sim_clock.now().tick);

    trace_buffer.reset();
    const recovered = try loop.step(&timer_buffer);
    try testing.expectEqual(@as(u32, 1), recovered.fault_count);
    try testing.expectEqual(@as(usize, 1), sim_fault_script.next_index);
}

test "event loop leaves due timers queued when scheduler capacity is exhausted" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 4,
        .timers_max = 2,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [1]scheduler.ReadyItem = undefined;
    var decision_storage: [2]scheduler.ScheduleDecision = undefined;
    var sim_scheduler = try scheduler.Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    try sim_scheduler.enqueueReady(.{ .id = 7, .value = 70 });

    const events = [_]fault_script.FaultEvent{};
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 3 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, null);

    _ = try timer_queue_value.scheduleAfter(.{ .id = 9, .value = 90 }, .init(1));
    _ = try sim_clock.advance(.init(1));

    var timer_buffer: [1]scheduler.ReadyItem = undefined;
    try testing.expectError(error.NoSpaceLeft, loop.step(&timer_buffer));
    try testing.expectEqual(@as(usize, 1), sim_scheduler.readyCount());
    try testing.expectEqual(@as(usize, 1), timer_queue_value.dueCountUpTo(sim_clock.now()));

    const manual = try sim_scheduler.nextDecision();
    try testing.expectEqual(@as(u32, 7), manual.chosen_id);

    const recovered = try loop.step(&timer_buffer);
    try testing.expect(recovered.decision != null);
    try testing.expectEqual(@as(u32, 9), recovered.decision.?.chosen_id);
}

test "event loop leaves time unchanged when jump tracing lacks capacity" {
    var sim_clock = clock.SimClock.init(.init(0));
    var timer_queue_value = try timer_queue.TimerQueue(scheduler.ReadyItem).init(testing.allocator, &sim_clock, .{
        .buckets = 4,
        .timers_max = 1,
    });
    defer timer_queue_value.deinit(testing.allocator);

    var ready_storage: [1]scheduler.ReadyItem = undefined;
    var decision_storage: [1]scheduler.ScheduleDecision = undefined;
    var sim_scheduler = try scheduler.Scheduler.init(.init(1), &ready_storage, &decision_storage, .{}, null);
    var trace_storage: [1]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 1 });
    try trace_buffer.append(.{
        .timestamp_ns = 0,
        .category = .info,
        .label = "preexisting",
    });

    const events = [_]fault_script.FaultEvent{};
    var sim_fault_script = try fault_script.FaultScript.init(&events);
    var loop = try EventLoop.init(.{ .step_budget_max = 2 }, &sim_clock, &sim_scheduler, &timer_queue_value, &sim_fault_script, &trace_buffer);

    _ = try timer_queue_value.scheduleAfter(.{ .id = 5, .value = 50 }, .init(2));
    var timer_buffer: [1]scheduler.ReadyItem = undefined;
    try testing.expectError(error.NoSpaceLeft, loop.step(&timer_buffer));
    try testing.expectEqual(@as(u64, 0), sim_clock.now().tick);

    trace_buffer.reset();
    const recovered = try loop.step(&timer_buffer);
    try testing.expect(recovered.time_advanced);
    try testing.expectEqual(@as(u64, 2), sim_clock.now().tick);
}
