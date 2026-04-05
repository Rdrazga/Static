//! Demonstrates bounded PCT-style exploration bias and replay of a retained schedule.

const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

const checker = testing.testing.checker;
const explore = testing.testing.sim.explore;
const sim = testing.testing.sim;

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();
    const output_dir_path = ".zig-cache/static_testing/examples/sim_explore_pct_bias";
    cwd.deleteTree(io, output_dir_path) catch {};
    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer cleanupOutputDir(cwd, io, output_dir_path);
    defer output_dir.close(io);

    const Context = struct {
        const violations = [_]checker.Violation{
            .{ .code = "schedule.pct_bias_failure", .message = "pct bias retained for replay" },
        };

        fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) !explore.ExplorationScenarioExecution {
            var sim_fixture: sim.fixture.Fixture(4, 4, 4, 8) = undefined;
            try sim_fixture.init(.{
                .allocator = std.heap.page_allocator,
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

            try scheduleSameTickChoices(&sim_fixture);
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

        fn scheduleSameTickChoices(sim_fixture: *sim.fixture.Fixture(4, 4, 4, 8)) !void {
            _ = try sim_fixture.scheduleAfter(.{ .id = 11, .value = 1 }, .init(1));
            _ = try sim_fixture.scheduleAfter(.{ .id = 22, .value = 2 }, .init(1));
            _ = try sim_fixture.scheduleAfter(.{ .id = 33, .value = 3 }, .init(1));
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

    var summary_buffer: [160]u8 = undefined;
    const summary_line = try explore.formatExplorationSummary(&summary_buffer, summary);
    std.debug.print("{s}\n", .{summary_line});

    assert(summary.first_failure != null);
    const first_failure = summary.first_failure.?;
    assert(std.mem.eql(u8, first_failure.schedule_mode, "pct_bias"));
    assert(first_failure.schedule_seed != null);

    var existing_file_buffer: [512]u8 = undefined;
    var record_buffer: [256]u8 = undefined;
    var frame_buffer: [256]u8 = undefined;
    var output_file_buffer: [512]u8 = undefined;
    _ = try explore.appendFailureRecordFile(io, output_dir, "exploration_failures.binlog", .{
        .existing_file_buffer = &existing_file_buffer,
        .record_buffer = &record_buffer,
        .frame_buffer = &frame_buffer,
        .output_file_buffer = &output_file_buffer,
    }, 8, first_failure);

    var file_buffer: [512]u8 = undefined;
    var mode_buffer: [32]u8 = undefined;
    var decoded_decisions: [8]sim.scheduler.ScheduleDecision = undefined;
    const retained_failure = (try explore.readMostRecentFailureRecord(io, output_dir, "exploration_failures.binlog", .{
        .file_buffer = &file_buffer,
        .mode_buffer = &mode_buffer,
        .decision_buffer = &decoded_decisions,
    })).?;

    const replay_candidate = try candidateFromRecord(retained_failure);
    var replayer_ready_storage: [4]sim.scheduler.ReadyItem = undefined;
    var replayer_decision_storage: [4]sim.scheduler.ScheduleDecision = undefined;
    var replayer = try sim.scheduler.Scheduler.init(
        replay_candidate.scheduler_seed,
        &replayer_ready_storage,
        &replayer_decision_storage,
        replay_candidate.scheduler_config,
        null,
    );
    try replayer.enqueueReady(.{ .id = 11, .value = 1 });
    try replayer.enqueueReady(.{ .id = 22, .value = 2 });
    try replayer.enqueueReady(.{ .id = 33, .value = 3 });

    for (retained_failure.recorded_decisions) |decision| {
        const replayed = try replayer.applyRecordedDecision(decision);
        assert(replayed.chosen_id == decision.chosen_id);
    }

    std.debug.print(
        "replayed mode={s} schedule={d} seed={s} decisions={d}\n",
        .{
            retained_failure.schedule_mode,
            retained_failure.schedule_index,
            testing.testing.seed.formatSeed(retained_failure.schedule_seed.?),
            retained_failure.recorded_decision_count,
        },
    );
}

fn candidateFromRecord(record: explore.ExplorationFailureRecord) !explore.ExplorationCandidate {
    if (!std.mem.eql(u8, record.schedule_mode, "pct_bias")) return error.InvalidInput;
    return .{
        .schedule_index = record.schedule_index,
        .scheduler_config = .{
            .strategy = .pct_bias,
            .pct_preemption_step = record.schedule_index,
        },
        .scheduler_seed = record.schedule_seed orelse return error.InvalidInput,
        .schedule_metadata = .{
            .mode_label = record.schedule_mode,
            .schedule_seed = record.schedule_seed,
        },
    };
}

fn cleanupOutputDir(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) void {
    dir.deleteTree(io, sub_path) catch |err| {
        std.log.warn("Best-effort cleanupOutputDir failed for {s}: {s}.", .{
            sub_path,
            @errorName(err),
        });
    };
}
