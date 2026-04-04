//! Shared deterministic simulation fixture for event-loop based tests.

const std = @import("std");
const seed = @import("../seed.zig");
const trace = @import("../trace.zig");
const clock = @import("clock.zig");
const scheduler = @import("scheduler.zig");
const timer_queue = @import("timer_queue.zig");
const fault_script = @import("fault_script.zig");
const event_loop = @import("event_loop.zig");

/// Public fixture setup errors.
pub const FixtureError = error{
    InvalidConfig,
} || timer_queue.TimerQueueError || scheduler.SchedulerError || fault_script.FaultScriptError || event_loop.EventLoopError || trace.TraceAppendError;

/// Fixture setup configuration over caller-owned compile-time storage.
pub const FixtureConfig = struct {
    allocator: std.mem.Allocator,
    timer_queue_config: timer_queue.TimerQueueConfig,
    scheduler_seed: seed.Seed,
    scheduler_config: scheduler.SchedulerConfig = .{},
    event_loop_config: event_loop.EventLoopConfig,
    start_time_ns: u64 = 0,
    fault_events: []const fault_script.FaultEvent = &.{},
    trace_config: ?trace.TraceBufferConfig = null,
};

/// Build one deterministic event-loop fixture over fixed-capacity storage.
pub fn Fixture(
    comptime ready_capacity: usize,
    comptime decision_capacity: usize,
    comptime timer_buffer_capacity: usize,
    comptime trace_capacity: usize,
) type {
    comptime {
        std.debug.assert(ready_capacity > 0);
        std.debug.assert(decision_capacity > 0);
        std.debug.assert(timer_buffer_capacity > 0);
    }

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator = undefined,
        sim_clock: clock.SimClock = undefined,
        timer_queue: timer_queue.TimerQueue(scheduler.ReadyItem) = undefined,
        scheduler: scheduler.Scheduler = undefined,
        fault_script: fault_script.FaultScript = undefined,
        event_loop: event_loop.EventLoop = undefined,
        trace_buffer: ?trace.TraceBuffer = null,

        ready_storage: [ready_capacity]scheduler.ReadyItem = undefined,
        decision_storage: [decision_capacity]scheduler.ScheduleDecision = undefined,
        timer_buffer: [timer_buffer_capacity]scheduler.ReadyItem = undefined,
        trace_storage: [trace_capacity]trace.TraceEvent = undefined,

        pub fn init(self: *Self, config: FixtureConfig) FixtureError!void {
            if (config.trace_config != null and trace_capacity == 0) return error.InvalidConfig;

            self.allocator = config.allocator;
            self.sim_clock = clock.SimClock.init(.init(config.start_time_ns));
            self.timer_queue = try timer_queue.TimerQueue(scheduler.ReadyItem).init(
                config.allocator,
                &self.sim_clock,
                config.timer_queue_config,
            );
            errdefer self.timer_queue.deinit(config.allocator);

            if (config.trace_config) |trace_config| {
                self.trace_buffer = try trace.TraceBuffer.init(&self.trace_storage, trace_config);
            } else {
                self.trace_buffer = null;
            }

            self.scheduler = try scheduler.Scheduler.init(
                config.scheduler_seed,
                &self.ready_storage,
                &self.decision_storage,
                config.scheduler_config,
                self.traceBufferPtr(),
            );
            self.fault_script = try fault_script.FaultScript.init(config.fault_events);
            self.event_loop = try event_loop.EventLoop.init(
                config.event_loop_config,
                &self.sim_clock,
                &self.scheduler,
                &self.timer_queue,
                &self.fault_script,
                self.traceBufferPtr(),
            );
        }

        pub fn deinit(self: *Self) void {
            self.timer_queue.deinit(self.allocator);
        }

        pub fn step(self: *Self) FixtureError!event_loop.StepResult {
            return self.event_loop.step(&self.timer_buffer);
        }

        pub fn runForSteps(self: *Self, step_count_max: u32) FixtureError!event_loop.RunResult {
            return self.event_loop.runForSteps(step_count_max, &self.timer_buffer);
        }

        pub fn runUntil(self: *Self, target_time: clock.LogicalTime) FixtureError!event_loop.RunResult {
            return self.event_loop.runUntil(target_time, &self.timer_buffer);
        }

        pub fn scheduleAfter(
            self: *Self,
            ready_item: scheduler.ReadyItem,
            delay: clock.LogicalDuration,
        ) timer_queue.TimerQueueError!timer_queue.TimerQueue(scheduler.ReadyItem).TimerId {
            return self.timer_queue.scheduleAfter(ready_item, delay);
        }

        pub fn recordedDecisions(self: *const Self) []const scheduler.ScheduleDecision {
            return self.scheduler.recordedDecisions();
        }

        pub fn traceMetadata(self: *const Self) ?trace.TraceMetadata {
            if (self.trace_buffer) |trace_buffer| {
                return trace_buffer.snapshot().metadata();
            }
            return null;
        }

        pub fn traceSnapshot(self: *Self) ?trace.TraceSnapshot {
            if (self.trace_buffer) |*trace_buffer| {
                return trace_buffer.snapshot();
            }
            return null;
        }

        pub fn traceProvenanceSummary(self: *Self) ?trace.TraceProvenanceSummary {
            if (self.traceSnapshot()) |snapshot| {
                return snapshot.provenanceSummary();
            }
            return null;
        }

        pub fn traceBufferPtr(self: *Self) ?*trace.TraceBuffer {
            if (self.trace_buffer) |*trace_buffer| {
                return trace_buffer;
            }
            return null;
        }
    };
}

test "fixture steps one deterministic timer-driven schedule" {
    var fixture: Fixture(4, 4, 4, 0) = undefined;
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(19),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 4 },
    });
    defer fixture.deinit();

    _ = try fixture.scheduleAfter(.{ .id = 11 }, .init(1));
    _ = try fixture.scheduleAfter(.{ .id = 22 }, .init(2));

    _ = try fixture.step();
    const first = try fixture.step();
    try std.testing.expectEqual(@as(u32, 11), first.decision.?.chosen_id);

    _ = try fixture.step();
    const second = try fixture.step();
    try std.testing.expectEqual(@as(u32, 22), second.decision.?.chosen_id);
}

test "fixture optionally records trace metadata" {
    var fixture: Fixture(4, 4, 4, 8) = undefined;
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(23),
        .scheduler_config = .{ .strategy = .seeded },
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 8 },
    });
    defer fixture.deinit();

    _ = try fixture.scheduleAfter(.{ .id = 7 }, .init(1));
    _ = try fixture.runForSteps(2);

    const metadata = fixture.traceMetadata().?;
    try std.testing.expect(metadata.event_count != 0);
}
