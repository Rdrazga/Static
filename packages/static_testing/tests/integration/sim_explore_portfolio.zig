const std = @import("std");
const testing = @import("static_testing");

test "simulation exploration retains one failing schedule that replays" {
    const explore = testing.testing.sim.explore;
    const sim = testing.testing.sim;
    const checker = testing.testing.checker;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const Context = struct {
        const violations = [_]checker.Violation{
            .{ .code = "schedule.seeded_failure", .message = "seeded candidate retained for replay" },
        };

        fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) !explore.ExplorationScenarioExecution {
            var sim_fixture: sim.fixture.Fixture(4, 4, 4, 8) = undefined;
            try sim_fixture.init(.{
                .allocator = std.testing.allocator,
                .timer_queue_config = .{
                    .buckets = 8,
                    .timers_max = 8,
                },
                .scheduler_seed = input.candidate.scheduler_seed,
                .scheduler_config = input.candidate.scheduler_config,
                .event_loop_config = .{ .step_budget_max = 4 },
                .trace_config = .{ .max_events = 8 },
            });
            defer sim_fixture.deinit();

            _ = try sim_fixture.scheduleAfter(.{ .id = 11, .value = 1 }, .init(1));
            _ = try sim_fixture.scheduleAfter(.{ .id = 22, .value = 2 }, .init(1));

            _ = try sim_fixture.runForSteps(2);
            try appendProvenanceTrace(&sim_fixture, input.candidate.schedule_index);
            const decisions = sim_fixture.recordedDecisions();

            return .{
                .check_result = if (std.mem.eql(u8, input.candidate.schedule_metadata.mode_label, "seeded"))
                    checker.CheckResult.fail(&violations, null)
                else
                    checker.CheckResult.pass(null),
                .recorded_decisions = decisions,
                .trace_metadata = sim_fixture.traceMetadata(),
                .trace_provenance_summary = sim_fixture.traceProvenanceSummary(),
            };
        }

        fn appendProvenanceTrace(
            sim_fixture: *sim.fixture.Fixture(4, 4, 4, 8),
            schedule_index: u32,
        ) !void {
            const trace_buffer = sim_fixture.traceBufferPtr().?;
            const snapshot = trace_buffer.snapshot();
            const root_sequence_no: u32 = if (snapshot.items.len == 0)
                0
            else
                snapshot.items[snapshot.items.len - 1].sequence_no + 1;
            try trace_buffer.append(.{
                .timestamp_ns = 20,
                .category = .decision,
                .label = "explore_decision",
                .value = schedule_index,
            });
            try trace_buffer.append(.{
                .timestamp_ns = 21,
                .category = .info,
                .label = "explore_apply",
                .value = schedule_index,
                .lineage = .{
                    .cause_sequence_no = root_sequence_no,
                    .correlation_id = schedule_index,
                    .surface_label = "explore",
                },
            });
        }
    };
    const scenario = explore.ExplorationScenario(anyerror){
        .context = undefined,
        .run_fn = Context.run,
    };
    var decision_buffer: [4]sim.scheduler.ScheduleDecision = undefined;

    const summary = try explore.runExploration(anyerror, .{
        .base_seed = .init(13),
        .schedules_max = 3,
    }, scenario, .{
        .decision_buffer = &decision_buffer,
    });

    try std.testing.expectEqual(@as(u32, 3), summary.executed_schedule_count);
    try std.testing.expectEqual(@as(u32, 2), summary.failed_schedule_count);
    try std.testing.expect(summary.first_failure != null);

    const first_failure = summary.first_failure.?;
    try std.testing.expectEqualStrings("seeded", first_failure.schedule_mode);
    try std.testing.expect(first_failure.schedule_seed != null);
    try std.testing.expectEqual(@as(u32, 1), first_failure.recorded_decision_count);
    try std.testing.expectEqual(@as(usize, 1), first_failure.recorded_decisions.len);
    try std.testing.expect(first_failure.trace_metadata != null);
    try std.testing.expect(first_failure.trace_provenance_summary != null);
    try std.testing.expect(first_failure.trace_provenance_summary.?.has_provenance);

    var existing_file_buffer: [512]u8 = undefined;
    var record_buffer: [256]u8 = undefined;
    var frame_buffer: [256]u8 = undefined;
    var output_file_buffer: [512]u8 = undefined;
    _ = try explore.appendFailureRecordFile(io, tmp_dir.dir, "exploration_failures.binlog", .{
        .existing_file_buffer = &existing_file_buffer,
        .record_buffer = &record_buffer,
        .frame_buffer = &frame_buffer,
        .output_file_buffer = &output_file_buffer,
    }, 4, first_failure);

    var file_buffer: [512]u8 = undefined;
    var mode_buffer: [32]u8 = undefined;
    var decoded_decisions: [4]sim.scheduler.ScheduleDecision = undefined;
    const retained_failure = (try explore.readMostRecentFailureRecord(io, tmp_dir.dir, "exploration_failures.binlog", .{
        .file_buffer = &file_buffer,
        .mode_buffer = &mode_buffer,
        .decision_buffer = &decoded_decisions,
    })).?;

    try std.testing.expectEqualStrings("seeded", retained_failure.schedule_mode);
    try std.testing.expect(retained_failure.schedule_seed != null);
    try std.testing.expectEqual(@as(u32, 1), retained_failure.recorded_decision_count);
    try std.testing.expectEqual(@as(usize, 1), retained_failure.recorded_decisions.len);
    try std.testing.expect(retained_failure.trace_metadata != null);
    try std.testing.expect(retained_failure.trace_provenance_summary != null);
    try std.testing.expect(retained_failure.trace_provenance_summary.?.has_provenance);

    var replay_ready_storage: [4]sim.scheduler.ReadyItem = undefined;
    var replay_decision_storage: [4]sim.scheduler.ScheduleDecision = undefined;
    var replayer = try sim.scheduler.Scheduler.init(
        retained_failure.schedule_seed.?,
        &replay_ready_storage,
        &replay_decision_storage,
        .{ .strategy = .seeded },
        null,
    );
    try replayer.enqueueReady(.{ .id = 11, .value = 1 });
    try replayer.enqueueReady(.{ .id = 22, .value = 2 });

    const replayed = try replayer.applyRecordedDecision(retained_failure.recorded_decisions[0]);
    try std.testing.expectEqual(retained_failure.recorded_decisions[0].chosen_id, replayed.chosen_id);
    try std.testing.expectEqual(retained_failure.recorded_decisions[0].chosen_value, replayed.chosen_value);
}
