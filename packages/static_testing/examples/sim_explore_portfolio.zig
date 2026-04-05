//! Demonstrates bounded portfolio exploration and replay of a retained schedule.

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
    const output_dir_path = ".zig-cache/static_testing/examples/sim_explore_portfolio";
    cwd.deleteTree(io, output_dir_path) catch {};
    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer cleanupOutputDir(cwd, io, output_dir_path);
    defer output_dir.close(io);

    const Context = struct {
        const violations = [_]checker.Violation{
            .{ .code = "schedule.seeded_failure", .message = "seeded candidate retained for replay" },
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

    var summary_buffer: [160]u8 = undefined;
    const summary_line = try explore.formatExplorationSummary(&summary_buffer, summary);
    std.debug.print("{s}\n", .{summary_line});

    assert(summary.first_failure != null);
    const first_failure = summary.first_failure.?;
    assert(first_failure.schedule_seed != null);
    assert(first_failure.trace_provenance_summary != null);

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
    var decoded_decisions: [4]sim.scheduler.ScheduleDecision = undefined;
    const retained_failure = (try explore.readMostRecentFailureRecord(io, output_dir, "exploration_failures.binlog", .{
        .file_buffer = &file_buffer,
        .mode_buffer = &mode_buffer,
        .decision_buffer = &decoded_decisions,
    })).?;
    assert(retained_failure.recorded_decision_count == 1);
    assert(retained_failure.trace_provenance_summary != null);

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
    assert(replayed.chosen_id == retained_failure.recorded_decisions[0].chosen_id);
    std.debug.print(
        "replayed mode={s} seed={s} chosen_id={} persisted=exploration_failures.binlog\n",
        .{
            retained_failure.schedule_mode,
            testing.testing.seed.formatSeed(retained_failure.schedule_seed.?),
            replayed.chosen_id,
        },
    );
}

fn cleanupOutputDir(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) void {
    dir.deleteTree(io, sub_path) catch |err| {
        std.log.warn("Best-effort cleanupOutputDir failed for {s}: {s}.", .{
            sub_path,
            @errorName(err),
        });
    };
}
