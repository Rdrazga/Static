const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const failure_bundle = static_testing.testing.failure_bundle;
const liveness = static_testing.testing.liveness;
const sim = static_testing.testing.sim;
const swarm = static_testing.testing.swarm_runner;
const trace = static_testing.testing.trace;

const ScenarioError = sim.fixture.FixtureError;

test "swarm runner drives one deterministic simulation harness" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const variants = [_]swarm.SwarmVariant{
        .{ .variant_id = 1, .variant_weight = 1, .label = "staggered_first" },
        .{ .variant_id = 2, .variant_weight = 1, .label = "same_tick_seeded" },
    };
    const Context = struct {
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
                .allocator = testing.allocator,
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

            const schedule_metadata = sim.scheduler.describeSchedule(
                input.run_identity.seed,
                schedulerConfig(input.variant.variant_id),
            );
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
                .pending_reason = if (input.run_identity.run_index == 1) .{
                    .reason = .reply_sequence_gap,
                    .count = 1,
                    .value = @as(u64, decisions.len),
                    .label = "decision_gap",
                } else null,
                .schedule_mode = schedule_metadata.mode_label,
                .schedule_seed = schedule_metadata.schedule_seed,
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
    var context: Context = .{};
    var artifact_buffer: [256]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var retained_trace_file_buffer: [1024]u8 = undefined;
    var retained_trace_frame_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    const Runner = swarm.SwarmRunner(ScenarioError);

    const summary = try swarm.runSwarm(ScenarioError, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_sim_integration",
            .base_seed = .init(5),
            .build_mode = .debug,
            .profile = .stress,
            .seed_count_max = 4,
            .steps_per_seed_max = 8,
            .failure_retention_max = 1,
            .stop_policy = .collect_failures,
        },
        .scenario = .{
            .context = &context,
            .run_fn = Context.run,
        },
        .variants = &variants,
        .failure_bundle_persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
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
    });

    try testing.expectEqual(@as(u32, 4), summary.executed_run_count);
    try testing.expectEqual(@as(u32, 1), summary.failed_run_count);
    try testing.expectEqual(@as(u32, 1), summary.retained_failure_count);
    try testing.expectEqual(@as(u8, 0b11), context.seen_variant_mask);
    try testing.expect(summary.first_failure != null);

    const first_failure = summary.first_failure.?;
    try testing.expectEqual(@as(u32, 1), first_failure.run_identity.run_index);
    try testing.expect(first_failure.persistedEntryName() != null);
    try testing.expectEqualStrings("sim.expected_failure", first_failure.check_result.violations[0].code);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [1024]u8 = undefined;
    var read_retained_events: [16]static_testing.testing.trace.TraceEvent = undefined;
    var read_retained_labels: [256]u8 = undefined;
    var read_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse_buffer: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const retained_entry = try failure_bundle.readFailureBundle(
        io,
        tmp_dir.dir,
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
    try testing.expectEqual(first_failure.run_identity.seed.value, retained_entry.replay_artifact_view.identity.seed.value);
    try testing.expectEqual(first_failure.trace_metadata.event_count, retained_entry.replay_artifact_view.trace_metadata.event_count);
    try testing.expectEqualStrings("stress", retained_entry.manifest_document.campaign_profile.?);
    try testing.expect(retained_entry.manifest_document.pending_reason != null);
    try testing.expectEqual(liveness.PendingReason.reply_sequence_gap, retained_entry.manifest_document.pending_reason.?.reason);
    try testing.expectEqual(@as(u32, 1), retained_entry.manifest_document.pending_reason.?.count);
    try testing.expectEqual(@as(u64, 2), retained_entry.manifest_document.pending_reason.?.value);
    try testing.expectEqualStrings("decision_gap", retained_entry.manifest_document.pending_reason.?.label.?);
    try testing.expect(retained_entry.trace_document != null);
    try testing.expect(retained_entry.retained_trace != null);
    try testing.expect(retained_entry.trace_document.?.has_provenance);
    try testing.expectEqual(
        retained_entry.trace_document.?.caused_event_count,
        retained_entry.retained_trace.?.provenanceSummary().caused_event_count,
    );
    if (first_failure.variant_id == 1) {
        try testing.expectEqualStrings("first", retained_entry.manifest_document.schedule_mode.?);
        try testing.expect(retained_entry.manifest_document.schedule_seed == null);
    } else {
        try testing.expectEqualStrings("seeded", retained_entry.manifest_document.schedule_mode.?);
        try testing.expect(retained_entry.manifest_document.schedule_seed != null);
    }
}
