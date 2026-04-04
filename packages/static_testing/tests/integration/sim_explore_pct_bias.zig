const std = @import("std");
const testing = @import("static_testing");

test "simulation exploration pct bias retains one failing schedule that replays" {
    const checker = testing.testing.checker;
    const explore = testing.testing.sim.explore;
    const sim = testing.testing.sim;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const Context = struct {
        const violations = [_]checker.Violation{
            .{ .code = "schedule.pct_bias_failure", .message = "pct bias retained for replay" },
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
            _ = try sim_fixture.scheduleAfter(.{ .id = 33, .value = 3 }, .init(1));

            _ = try sim_fixture.runForSteps(3);
            const decisions = sim_fixture.recordedDecisions();

            return .{
                .check_result = if (std.mem.eql(u8, input.candidate.schedule_metadata.mode_label, "pct_bias"))
                    checker.CheckResult.fail(&violations, null)
                else
                    checker.CheckResult.pass(null),
                .recorded_decisions = decisions,
                .trace_metadata = sim_fixture.traceMetadata(),
            };
        }
    };
    const scenario = explore.ExplorationScenario(anyerror){
        .context = undefined,
        .run_fn = Context.run,
    };
    var decision_buffer: [8]sim.scheduler.ScheduleDecision = undefined;

    const summary = try explore.runExploration(anyerror, .{
        .mode = .pct_bias,
        .base_seed = .init(23),
        .schedules_max = 2,
    }, scenario, .{
        .decision_buffer = &decision_buffer,
    });

    try std.testing.expectEqual(@as(u32, 2), summary.executed_schedule_count);
    try std.testing.expectEqual(@as(u32, 2), summary.failed_schedule_count);
    try std.testing.expect(summary.first_failure != null);

    const first_failure = summary.first_failure.?;
    try std.testing.expectEqualStrings("pct_bias", first_failure.schedule_mode);
    try std.testing.expect(first_failure.schedule_seed != null);
    try std.testing.expectEqual(@as(u32, 2), first_failure.recorded_decision_count);
    try std.testing.expectEqual(@as(usize, 2), first_failure.recorded_decisions.len);

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
    var decoded_decisions: [8]sim.scheduler.ScheduleDecision = undefined;
    const retained_failure = (try explore.readMostRecentFailureRecord(io, tmp_dir.dir, "exploration_failures.binlog", .{
        .file_buffer = &file_buffer,
        .mode_buffer = &mode_buffer,
        .decision_buffer = &decoded_decisions,
    })).?;

    try std.testing.expectEqualStrings("pct_bias", retained_failure.schedule_mode);
    try std.testing.expectEqual(first_failure.schedule_index, retained_failure.schedule_index);
    try std.testing.expectEqual(first_failure.schedule_seed.?.value, retained_failure.schedule_seed.?.value);

    var replay_ready_storage: [4]sim.scheduler.ReadyItem = undefined;
    var replay_decision_storage: [4]sim.scheduler.ScheduleDecision = undefined;
    var replayer = try sim.scheduler.Scheduler.init(
        retained_failure.schedule_seed.?,
        &replay_ready_storage,
        &replay_decision_storage,
        .{
            .strategy = .pct_bias,
            .pct_preemption_step = retained_failure.schedule_index,
        },
        null,
    );
    try replayer.enqueueReady(.{ .id = 11, .value = 1 });
    try replayer.enqueueReady(.{ .id = 22, .value = 2 });
    try replayer.enqueueReady(.{ .id = 33, .value = 3 });

    for (retained_failure.recorded_decisions) |decision| {
        const replayed = try replayer.applyRecordedDecision(decision);
        try std.testing.expectEqual(decision.chosen_id, replayed.chosen_id);
        try std.testing.expectEqual(decision.chosen_value, replayed.chosen_value);
    }
}
