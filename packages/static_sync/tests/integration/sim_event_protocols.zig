const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const sim = static_testing.testing.sim;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;

test "simulation exploration validates event set-reset handoff across schedules" {
    const explore = sim.explore;

    const Context = struct {
        const violations = [_]checker.Violation{
            .{
                .code = "event.set_reset_protocol",
                .message = "event set-reset handoff did not complete deterministically",
            },
        };

        const State = struct {
            signaled: bool = false,
            waiter_a_blocked: bool = false,
            waiter_a_done: bool = false,
            waiter_b_blocked: bool = false,
            waiter_b_done: bool = false,
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

            _ = try fixture.scheduleAfter(.{ .id = 31 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 32 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 33 }, .init(2));
            _ = try fixture.scheduleAfter(.{ .id = 34 }, .init(3));
            _ = try fixture.scheduleAfter(.{ .id = 35 }, .init(3));

            var state: State = .{};
            var steps: u32 = 0;
            while (steps < 8) : (steps += 1) {
                const step_result = try fixture.step();
                if (step_result.decision) |decision| {
                    try applyEventAction(
                        &state,
                        fixture.traceBufferPtr().?,
                        fixture.sim_clock.now().tick,
                        decision.chosen_id,
                    );
                }
                if (!step_result.progress_made) break;
            }

            const snapshot = fixture.traceSnapshot().?;
            const set_eventually = try temporal.checkEventually(snapshot, .{ .label = "event.set" });
            if (!set_eventually.check_result.passed) return temporalFailureResult(&fixture, set_eventually.check_result);
            const waiter_a_done = try temporal.checkEventually(snapshot, .{ .label = "event.waiter_a_done" });
            if (!waiter_a_done.check_result.passed) return temporalFailureResult(&fixture, waiter_a_done.check_result);
            const reset_eventually = try temporal.checkEventually(snapshot, .{ .label = "event.reset" });
            if (!reset_eventually.check_result.passed) return temporalFailureResult(&fixture, reset_eventually.check_result);
            const set_two_eventually = try temporal.checkEventually(snapshot, .{ .label = "event.set_two" });
            if (!set_two_eventually.check_result.passed) return temporalFailureResult(&fixture, set_two_eventually.check_result);
            const waiter_b_done = try temporal.checkEventually(snapshot, .{ .label = "event.waiter_b_done" });
            if (!waiter_b_done.check_result.passed) return temporalFailureResult(&fixture, waiter_b_done.check_result);

            const set_before_waiter = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "event.set" },
                .{ .label = "event.waiter_a_done" },
            );
            if (!set_before_waiter.check_result.passed) return temporalFailureResult(&fixture, set_before_waiter.check_result);
            const reset_before_set_two = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "event.reset" },
                .{ .label = "event.set_two" },
            );
            if (!reset_before_set_two.check_result.passed) return temporalFailureResult(&fixture, reset_before_set_two.check_result);
            const set_two_before_waiter_b = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "event.set_two" },
                .{ .label = "event.waiter_b_done" },
            );
            if (!set_two_before_waiter_b.check_result.passed) return temporalFailureResult(&fixture, set_two_before_waiter_b.check_result);

            return .{
                .check_result = if (state.waiter_a_done and state.waiter_b_done and state.signaled and !state.waiter_b_blocked)
                    checker.CheckResult.pass(checker.CheckpointDigest.init(eventDigest(state)))
                else
                    checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(eventDigest(state))),
                .recorded_decisions = fixture.recordedDecisions(),
                .trace_metadata = fixture.traceMetadata(),
                .trace_provenance_summary = fixture.traceProvenanceSummary(),
            };
        }

        fn applyEventAction(
            state: *State,
            trace_buffer: *trace.TraceBuffer,
            timestamp_ns: u64,
            chosen_id: u32,
        ) !void {
            switch (chosen_id) {
                31 => {
                    if (state.signaled) {
                        state.waiter_a_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "event.waiter_a_done",
                        });
                    } else {
                        state.waiter_a_blocked = true;
                    }
                },
                32 => {
                    state.signaled = true;
                    try trace_buffer.append(.{
                        .timestamp_ns = timestamp_ns,
                        .category = .info,
                        .label = "event.set",
                    });
                    if (state.waiter_a_blocked) {
                        state.waiter_a_blocked = false;
                        state.waiter_a_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "event.waiter_a_done",
                        });
                    }
                },
                33 => {
                    state.signaled = false;
                    try trace_buffer.append(.{
                        .timestamp_ns = timestamp_ns,
                        .category = .info,
                        .label = "event.reset",
                    });
                },
                34 => {
                    if (state.signaled) {
                        state.waiter_b_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "event.waiter_b_done",
                        });
                    } else {
                        state.waiter_b_blocked = true;
                    }
                },
                35 => {
                    state.signaled = true;
                    try trace_buffer.append(.{
                        .timestamp_ns = timestamp_ns,
                        .category = .info,
                        .label = "event.set_two",
                    });
                    if (state.waiter_b_blocked) {
                        state.waiter_b_blocked = false;
                        state.waiter_b_done = true;
                        try trace_buffer.append(.{
                            .timestamp_ns = timestamp_ns,
                            .category = .info,
                            .label = "event.waiter_b_done",
                        });
                    }
                },
                else => unreachable,
            }
        }

        fn eventDigest(state: State) u128 {
            return @as(u128, @intFromBool(state.signaled)) |
                (@as(u128, @intFromBool(state.waiter_a_done)) << 16) |
                (@as(u128, @intFromBool(state.waiter_b_blocked)) << 32) |
                (@as(u128, @intFromBool(state.waiter_b_done)) << 48);
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
        .base_seed = .init(41),
        .schedules_max = 3,
    }, scenario, null);

    try testing.expectEqual(@as(u32, 3), summary.executed_schedule_count);
    try testing.expectEqual(@as(u32, 0), summary.failed_schedule_count);
    try testing.expect(summary.first_failure == null);
}
