const std = @import("std");
const testing = @import("static_testing");

const failure_threshold: u64 = 1024;
const violations = [_]testing.testing.checker.Violation{
    .{ .code = "threshold", .message = "seed reached the failure threshold" },
};

test "fuzz runner persists a reduced failing seed and replay reproduces it" {
    // Method: Drive the runner to its first deterministic failure, persist the
    // reduced seed, then replay the stored artifact through the high-level
    // replay path to prove the persisted case remains actionable.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const config = testing.testing.fuzz_runner.FuzzConfig{
        .package_name = "static_testing",
        .run_name = "fuzz_persistence",
        .base_seed = .{ .value = 2026 },
        .build_mode = .debug,
        .case_count_max = 16,
        .reduction_budget = .{
            .max_attempts = 64,
            .max_successes = 64,
        },
    };

    const first_failing = blk: {
        const candidate = findFirstFailingSeed(config);
        std.debug.assert(candidate != null);
        break :blk candidate.?;
    };
    try std.testing.expect(first_failing.case_index < config.case_count_max);

    const Runner = testing.testing.fuzz_runner.FuzzRunner(error{}, error{});
    var target_context = TargetContext{ .threshold = failure_threshold };
    var reducer_context = ReducerContext{ .threshold = failure_threshold };
    var artifact_buffer: [256]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const runner = Runner{
        .config = config,
        .target = .{
            .context = &target_context,
            .run_fn = TargetContext.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "phase2_fuzz_test" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
        .seed_reducer = .{
            .context = &reducer_context,
            .measure_fn = ReducerContext.measure,
            .next_fn = ReducerContext.next,
            .is_interesting_fn = ReducerContext.isInteresting,
        },
    };

    const summary = try runner.run();
    try std.testing.expect(summary.failed_case != null);

    const failed_case = summary.failed_case.?;
    try std.testing.expect(failed_case.persisted_entry_name != null);
    try std.testing.expect(failed_case.reduced_seed != null);
    try std.testing.expectEqual(first_failing.case_index, failed_case.run_identity.case_index);
    try std.testing.expect(failed_case.run_identity.seed.value < first_failing.seed.value);
    try std.testing.expect(failed_case.run_identity.seed.value >= failure_threshold);
    try std.testing.expect(failed_case.run_identity.seed.value < failure_threshold * 2);

    var read_buffer: [256]u8 = undefined;
    const entry = try testing.testing.corpus.readCorpusEntry(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        &read_buffer,
    );

    try std.testing.expectEqual(
        testing.testing.identity.identityHash(failed_case.run_identity),
        entry.meta.identity_hash,
    );
    try std.testing.expectEqual(
        failed_case.run_identity.seed.value,
        entry.artifact.identity.seed.value,
    );
    try std.testing.expectEqual(
        failed_case.trace_metadata.last_timestamp_ns,
        entry.artifact.trace_metadata.last_timestamp_ns,
    );

    var replay_context = ReplayContext{ .threshold = failure_threshold };
    const outcome = try testing.testing.replay_runner.runReplay(
        error{},
        read_buffer[0..entry.meta.artifact_bytes_len],
        .{
            .context = &replay_context,
            .run_fn = ReplayContext.run,
        },
        .{
            .expected_identity_hash = entry.meta.identity_hash,
        },
    );

    try std.testing.expectEqual(
        testing.testing.replay_runner.ReplayOutcome.violation_reproduced,
        outcome,
    );
}

const TargetContext = struct {
    threshold: u64,

    fn run(
        context_ptr: *const anyopaque,
        run_identity: testing.testing.identity.RunIdentity,
    ) error{}!testing.testing.fuzz_runner.FuzzExecution {
        const context: *const TargetContext = @ptrCast(@alignCast(context_ptr));
        const failing = run_identity.seed.value >= context.threshold;
        return .{
            .trace_metadata = makeTraceMetadata(run_identity),
            .check_result = if (failing)
                testing.testing.checker.CheckResult.fail(&violations, null)
            else
                testing.testing.checker.CheckResult.pass(null),
        };
    }
};

const ReplayContext = struct {
    threshold: u64,

    fn run(
        context_ptr: *const anyopaque,
        artifact: testing.testing.replay_artifact.ReplayArtifactView,
    ) error{}!testing.testing.replay_runner.ReplayExecution {
        const context: *const ReplayContext = @ptrCast(@alignCast(context_ptr));
        const run_identity = artifact.identity;
        const failing = run_identity.seed.value >= context.threshold;
        return .{
            .trace_metadata = makeTraceMetadata(run_identity),
            .check_result = if (failing)
                testing.testing.checker.CheckResult.fail(&violations, null)
            else
                testing.testing.checker.CheckResult.pass(null),
        };
    }
};

const ReducerContext = struct {
    threshold: u64,

    fn measure(_: *const anyopaque, candidate: testing.testing.seed.Seed) u64 {
        return candidate.value;
    }

    fn next(
        _: *const anyopaque,
        current: testing.testing.seed.Seed,
        _: u32,
    ) error{}!?testing.testing.seed.Seed {
        if (current.value <= 1) return null;
        return testing.testing.seed.Seed.init(@divFloor(current.value, 2));
    }

    fn isInteresting(
        context_ptr: *const anyopaque,
        candidate: testing.testing.seed.Seed,
    ) error{}!bool {
        const context: *const ReducerContext = @ptrCast(@alignCast(context_ptr));
        return candidate.value >= context.threshold;
    }
};

const FirstFailingSeed = struct {
    case_index: u32,
    seed: testing.testing.seed.Seed,
};

fn findFirstFailingSeed(
    config: testing.testing.fuzz_runner.FuzzConfig,
) ?FirstFailingSeed {
    var case_index: u32 = 0;
    while (case_index < config.case_count_max) : (case_index += 1) {
        const case_seed = testing.testing.seed.splitSeed(config.base_seed, case_index);
        if (case_seed.value >= failure_threshold) {
            return .{
                .case_index = case_index,
                .seed = case_seed,
            };
        }
    }
    return null;
}

fn makeTraceMetadata(
    run_identity: testing.testing.identity.RunIdentity,
) testing.testing.trace.TraceMetadata {
    const timestamp_ns = run_identity.seed.value & 0xffff;
    return .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = run_identity.case_index,
        .last_sequence_no = run_identity.case_index,
        .first_timestamp_ns = timestamp_ns,
        .last_timestamp_ns = timestamp_ns,
    };
}
