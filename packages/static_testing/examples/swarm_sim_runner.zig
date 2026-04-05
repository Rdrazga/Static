//! Demonstrates a bounded swarm campaign over the deterministic simulation layer.

const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

const checker = testing.testing.checker;
const failure_bundle = testing.testing.failure_bundle;
const sim = testing.testing.sim;
const swarm = testing.testing.swarm_runner;
const trace = testing.testing.trace;

const ScenarioError = sim.fixture.FixtureError;

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();
    const output_dir_path = ".zig-cache/static_testing/examples/swarm_sim_runner";
    cleanupOutputDir(cwd, io, output_dir_path);

    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer cleanupOutputDir(cwd, io, output_dir_path);
    defer output_dir.close(io);

    const variants = [_]swarm.SwarmVariant{
        .{ .variant_id = 1, .variant_weight = 1, .label = "staggered_first" },
        .{ .variant_id = 2, .variant_weight = 1, .label = "same_tick_seeded" },
    };
    var scenario_context: ScenarioContext = .{};
    var progress_context: ProgressContext = .{};
    var artifact_buffer: [256]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var retained_trace_file_buffer: [1024]u8 = undefined;
    var retained_trace_frame_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    var campaign_existing_file_buffer: [4096]u8 = undefined;
    var campaign_record_buffer: [256]u8 = undefined;
    var campaign_frame_buffer: [256]u8 = undefined;
    var campaign_output_file_buffer: [4096]u8 = undefined;
    var campaign_read_file_buffer: [4096]u8 = undefined;
    var campaign_read_entry_name_buffer: [128]u8 = undefined;
    var campaign_variant_summaries: [4]swarm.SwarmCampaignVariantSummary = undefined;
    var campaign_retained_seeds: [4]swarm.SwarmRetainedSeedSuggestion = undefined;
    var campaign_summary_buffer: [512]u8 = undefined;
    const Runner = swarm.SwarmRunner(ScenarioError);

    const summary = try swarm.runSwarm(ScenarioError, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_sim_runner_example",
            .base_seed = .init(5),
            .build_mode = .debug,
            .profile = .stress,
            .seed_count_max = 4,
            .steps_per_seed_max = 8,
            .failure_retention_max = 1,
            .stop_policy = .collect_failures,
            .progress_every_n_runs = 2,
        },
        .scenario = .{
            .context = &scenario_context,
            .run_fn = ScenarioContext.run,
        },
        .variants = &variants,
        .failure_bundle_persistence = .{
            .io = io,
            .dir = output_dir,
            .entry_name_buffer = &entry_name_buffer,
            .artifact_buffer = &artifact_buffer,
            .manifest_buffer = &manifest_buffer,
            .trace_buffer = &trace_buffer,
            .retained_trace_file_buffer = &retained_trace_file_buffer,
            .retained_trace_frame_buffer = &retained_trace_frame_buffer,
            .violations_buffer = &violations_buffer,
            .context = .{
                .artifact_selection = .{ .trace_artifact = .summary_and_retained },
            },
        },
        .campaign_persistence = .{
            .io = io,
            .dir = output_dir,
            .resume_mode = .fresh,
            .max_records = 16,
            .append_buffers = .{
                .existing_file_buffer = &campaign_existing_file_buffer,
                .record_buffer = &campaign_record_buffer,
                .frame_buffer = &campaign_frame_buffer,
                .output_file_buffer = &campaign_output_file_buffer,
            },
            .read_buffers = .{
                .file_buffer = &campaign_read_file_buffer,
                .entry_name_buffer = &campaign_read_entry_name_buffer,
            },
        },
        .progress = .{
            .context = &progress_context,
            .report_fn = ProgressContext.report,
        },
    });

    assert(summary.executed_run_count == 4);
    assert(summary.failed_run_count == 1);
    assert(summary.retained_failure_count == 1);
    assert(summary.first_failure != null);
    assert(scenario_context.seen_variant_mask == 0b11);
    assert(progress_context.report_count == 2);

    const first_failure = summary.first_failure.?;
    assert(first_failure.persistedEntryName() != null);
    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [1024]u8 = undefined;
    var read_retained_events: [16]testing.testing.trace.TraceEvent = undefined;
    var read_retained_labels: [256]u8 = undefined;
    var read_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse_buffer: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const retained_entry = try failure_bundle.readFailureBundle(
        io,
        output_dir,
        first_failure.persistedEntryName().?,
        .{
            .selection = .{
                .trace_artifact = .summary_and_retained,
            },
            .artifact_buffer = &read_artifact_buffer,
            .manifest_buffer = &read_manifest_buffer,
            .manifest_parse_buffer = &read_manifest_parse_buffer,
            .trace_buffer = &read_trace_buffer,
            .trace_parse_buffer = &read_trace_parse_buffer,
            .retained_trace_file_buffer = &read_retained_trace_file,
            .retained_trace_events_buffer = &read_retained_events,
            .retained_trace_label_buffer = &read_retained_labels,
            .violations_buffer = &read_violations_buffer,
            .violations_parse_buffer = &read_violations_parse_buffer,
        },
    );
    assert(retained_entry.replay_artifact_view.identity.seed.value == first_failure.run_identity.seed.value);
    assert(std.mem.eql(u8, retained_entry.manifest_document.campaign_profile.?, "stress"));
    assert(retained_entry.trace_document != null);
    assert(retained_entry.retained_trace != null);

    const campaign_summary = (try swarm.summarizeCampaignRecords(
        io,
        output_dir,
        "swarm_campaign.binlog",
        .{
            .file_buffer = &campaign_read_file_buffer,
            .entry_name_buffer = &campaign_read_entry_name_buffer,
            .variant_summaries_buffer = &campaign_variant_summaries,
            .retained_seed_suggestions_buffer = &campaign_retained_seeds,
        },
    )).?;
    const campaign_summary_text = try swarm.formatCampaignSummary(
        &campaign_summary_buffer,
        campaign_summary,
    );
    assert(campaign_summary.total_run_count == 4);
    assert(campaign_summary.failed_run_count == 1);
    assert(campaign_summary.retained_failure_count == 1);
    assert(campaign_summary.variant_summaries.len == 2);
    assert(campaign_summary.retained_seed_suggestions.len == 1);
    assert(std.mem.indexOf(u8, campaign_summary_text, "campaign runs=4 failed=1 retained=1 variants=2") != null);
}

fn cleanupOutputDir(
    dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
) void {
    dir.deleteTree(io, sub_path) catch {};
}

const ScenarioContext = struct {
    const Self = @This();
    const invariant_violations = [_]checker.Violation{
        .{ .code = "sim.expected_failure", .message = "run index 1 is reserved as a retained failure" },
    };
    const structure_violations = [_]checker.Violation{
        .{ .code = "sim.decision_count", .message = "simulation did not produce the expected decision count" },
    };

    seen_variant_mask: u8 = 0,
    retained_trace_events: [16]trace.TraceEvent = undefined,
    retained_trace_labels: [256]u8 = undefined,

    fn run(context: *const anyopaque, input: swarm.SwarmScenarioInput) ScenarioError!swarm.SwarmScenarioExecution {
        const typed_context: *Self = @ptrCast(@alignCast(@constCast(context)));
        typed_context.seenVariant(input.variant.variant_id);
        return typed_context.runSimulationHarness(input);
    }

    fn seenVariant(self: *Self, variant_id: u32) void {
        if (variant_id == 1) {
            self.seen_variant_mask |= 0b01;
        } else {
            self.seen_variant_mask |= 0b10;
        }
    }

    fn runSimulationHarness(
        self: *Self,
        input: swarm.SwarmScenarioInput,
    ) ScenarioError!swarm.SwarmScenarioExecution {
        var sim_fixture: sim.fixture.Fixture(4, 4, 4, 16) = undefined;
        try sim_fixture.init(.{
            .allocator = std.heap.page_allocator,
            .timer_queue_config = .{
                .buckets = 8,
                .timers_max = 8,
            },
            .scheduler_seed = input.run_identity.seed,
            .scheduler_config = schedulerConfig(input.variant.variant_id),
            .event_loop_config = .{ .step_budget_max = input.steps_per_seed_max },
            .trace_config = .{
                .max_events = 16,
            },
        });
        defer sim_fixture.deinit();

        try scheduleScenario(&sim_fixture, input.variant.variant_id);

        const run_result = try sim_fixture.runUntil(.init(3));
        try appendProvenanceTrace(&sim_fixture, input.run_identity.run_index);
        const decisions = sim_fixture.recordedDecisions();
        const trace_metadata = sim_fixture.traceMetadata().?;
        const trace_provenance_summary = sim_fixture.traceProvenanceSummary();
        const retained_trace_snapshot = if (sim_fixture.traceSnapshot()) |snapshot|
            try trace.captureSnapshot(.{
                .events_buffer = &self.retained_trace_events,
                .label_buffer = &self.retained_trace_labels,
            }, snapshot)
        else
            null;

        return .{
            .steps_executed = run_result.steps_run,
            .trace_metadata = trace_metadata,
            .trace_provenance_summary = trace_provenance_summary,
            .retained_trace_snapshot = retained_trace_snapshot,
            .check_result = makeCheckResult(input.run_identity.run_index, decisions.len),
        };
    }

    fn schedulerConfig(variant_id: u32) sim.scheduler.SchedulerConfig {
        return .{
            .strategy = if (variant_id == 1) .first else .seeded,
        };
    }

    fn scheduleScenario(
        sim_fixture: *sim.fixture.Fixture(4, 4, 4, 16),
        variant_id: u32,
    ) ScenarioError!void {
        if (variant_id == 1) {
            _ = try sim_fixture.scheduleAfter(.{ .id = 11, .value = 1 }, .init(1));
            _ = try sim_fixture.scheduleAfter(.{ .id = 22, .value = 2 }, .init(2));
            return;
        }

        _ = try sim_fixture.scheduleAfter(.{ .id = 11, .value = 1 }, .init(1));
        _ = try sim_fixture.scheduleAfter(.{ .id = 22, .value = 2 }, .init(1));
    }

    fn appendProvenanceTrace(
        sim_fixture: *sim.fixture.Fixture(4, 4, 4, 16),
        run_index: u32,
    ) ScenarioError!void {
        const trace_buffer = sim_fixture.traceBufferPtr().?;
        const snapshot = trace_buffer.snapshot();
        const root_sequence_no: u32 = if (snapshot.items.len == 0)
            0
        else
            snapshot.items[snapshot.items.len - 1].sequence_no + 1;
        try trace_buffer.append(.{
            .timestamp_ns = 10,
            .category = .decision,
            .label = "swarm_decision",
            .value = run_index,
        });
        try trace_buffer.append(.{
            .timestamp_ns = 11,
            .category = .info,
            .label = "swarm_apply",
            .value = run_index,
            .lineage = .{
                .cause_sequence_no = root_sequence_no,
                .correlation_id = run_index,
                .surface_label = "swarm_sim",
            },
        });
    }

    fn makeCheckResult(run_index: u32, decision_count: usize) checker.CheckResult {
        if (run_index == 1) {
            return checker.CheckResult.fail(
                &invariant_violations,
                checker.CheckpointDigest.init(@as(u128, @intCast(decision_count))),
            );
        }
        if (decision_count != 2) {
            return checker.CheckResult.fail(
                &structure_violations,
                checker.CheckpointDigest.init(@as(u128, @intCast(decision_count))),
            );
        }
        return checker.CheckResult.pass(
            checker.CheckpointDigest.init(@as(u128, @intCast(decision_count))),
        );
    }
};

const ProgressContext = struct {
    const Self = @This();

    report_count: u32 = 0,

    fn report(context: *const anyopaque, progress: swarm.SwarmProgress) void {
        const typed_context: *Self = @ptrCast(@alignCast(@constCast(context)));
        typed_context.report_count += 1;

        var buffer: [160]u8 = undefined;
        const line = swarm.formatProgressSummary(&buffer, progress) catch unreachable;
        std.debug.print("{s}\n", .{line});
    }
};
