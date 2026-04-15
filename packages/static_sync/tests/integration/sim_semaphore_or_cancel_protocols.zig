const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const sim = static_testing.testing.sim;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;

test "simulation exploration validates semaphore permit handoff before timeout across schedules" {
    const explore = sim.explore;

    const Context = struct {
        const violations = [_]checker.Violation{
            .{
                .code = "semaphore.handoff_protocol",
                .message = "semaphore permit handoff did not complete before timeout deterministically",
            },
        };

        const State = struct {
            permits: u32 = 0,
            blocked: bool = false,
            waiter_done: bool = false,
            timed_out: bool = false,
        };

        fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) !explore.ExplorationScenarioExecution {
            var fixture: sim.fixture.Fixture(4, 4, 4, 24) = undefined;
            try fixture.init(.{
                .allocator = testing.allocator,
                .timer_queue_config = .{
                    .buckets = 8,
                    .timers_max = 8,
                },
                .scheduler_seed = input.candidate.scheduler_seed,
                .scheduler_config = input.candidate.scheduler_config,
                .event_loop_config = .{ .step_budget_max = 8 },
                .trace_config = .{ .max_events = 24 },
            });
            defer fixture.deinit();

            _ = try fixture.scheduleAfter(.{ .id = 41 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 42 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 43 }, .init(2));

            var state: State = .{};
            var steps: u32 = 0;
            while (steps < 8) : (steps += 1) {
                const step_result = try fixture.step();
                if (step_result.decision) |decision| {
                    try applySemaphoreAction(
                        &state,
                        fixture.traceBufferPtr().?,
                        fixture.sim_clock.now().tick,
                        decision.chosen_id,
                    );
                }
                if (!step_result.progress_made) break;
            }

            const snapshot = fixture.traceSnapshot().?;
            const post_once = try temporal.checkExactlyOnce(snapshot, .{ .label = "semaphore.post" });
            if (!post_once.check_result.passed) return temporalFailureResult(&fixture, post_once.check_result);
            const wait_done = try temporal.checkEventually(snapshot, .{ .label = "semaphore.waiter_done" });
            if (!wait_done.check_result.passed) return temporalFailureResult(&fixture, wait_done.check_result);
            const post_before_done = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "semaphore.post" },
                .{ .label = "semaphore.waiter_done" },
            );
            if (!post_before_done.check_result.passed) return temporalFailureResult(&fixture, post_before_done.check_result);
            const no_timeout = try temporal.checkNever(snapshot, .{ .label = "semaphore.timeout" });
            if (!no_timeout.check_result.passed) return temporalFailureResult(&fixture, no_timeout.check_result);

            return .{
                .check_result = if (state.waiter_done and !state.blocked and !state.timed_out and state.permits == 0)
                    checker.CheckResult.pass(checker.CheckpointDigest.init(semaphoreDigest(state)))
                else
                    checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(semaphoreDigest(state))),
                .recorded_decisions = fixture.recordedDecisions(),
                .trace_metadata = fixture.traceMetadata(),
                .trace_provenance_summary = fixture.traceProvenanceSummary(),
            };
        }

        fn applySemaphoreAction(
            state: *State,
            trace_buffer: *trace.TraceBuffer,
            timestamp_ns: u64,
            chosen_id: u32,
        ) !void {
            switch (chosen_id) {
                41 => {
                    if (state.permits > 0) {
                        state.permits -= 1;
                        state.waiter_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "semaphore.waiter_done",
                        });
                    } else {
                        state.blocked = true;
                    }
                },
                42 => {
                    state.permits += 1;
                    try trace_buffer.append(.{
                        .timestamp_ns = timestamp_ns,
                        .category = .info,
                        .label = "semaphore.post",
                    });
                    if (state.blocked and state.permits > 0) {
                        state.blocked = false;
                        state.permits -= 1;
                        state.waiter_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "semaphore.waiter_done",
                        });
                    }
                },
                43 => {
                    if (state.blocked and state.permits == 0) {
                        state.blocked = false;
                        state.timed_out = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "semaphore.timeout",
                        });
                    }
                },
                else => unreachable,
            }
        }

        fn semaphoreDigest(state: State) u128 {
            return @as(u128, state.permits) |
                (@as(u128, @intFromBool(state.blocked)) << 32) |
                (@as(u128, @intFromBool(state.waiter_done)) << 48) |
                (@as(u128, @intFromBool(state.timed_out)) << 64);
        }

        fn temporalFailureResult(
            fixture: anytype,
            check_result: checker.CheckResult,
        ) explore.ExplorationScenarioExecution {
            return .{
                .check_result = check_result,
                .recorded_decisions = fixture.recordedDecisions(),
                .trace_metadata = fixture.traceMetadata(),
                .trace_provenance_summary = fixture.traceProvenanceSummary(),
            };
        }
    };

    const scenario = explore.ExplorationScenario(anyerror){
        .context = undefined,
        .run_fn = Context.run,
    };

    const summary = try explore.runExploration(anyerror, .{
        .base_seed = .init(43),
        .schedules_max = 3,
    }, scenario, null);

    try testing.expectEqual(@as(u32, 3), summary.executed_schedule_count);
    try testing.expectEqual(@as(u32, 0), summary.failed_schedule_count);
    try testing.expect(summary.first_failure == null);
}

test "simulation exploration validates cancel reset ordering across schedules" {
    const explore = sim.explore;

    const Context = struct {
        const violations = [_]checker.Violation{
            .{
                .code = "cancel.reset_protocol",
                .message = "cancel reset ordering did not preserve wake semantics deterministically",
            },
        };

        const State = struct {
            cancelled: bool = false,
            waiter_a_blocked: bool = false,
            waiter_a_cancelled: bool = false,
            waiter_b_blocked: bool = false,
            waiter_b_cancelled: bool = false,
        };

        fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) !explore.ExplorationScenarioExecution {
            var fixture: sim.fixture.Fixture(6, 6, 6, 32) = undefined;
            try fixture.init(.{
                .allocator = testing.allocator,
                .timer_queue_config = .{
                    .buckets = 8,
                    .timers_max = 8,
                },
                .scheduler_seed = input.candidate.scheduler_seed,
                .scheduler_config = input.candidate.scheduler_config,
                .event_loop_config = .{ .step_budget_max = 8 },
                .trace_config = .{ .max_events = 32 },
            });
            defer fixture.deinit();

            _ = try fixture.scheduleAfter(.{ .id = 51 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 52 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 53 }, .init(2));
            _ = try fixture.scheduleAfter(.{ .id = 54 }, .init(3));
            _ = try fixture.scheduleAfter(.{ .id = 55 }, .init(3));

            var state: State = .{};
            var steps: u32 = 0;
            while (steps < 8) : (steps += 1) {
                const step_result = try fixture.step();
                if (step_result.decision) |decision| {
                    try applyCancelAction(
                        &state,
                        fixture.traceBufferPtr().?,
                        fixture.sim_clock.now().tick,
                        decision.chosen_id,
                    );
                }
                if (!step_result.progress_made) break;
            }

            const snapshot = fixture.traceSnapshot().?;
            const waiter_a_cancelled = try temporal.checkEventually(snapshot, .{ .label = "cancel.waiter_a_cancelled" });
            if (!waiter_a_cancelled.check_result.passed) return temporalFailureResult(&fixture, waiter_a_cancelled.check_result);
            const reset_once = try temporal.checkExactlyOnce(snapshot, .{ .label = "cancel.reset" });
            if (!reset_once.check_result.passed) return temporalFailureResult(&fixture, reset_once.check_result);
            const waiter_b_cancelled = try temporal.checkEventually(snapshot, .{ .label = "cancel.waiter_b_cancelled" });
            if (!waiter_b_cancelled.check_result.passed) return temporalFailureResult(&fixture, waiter_b_cancelled.check_result);

            const first_cancel_before_first_waiter = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "cancel.fire_one" },
                .{ .label = "cancel.waiter_a_cancelled" },
            );
            if (!first_cancel_before_first_waiter.check_result.passed) return temporalFailureResult(&fixture, first_cancel_before_first_waiter.check_result);
            const reset_before_second_cancel = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "cancel.reset" },
                .{ .label = "cancel.fire_two" },
            );
            if (!reset_before_second_cancel.check_result.passed) return temporalFailureResult(&fixture, reset_before_second_cancel.check_result);
            const second_cancel_before_second_waiter = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "cancel.fire_two" },
                .{ .label = "cancel.waiter_b_cancelled" },
            );
            if (!second_cancel_before_second_waiter.check_result.passed) return temporalFailureResult(&fixture, second_cancel_before_second_waiter.check_result);

            return .{
                .check_result = if (state.waiter_a_cancelled and state.waiter_b_cancelled and !state.waiter_a_blocked and !state.waiter_b_blocked and state.cancelled)
                    checker.CheckResult.pass(checker.CheckpointDigest.init(cancelDigest(state)))
                else
                    checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(cancelDigest(state))),
                .recorded_decisions = fixture.recordedDecisions(),
                .trace_metadata = fixture.traceMetadata(),
                .trace_provenance_summary = fixture.traceProvenanceSummary(),
            };
        }

        fn applyCancelAction(
            state: *State,
            trace_buffer: *trace.TraceBuffer,
            timestamp_ns: u64,
            chosen_id: u32,
        ) !void {
            switch (chosen_id) {
                51 => {
                    if (state.cancelled) {
                        state.waiter_a_cancelled = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "cancel.waiter_a_cancelled",
                        });
                    } else {
                        state.waiter_a_blocked = true;
                    }
                },
                52 => {
                    state.cancelled = true;
                    try trace_buffer.append(.{
                        .timestamp_ns = timestamp_ns,
                        .category = .info,
                        .label = "cancel.fire_one",
                    });
                    if (state.waiter_a_blocked) {
                        state.waiter_a_blocked = false;
                        state.waiter_a_cancelled = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "cancel.waiter_a_cancelled",
                        });
                    }
                },
                53 => {
                    state.cancelled = false;
                    try trace_buffer.append(.{
                        .timestamp_ns = timestamp_ns,
                        .category = .info,
                        .label = "cancel.reset",
                    });
                },
                54 => {
                    if (state.cancelled) {
                        state.waiter_b_cancelled = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "cancel.waiter_b_cancelled",
                        });
                    } else {
                        state.waiter_b_blocked = true;
                    }
                },
                55 => {
                    state.cancelled = true;
                    try trace_buffer.append(.{
                        .timestamp_ns = timestamp_ns,
                        .category = .info,
                        .label = "cancel.fire_two",
                    });
                    if (state.waiter_b_blocked) {
                        state.waiter_b_blocked = false;
                        state.waiter_b_cancelled = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "cancel.waiter_b_cancelled",
                        });
                    }
                },
                else => unreachable,
            }
        }

        fn cancelDigest(state: State) u128 {
            return @as(u128, @intFromBool(state.cancelled)) |
                (@as(u128, @intFromBool(state.waiter_a_blocked)) << 16) |
                (@as(u128, @intFromBool(state.waiter_a_cancelled)) << 32) |
                (@as(u128, @intFromBool(state.waiter_b_blocked)) << 48) |
                (@as(u128, @intFromBool(state.waiter_b_cancelled)) << 64);
        }

        fn temporalFailureResult(
            fixture: anytype,
            check_result: checker.CheckResult,
        ) explore.ExplorationScenarioExecution {
            return .{
                .check_result = check_result,
                .recorded_decisions = fixture.recordedDecisions(),
                .trace_metadata = fixture.traceMetadata(),
                .trace_provenance_summary = fixture.traceProvenanceSummary(),
            };
        }
    };

    const scenario = explore.ExplorationScenario(anyerror){
        .context = undefined,
        .run_fn = Context.run,
    };

    const summary = try explore.runExploration(anyerror, .{
        .base_seed = .init(47),
        .schedules_max = 3,
    }, scenario, null);

    try testing.expectEqual(@as(u32, 3), summary.executed_schedule_count);
    try testing.expectEqual(@as(u32, 0), summary.failed_schedule_count);
    try testing.expect(summary.first_failure == null);
}
