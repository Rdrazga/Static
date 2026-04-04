const std = @import("std");
const hash = @import("static_hash");
const testing = @import("static_testing");

const checker = testing.testing.checker;
const corpus = testing.testing.corpus;
const fuzz_runner = testing.testing.fuzz_runner;
const identity = testing.testing.identity;
const replay_artifact = testing.testing.replay_artifact;
const replay_runner = testing.testing.replay_runner;
const seed_mod = testing.testing.seed;
const trace = testing.testing.trace;
const reducer_helpers = @import("seed_reducer_helpers.zig");

const ordered_violation = [_]checker.Violation{
    .{
        .code = "combine_ordered",
        .message = "ordered combiner lost deterministic ordering behavior",
    },
};

const unordered_violation = [_]checker.Violation{
    .{
        .code = "combine_unordered",
        .message = "unordered combiner lost commutativity",
    },
};

const multiset_violation = [_]checker.Violation{
    .{
        .code = "combine_multiset",
        .message = "multiset combiner lost permutation invariance",
    },
};

const multiplicity_violation = [_]checker.Violation{
    .{
        .code = "combine_multiplicity",
        .message = "multiset combiner stopped distinguishing duplicate elements",
    },
};

const alias_violation = [_]checker.Violation{
    .{
        .code = "combine_alias",
        .message = "combine aliases diverged from the direct entrypoints",
    },
};

test "deterministic replay-backed combine campaigns preserve algebraic invariants" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const config = fuzz_runner.FuzzConfig{
        .package_name = "static_hash",
        .run_name = "combine_invariants",
        .base_seed = .{ .value = 0x17b4_2026_0000_0003 },
        .build_mode = .debug,
        .case_count_max = 128,
        .reduction_budget = .{
            .max_attempts = 64,
            .max_successes = 64,
        },
    };

    var target_context = CombineTargetContext{};
    const CombineSeedReducerContext = reducer_helpers.SeedReducerContext(
        CombineTargetContext,
        CombineTargetContext.run,
    );
    var reducer_context = CombineSeedReducerContext{
        .target_context = &target_context,
        .config = config,
    };
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const runner = Runner{
        .config = config,
        .target = .{
            .context = &target_context,
            .run_fn = CombineTargetContext.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_hash_combine" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
        .seed_reducer = reducer_context.buildReducer(),
    };

    const summary = try runner.run();
    try expectNoFailureOrReplay(
        io,
        tmp_dir.dir,
        summary,
        &target_context,
        CombineTargetContext.replay,
    );
    try std.testing.expectEqual(config.case_count_max, summary.executed_case_count);
}

const CombineTargetContext = struct {
    fn run(
        context_ptr: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const context: *const CombineTargetContext = @ptrCast(@alignCast(context_ptr));
        _ = context;
        const evaluation = evaluateCombineCase(run_identity.seed);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity),
            .check_result = evaluation.toCheckResult(),
        };
    }

    fn replay(
        context_ptr: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution {
        const context: *const CombineTargetContext = @ptrCast(@alignCast(context_ptr));
        _ = context;
        const evaluation = evaluateCombineCase(artifact.identity.seed);
        return .{
            .trace_metadata = makeTraceMetadata(artifact.identity),
            .check_result = evaluation.toCheckResult(),
        };
    }
};

const Evaluation = struct {
    violations: ?[]const checker.Violation,
    checkpoint_digest: checker.CheckpointDigest,

    fn toCheckResult(self: Evaluation) checker.CheckResult {
        if (self.violations) |violations| {
            return checker.CheckResult.fail(violations, self.checkpoint_digest);
        }
        return checker.CheckResult.pass(self.checkpoint_digest);
    }
};

const CombineCase = struct {
    values: [6]u64,
    len: usize,
};

fn evaluateCombineCase(case_seed: seed_mod.Seed) Evaluation {
    const generated = buildCombineCase(case_seed.value);
    const values = generated.values[0..generated.len];

    const pair: hash.Pair64 = .{
        .left = values[0],
        .right = values[1],
    };
    const swapped_pair: hash.Pair64 = .{
        .left = pair.right,
        .right = pair.left,
    };

    const ordered = hash.combineOrdered64(pair);
    if (hash.combine.ordered(pair) != ordered) {
        return failEvaluation(&alias_violation, ordered);
    }

    if (pair.left != pair.right and ordered == hash.combineOrdered64(swapped_pair)) {
        return failEvaluation(&ordered_violation, ordered);
    }

    const unordered = hash.combineUnordered64(pair);
    if (hash.combine.unordered(pair) != unordered) {
        return failEvaluation(&alias_violation, unordered);
    }
    if (unordered != hash.combineUnordered64(swapped_pair)) {
        return failEvaluation(&unordered_violation, unordered);
    }

    const multiset_forward = foldUnorderedMultiset(values);
    if (multiset_forward != foldUnorderedMultisetReverse(values)) {
        return failEvaluation(&multiset_violation, multiset_forward);
    }
    if (multiset_forward != foldUnorderedMultisetRotated(values)) {
        return failEvaluation(&multiset_violation, multiset_forward);
    }

    const duplicate_value = chooseMultiplicityValue(values, case_seed.value);
    const multiset_duplicate = hash.combineUnorderedMultiset64(multiset_forward, duplicate_value);
    if (multiset_duplicate == multiset_forward) {
        return failEvaluation(&multiplicity_violation, multiset_duplicate);
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(makeCheckpoint(
            ordered ^ unordered,
            multiset_forward,
        )),
    };
}

fn buildCombineCase(seed_value: u64) CombineCase {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0xd1b5_4a32_98ef_1027);
    const random = prng.random();

    var values: [6]u64 = undefined;
    for (&values, 0..) |*value, index| {
        value.* = random.int(u64) ^ (@as(u64, @intCast(index)) *% 0x9e37_79b9_7f4a_7c15);
    }

    return .{
        .values = values,
        .len = 2 + @as(usize, @intCast(seed_value % 5)),
    };
}

fn foldUnorderedMultiset(values: []const u64) u64 {
    var acc: u64 = 0;
    for (values) |value| {
        acc = hash.combineUnorderedMultiset64(acc, value);
    }
    return acc;
}

fn foldUnorderedMultisetReverse(values: []const u64) u64 {
    var acc: u64 = 0;
    var index = values.len;
    while (index > 0) {
        index -= 1;
        acc = hash.combineUnorderedMultiset64(acc, values[index]);
    }
    return acc;
}

fn foldUnorderedMultisetRotated(values: []const u64) u64 {
    var acc: u64 = 0;
    if (values.len == 0) return acc;

    for (values[1..]) |value| {
        acc = hash.combineUnorderedMultiset64(acc, value);
    }
    acc = hash.combineUnorderedMultiset64(acc, values[0]);
    return acc;
}

fn chooseMultiplicityValue(values: []const u64, case_seed_value: u64) u64 {
    for (values) |value| {
        if (hash.combine.mix64(value) != 0) return value;
    }

    const fallbacks = [_]u64{
        1,
        0xdead_beef_dead_beef,
        case_seed_value ^ 0x9e37_79b9_7f4a_7c15,
    };
    inline for (fallbacks) |value| {
        if (hash.combine.mix64(value) != 0) return value;
    }
    unreachable;
}

fn expectNoFailureOrReplay(
    io: std.Io,
    dir: std.Io.Dir,
    summary: fuzz_runner.FuzzRunSummary,
    replay_context: *CombineTargetContext,
    replay_fn: *const fn (
        context: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution,
) !void {
    if (summary.failed_case) |failed_case| {
        try std.testing.expect(failed_case.persisted_entry_name != null);

        var read_buffer: [512]u8 = undefined;
        const entry = try corpus.readCorpusEntry(
            io,
            dir,
            failed_case.persisted_entry_name.?,
            &read_buffer,
        );

        const outcome = try replay_runner.runReplay(error{}, read_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))], .{
            .context = replay_context,
            .run_fn = replay_fn,
        }, .{
            .expected_identity_hash = entry.meta.identity_hash,
        });
        try std.testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, outcome);

        std.debug.print("static_hash combine regression persisted at {s}\n", .{
            failed_case.persisted_entry_name.?,
        });
        for (failed_case.check_result.violations) |violation| {
            std.debug.print("violation {s}: {s}\n", .{
                violation.code,
                violation.message,
            });
        }
        return error.TestUnexpectedResult;
    }
}

fn failEvaluation(
    violations: []const checker.Violation,
    checkpoint_value: u64,
) Evaluation {
    return .{
        .violations = violations,
        .checkpoint_digest = checker.CheckpointDigest.init(@as(u128, checkpoint_value)),
    };
}

fn makeTraceMetadata(run_identity: identity.RunIdentity) trace.TraceMetadata {
    const low = run_identity.seed.value & 0xffff;
    return .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = run_identity.case_index,
        .last_sequence_no = run_identity.case_index,
        .first_timestamp_ns = low,
        .last_timestamp_ns = low,
    };
}

fn makeCheckpoint(left: u64, right: u64) u128 {
    return (@as(u128, right) << 64) | left;
}
