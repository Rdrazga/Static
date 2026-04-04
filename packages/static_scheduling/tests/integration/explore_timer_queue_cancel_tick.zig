const std = @import("std");
const static_scheduling = @import("static_scheduling");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const explore = static_testing.testing.sim.explore;
const sim = static_testing.testing.sim;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;

fn emitTraceEvent(
    trace_buffer: *trace.TraceBuffer,
    timestamp_ns: u64,
    category: trace.TraceCategory,
    label: []const u8,
    value: u64,
) !u32 {
    std.debug.assert(label.len > 0);
    std.debug.assert(trace_buffer.freeSlots() > 0);

    try trace_buffer.append(.{
        .timestamp_ns = timestamp_ns,
        .category = category,
        .label = label,
        .value = value,
        .lineage = .{
            .surface_label = "timer_queue",
        },
    });

    const snapshot = trace_buffer.snapshot();
    std.debug.assert(snapshot.items.len > 0);
    const event = snapshot.items[snapshot.items.len - 1];
    std.debug.assert(std.mem.eql(u8, event.label, label));
    std.debug.assert(event.value == value);
    std.debug.assert(event.lineage.surface_label != null);
    return event.sequence_no;
}

test "simulation exploration keeps timer queue cancel-before-tick and due-order stable" {
    const Context = struct {
        fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) !explore.ExplorationScenarioExecution {
            var fixture: sim.fixture.Fixture(4, 4, 4, 16) = undefined;
            try fixture.init(.{
                .allocator = std.testing.allocator,
                .timer_queue_config = .{
                    .buckets = 4,
                    .timers_max = 4,
                },
                .scheduler_seed = input.candidate.scheduler_seed,
                .scheduler_config = input.candidate.scheduler_config,
                .event_loop_config = .{ .step_budget_max = 8 },
                .trace_config = .{ .max_events = 16 },
            });
            defer fixture.deinit();

            const cancel_id = try fixture.scheduleAfter(.{ .id = 44, .value = 440 }, .init(2));
            _ = try fixture.scheduleAfter(.{ .id = 11, .value = 110 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 22, .value = 220 }, .init(1));
            _ = try fixture.scheduleAfter(.{ .id = 33, .value = 330 }, .init(2));

            const first_step = try fixture.step();
            std.debug.assert(first_step.progress_made);
            std.debug.assert(first_step.time_advanced);
            std.debug.assert(first_step.decision == null);
            std.debug.assert(fixture.sim_clock.now().tick == 1);

            const cancelled = try fixture.timer_queue.cancel(cancel_id);
            std.debug.assert(cancelled.id == 44);
            std.debug.assert(cancelled.value == 440);

            const trace_buffer = fixture.traceBufferPtr().?;
            _ = try emitTraceEvent(
                trace_buffer,
                fixture.sim_clock.now().tick,
                .decision,
                "timer_queue.cancel",
                cancelled.id,
            );

            const remainder = try fixture.runForSteps(8);
            std.debug.assert(remainder.reason == .idle);
            std.debug.assert(remainder.steps_run == 4);
            std.debug.assert(fixture.sim_clock.now().tick == 2);
            std.debug.assert(fixture.recordedDecisions().len == 3);

            const snapshot = fixture.traceSnapshot().?;
            std.debug.assert(snapshot.items.len == 6);

            const cancel_before_second_jump = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "timer_queue.cancel", .value = 44, .surface_label = "timer_queue" },
                .{ .label = "event_loop.jump", .value = 2 },
            );
            if (!cancel_before_second_jump.check_result.passed) {
                return .{
                    .check_result = cancel_before_second_jump.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const first_jump_before_cancel = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "event_loop.jump", .value = 1 },
                .{ .label = "timer_queue.cancel", .value = 44, .surface_label = "timer_queue" },
            );
            if (!first_jump_before_cancel.check_result.passed) {
                return .{
                    .check_result = first_jump_before_cancel.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const second_jump_before_late_delivery = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "event_loop.jump", .value = 2 },
                .{ .label = "scheduler.decision", .value = 33 },
            );
            if (!second_jump_before_late_delivery.check_result.passed) {
                return .{
                    .check_result = second_jump_before_late_delivery.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const jump_one_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "event_loop.jump",
                .value = 1,
            });
            if (!jump_one_once.check_result.passed) {
                return .{
                    .check_result = jump_one_once.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const jump_two_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "event_loop.jump",
                .value = 2,
            });
            if (!jump_two_once.check_result.passed) {
                return .{
                    .check_result = jump_two_once.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const decision_11_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "scheduler.decision",
                .value = 11,
            });
            if (!decision_11_once.check_result.passed) {
                return .{
                    .check_result = decision_11_once.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const decision_22_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "scheduler.decision",
                .value = 22,
            });
            if (!decision_22_once.check_result.passed) {
                return .{
                    .check_result = decision_22_once.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const decision_33_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "scheduler.decision",
                .value = 33,
            });
            if (!decision_33_once.check_result.passed) {
                return .{
                    .check_result = decision_33_once.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const decision_11_before_33 = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "scheduler.decision", .value = 11 },
                .{ .label = "scheduler.decision", .value = 33 },
            );
            if (!decision_11_before_33.check_result.passed) {
                return .{
                    .check_result = decision_11_before_33.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const decision_22_before_33 = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "scheduler.decision", .value = 22 },
                .{ .label = "scheduler.decision", .value = 33 },
            );
            if (!decision_22_before_33.check_result.passed) {
                return .{
                    .check_result = decision_22_before_33.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const cancelled_never_decided = try temporal.checkNever(snapshot, .{
                .label = "scheduler.decision",
                .value = 44,
            });
            if (!cancelled_never_decided.check_result.passed) {
                return .{
                    .check_result = cancelled_never_decided.check_result,
                    .recorded_decisions = fixture.recordedDecisions(),
                    .trace_metadata = fixture.traceMetadata(),
                    .trace_provenance_summary = fixture.traceProvenanceSummary(),
                };
            }

            const digest = checker.CheckpointDigest.init(
                (@as(u128, fixture.sim_clock.now().tick) << 96) |
                    (@as(u128, snapshot.items.len) << 64) |
                    @as(u128, fixture.recordedDecisions().len),
            );
            return .{
                .check_result = checker.CheckResult.pass(digest),
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
        .base_seed = .init(0x17b4_2026_0000_3301),
        .schedules_max = 3,
    }, scenario, null);

    try std.testing.expectEqual(@as(u32, 3), summary.executed_schedule_count);
    try std.testing.expectEqual(@as(u32, 0), summary.failed_schedule_count);
    try std.testing.expect(summary.first_failure == null);
}
