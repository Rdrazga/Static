const std = @import("std");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const explore = static_testing.testing.sim.explore;
const scheduler = static_testing.testing.sim.scheduler;
const sim = static_testing.testing.sim;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;

const ScenarioError = sim.fixture.FixtureError || temporal.TemporalError;

const intentional_failure_violations = [_]checker.Violation{
    .{
        .code = "static_scheduling.intentional_exploration_failure",
        .message = "retained exploration provenance is validated before the failure is emitted",
    },
};

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

fn compareDecisions(
    expected: []const scheduler.ScheduleDecision,
    actual: []const scheduler.ScheduleDecision,
) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqual(lhs.step_index, rhs.step_index);
        try std.testing.expectEqual(lhs.chosen_index, rhs.chosen_index);
        try std.testing.expectEqual(lhs.ready_len, rhs.ready_len);
        try std.testing.expectEqual(lhs.chosen_id, rhs.chosen_id);
        try std.testing.expectEqual(lhs.chosen_value, rhs.chosen_value);
    }
}

fn candidateFromRecord(
    record: explore.ExplorationFailureRecord,
) !explore.ExplorationCandidate {
    const scheduler_strategy: scheduler.SchedulerStrategy = if (std.mem.eql(u8, record.schedule_mode, "first"))
        .first
    else if (std.mem.eql(u8, record.schedule_mode, "seeded"))
        .seeded
    else if (std.mem.eql(u8, record.schedule_mode, "pct_bias"))
        .pct_bias
    else
        return error.InvalidInput;
    const scheduler_seed = if (scheduler_strategy == .first)
        record.schedule_seed orelse static_testing.testing.seed.Seed.init(0)
    else
        record.schedule_seed orelse return error.InvalidInput;
    const scheduler_config: scheduler.SchedulerConfig = .{
        .strategy = scheduler_strategy,
        .pct_preemption_step = if (scheduler_strategy == .pct_bias) record.schedule_index else 0,
    };

    return .{
        .schedule_index = record.schedule_index,
        .scheduler_config = scheduler_config,
        .scheduler_seed = scheduler_seed,
        .schedule_metadata = scheduler.describeSchedule(scheduler_seed, scheduler_config),
    };
}

const Context = struct {
    fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) ScenarioError!explore.ExplorationScenarioExecution {
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
        const is_intentional_failure = input.candidate.scheduler_config.strategy == .seeded;
        return .{
            .check_result = if (is_intentional_failure)
                checker.CheckResult.fail(&intentional_failure_violations, digest)
            else
                checker.CheckResult.pass(digest),
            .recorded_decisions = fixture.recordedDecisions(),
            .trace_metadata = fixture.traceMetadata(),
            .trace_provenance_summary = fixture.traceProvenanceSummary(),
        };
    }
};

test "replay exploration retains and replays timer queue provenance" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var failure_storage_decisions: [8]scheduler.ScheduleDecision = undefined;
    const scenario = explore.ExplorationScenario(ScenarioError){
        .context = undefined,
        .run_fn = Context.run,
    };

    const summary = try explore.runExploration(ScenarioError, .{
        .base_seed = .init(0x17b4_2026_0000_7301),
        .schedules_max = 2,
    }, scenario, .{
        .decision_buffer = &failure_storage_decisions,
    });

    try std.testing.expectEqual(@as(u32, 2), summary.executed_schedule_count);
    try std.testing.expectEqual(@as(u32, 1), summary.failed_schedule_count);
    try std.testing.expect(summary.first_failure != null);

    const first_failure = summary.first_failure.?;
    try std.testing.expectEqualStrings("seeded", first_failure.schedule_mode);
    try std.testing.expect(first_failure.schedule_seed != null);
    try std.testing.expectEqual(@as(usize, 3), first_failure.recorded_decisions.len);
    try std.testing.expect(first_failure.trace_metadata != null);
    try std.testing.expect(first_failure.trace_provenance_summary != null);

    var append_existing_file_buffer: [256]u8 = undefined;
    var append_record_buffer: [2048]u8 = undefined;
    var append_frame_buffer: [256]u8 = undefined;
    var append_output_file_buffer: [4096]u8 = undefined;
    const appended_name = try explore.appendFailureRecordFile(io, tmp_dir.dir, "timer_queue_exploration_failures.binlog", .{
        .existing_file_buffer = &append_existing_file_buffer,
        .record_buffer = &append_record_buffer,
        .frame_buffer = &append_frame_buffer,
        .output_file_buffer = &append_output_file_buffer,
    }, 4, first_failure);
    try std.testing.expect(appended_name.len != 0);

    var read_file_buffer: [4096]u8 = undefined;
    var read_mode_buffer: [64]u8 = undefined;
    var read_decisions: [8]scheduler.ScheduleDecision = undefined;
    const retained = (try explore.readMostRecentFailureRecord(io, tmp_dir.dir, "timer_queue_exploration_failures.binlog", .{
        .selection = .{ .decision_artifact = .decisions },
        .file_buffer = &read_file_buffer,
        .mode_buffer = &read_mode_buffer,
        .decision_buffer = &read_decisions,
    })).?;

    try std.testing.expectEqual(first_failure.schedule_index, retained.schedule_index);
    try std.testing.expectEqualStrings(first_failure.schedule_mode, retained.schedule_mode);
    try std.testing.expectEqual(first_failure.schedule_seed.?.value, retained.schedule_seed.?.value);
    try std.testing.expectEqual(first_failure.recorded_decision_count, retained.recorded_decision_count);
    try std.testing.expectEqual(first_failure.trace_metadata.?, retained.trace_metadata.?);
    try std.testing.expectEqual(first_failure.trace_provenance_summary.?, retained.trace_provenance_summary.?);
    try compareDecisions(first_failure.recorded_decisions, retained.recorded_decisions);

    const replay_candidate = try candidateFromRecord(retained);
    const replay_execution = try scenario.run(.{ .candidate = replay_candidate });
    try std.testing.expect(!replay_execution.check_result.passed);
    try std.testing.expectEqualStrings("static_scheduling.intentional_exploration_failure", replay_execution.check_result.violations[0].code);
    try compareDecisions(retained.recorded_decisions, replay_execution.recorded_decisions);
    try std.testing.expectEqual(retained.trace_metadata.?, replay_execution.trace_metadata.?);
    try std.testing.expectEqual(retained.trace_provenance_summary.?, replay_execution.trace_provenance_summary.?);
}
