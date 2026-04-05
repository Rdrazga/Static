const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const sim = static_testing.testing.sim;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;

test "simulation exploration validates wait_queue wake-before-timeout protocol across schedules" {
    const explore = sim.explore;

    const Context = struct {
        const violations = [_]checker.Violation{
            .{
                .code = "wait_queue.protocol",
                .message = "wake-before-timeout protocol did not complete deterministically",
            },
        };

        const State = struct {
            shared_value: u32 = 0,
            waiting: bool = false,
            completed: bool = false,
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

            _ = try fixture.scheduleAfter(.{ .id = 1 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 2 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 3 }, .init(2));

            var state: State = .{};
            var steps: u32 = 0;
            while (steps < 8) : (steps += 1) {
                const step_result = try fixture.step();
                if (step_result.decision) |decision| {
                    try applyWaitQueueAction(
                        &state,
                        fixture.traceBufferPtr().?,
                        fixture.sim_clock.now().tick,
                        decision.chosen_id,
                    );
                }
                if (!step_result.progress_made) break;
            }

            const snapshot = fixture.traceSnapshot().?;
            if (traceContainsLabel(snapshot, "wait_queue.wake")) {
                const wake_before_complete = try temporal.checkHappensBefore(
                    snapshot,
                    .{ .label = "wait_queue.wake" },
                    .{ .label = "wait_queue.completed" },
                );
                if (!wake_before_complete.check_result.passed) {
                    return .{
                        .check_result = wake_before_complete.check_result,
                        .recorded_decisions = fixture.recordedDecisions(),
                        .trace_metadata = fixture.traceMetadata(),
                        .trace_provenance_summary = fixture.traceProvenanceSummary(),
                    };
                }
            }
            const no_timeout = try temporal.checkNever(snapshot, .{
                .label = "wait_queue.timeout",
            });
            if (!no_timeout.check_result.passed) {
                return .{
                    .check_result = no_timeout.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            return .{
                .check_result = if (state.completed and !state.timed_out and state.shared_value == 1)
                    checker.CheckResult.pass(checker.CheckpointDigest.init(waitQueueDigest(state)))
                else
                    checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(waitQueueDigest(state))),
                .recorded_decisions = fixture.recordedDecisions(),
                .trace_metadata = fixture.traceMetadata(),
                .trace_provenance_summary = fixture.traceProvenanceSummary(),
            };
        }

        fn applyWaitQueueAction(
            state: *State,
            trace_buffer: *trace.TraceBuffer,
            timestamp_ns: u64,
            chosen_id: u32,
        ) !void {
            switch (chosen_id) {
                1 => {
                    if (state.shared_value != 0) {
                        state.completed = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "wait_queue.completed",
                        });
                    } else {
                        state.waiting = true;
                    }
                },
                2 => {
                    state.shared_value = 1;
                    if (state.waiting) {
                        state.waiting = false;
                        state.completed = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "wait_queue.wake",
                        });
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "wait_queue.completed",
                        });
                    }
                },
                3 => {
                    if (state.waiting and state.shared_value == 0) {
                        state.waiting = false;
                        state.timed_out = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "wait_queue.timeout",
                        });
                    }
                },
                else => unreachable,
            }
        }

        fn waitQueueDigest(state: State) u128 {
            return @as(u128, state.shared_value) |
                (@as(u128, if (state.waiting) 1 else 0) << 32) |
                (@as(u128, if (state.completed) 1 else 0) << 64) |
                (@as(u128, if (state.timed_out) 1 else 0) << 96);
        }
    };

    const scenario = explore.ExplorationScenario(anyerror){
        .context = undefined,
        .run_fn = Context.run,
    };

    const summary = try explore.runExploration(anyerror, .{
        .base_seed = .init(23),
        .schedules_max = 3,
    }, scenario, null);

    try testing.expectEqual(@as(u32, 3), summary.executed_schedule_count);
    try testing.expectEqual(@as(u32, 0), summary.failed_schedule_count);
    try testing.expect(summary.first_failure == null);
}

fn traceContainsLabel(snapshot: trace.TraceSnapshot, label: []const u8) bool {
    for (snapshot.items) |event| {
        if (std.mem.eql(u8, event.label, label)) return true;
    }
    return false;
}

test "simulation exploration validates condvar broadcast protocol across schedules" {
    const explore = sim.explore;

    const Context = struct {
        const violations = [_]checker.Violation{
            .{
                .code = "condvar.broadcast_protocol",
                .message = "broadcast protocol did not release both waiters deterministically",
            },
        };

        const State = struct {
            predicate_ready: bool = false,
            waiter_a_blocked: bool = false,
            waiter_b_blocked: bool = false,
            waiter_a_done: bool = false,
            waiter_b_done: bool = false,
        };

        fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) !explore.ExplorationScenarioExecution {
            var fixture: sim.fixture.Fixture(6, 6, 6, 24) = undefined;
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

            _ = try fixture.scheduleAfter(.{ .id = 11 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 12 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 13 }, .init(1));

            var state: State = .{};
            var steps: u32 = 0;
            while (steps < 8) : (steps += 1) {
                const step_result = try fixture.step();
                if (step_result.decision) |decision| {
                    try applyBroadcastAction(
                        &state,
                        fixture.traceBufferPtr().?,
                        fixture.sim_clock.now().tick,
                        decision.chosen_id,
                    );
                }
                if (!step_result.progress_made) break;
            }

            const snapshot = fixture.traceSnapshot().?;
            const waiter_a_after_broadcast = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "condvar.broadcast" },
                .{ .label = "condvar.waiter_a_done" },
            );
            if (!waiter_a_after_broadcast.check_result.passed) {
                return .{
                    .check_result = waiter_a_after_broadcast.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }
            const waiter_b_after_broadcast = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "condvar.broadcast" },
                .{ .label = "condvar.waiter_b_done" },
            );
            if (!waiter_b_after_broadcast.check_result.passed) {
                return .{
                    .check_result = waiter_b_after_broadcast.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }
            const broadcast_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "condvar.broadcast",
            });
            if (!broadcast_once.check_result.passed) {
                return .{
                    .check_result = broadcast_once.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            return .{
                .check_result = if (state.predicate_ready and state.waiter_a_done and state.waiter_b_done)
                    checker.CheckResult.pass(checker.CheckpointDigest.init(condvarDigest(state)))
                else
                    checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(condvarDigest(state))),
                .recorded_decisions = fixture.recordedDecisions(),
                .trace_metadata = fixture.traceMetadata(),
                .trace_provenance_summary = fixture.traceProvenanceSummary(),
            };
        }

        fn applyBroadcastAction(
            state: *State,
            trace_buffer: *trace.TraceBuffer,
            timestamp_ns: u64,
            chosen_id: u32,
        ) !void {
            switch (chosen_id) {
                11 => {
                    if (state.predicate_ready) {
                        state.waiter_a_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "condvar.waiter_a_done",
                        });
                    } else {
                        state.waiter_a_blocked = true;
                    }
                },
                12 => {
                    if (state.predicate_ready) {
                        state.waiter_b_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "condvar.waiter_b_done",
                        });
                    } else {
                        state.waiter_b_blocked = true;
                    }
                },
                13 => {
                    state.predicate_ready = true;
                    try trace_buffer.append(.{
                        .timestamp_ns = timestamp_ns,
                        .category = .info,
                        .label = "condvar.broadcast",
                    });
                    if (state.waiter_a_blocked) {
                        state.waiter_a_blocked = false;
                        state.waiter_a_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "condvar.waiter_a_done",
                        });
                    }
                    if (state.waiter_b_blocked) {
                        state.waiter_b_blocked = false;
                        state.waiter_b_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "condvar.waiter_b_done",
                        });
                    }
                },
                else => unreachable,
            }
        }

        fn condvarDigest(state: State) u128 {
            return @as(u128, if (state.predicate_ready) 1 else 0) |
                (@as(u128, if (state.waiter_a_blocked) 1 else 0) << 16) |
                (@as(u128, if (state.waiter_b_blocked) 1 else 0) << 32) |
                (@as(u128, if (state.waiter_a_done) 1 else 0) << 64) |
                (@as(u128, if (state.waiter_b_done) 1 else 0) << 80);
        }
    };

    const scenario = explore.ExplorationScenario(anyerror){
        .context = undefined,
        .run_fn = Context.run,
    };

    const summary = try explore.runExploration(anyerror, .{
        .base_seed = .init(31),
        .schedules_max = 3,
    }, scenario, null);

    try testing.expectEqual(@as(u32, 3), summary.executed_schedule_count);
    try testing.expectEqual(@as(u32, 0), summary.failed_schedule_count);
    try testing.expect(summary.first_failure == null);
}

test "simulation exploration validates condvar timeout protocol" {
    const explore = sim.explore;

    const Context = struct {
        const violations = [_]checker.Violation{
            .{
                .code = "condvar.timeout_protocol",
                .message = "timed-wait protocol did not time out deterministically",
            },
        };

        const State = struct {
            predicate_ready: bool = false,
            blocked: bool = false,
            timed_out: bool = false,
        };

        fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) !explore.ExplorationScenarioExecution {
            var fixture: sim.fixture.Fixture(4, 4, 4, 0) = undefined;
            try fixture.init(.{
                .allocator = testing.allocator,
                .timer_queue_config = .{
                    .buckets = 8,
                    .timers_max = 8,
                },
                .scheduler_seed = input.candidate.scheduler_seed,
                .scheduler_config = input.candidate.scheduler_config,
                .event_loop_config = .{ .step_budget_max = 8 },
            });
            defer fixture.deinit();

            _ = try fixture.scheduleAfter(.{ .id = 21 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 22 }, .init(2));

            var state: State = .{};
            var steps: u32 = 0;
            while (steps < 8) : (steps += 1) {
                const step_result = try fixture.step();
                if (step_result.decision) |decision| {
                    switch (decision.chosen_id) {
                        21 => {
                            if (!state.predicate_ready) state.blocked = true;
                        },
                        22 => {
                            if (state.blocked and !state.predicate_ready) {
                                state.blocked = false;
                                state.timed_out = true;
                            }
                        },
                        else => unreachable,
                    }
                }
                if (!step_result.progress_made) break;
            }

            return .{
                .check_result = if (state.timed_out and !state.blocked)
                    checker.CheckResult.pass(checker.CheckpointDigest.init(timeoutDigest(state)))
                else
                    checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(timeoutDigest(state))),
                .recorded_decisions = fixture.recordedDecisions(),
            };
        }

        fn timeoutDigest(state: State) u128 {
            return @as(u128, if (state.predicate_ready) 1 else 0) |
                (@as(u128, if (state.blocked) 1 else 0) << 32) |
                (@as(u128, if (state.timed_out) 1 else 0) << 64);
        }
    };

    const scenario = explore.ExplorationScenario(anyerror){
        .context = undefined,
        .run_fn = Context.run,
    };

    const summary = try explore.runExploration(anyerror, .{
        .base_seed = .init(37),
        .schedules_max = 1,
    }, scenario, null);

    try testing.expectEqual(@as(u32, 1), summary.executed_schedule_count);
    try testing.expectEqual(@as(u32, 0), summary.failed_schedule_count);
    try testing.expect(summary.first_failure == null);
}
