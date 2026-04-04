const builtin = @import("builtin");
const std = @import("std");
const hash = @import("static_hash");
const testing = @import("static_testing");

const checker = testing.testing.checker;
const corpus = testing.testing.corpus;
const failure_bundle = testing.testing.failure_bundle;
const fuzz_runner = testing.testing.fuzz_runner;
const identity = testing.testing.identity;
const replay_artifact = testing.testing.replay_artifact;
const replay_runner = testing.testing.replay_runner;
const seed_mod = testing.testing.seed;
const trace = testing.testing.trace;
const reducer_helpers = @import("seed_reducer_helpers.zig");

const streaming_violation = [_]checker.Violation{
    .{
        .code = "byte_hash_invariant",
        .message = "streaming or direct byte-hash invariant diverged",
    },
};

const structural_padding_violation = [_]checker.Violation{
    .{
        .code = "structural_padding",
        .message = "equal values with different padding produced different hashes",
    },
};

const structural_slice_violation = [_]checker.Violation{
    .{
        .code = "structural_slice_content",
        .message = "equal slice-backed values produced different content hashes",
    },
};

const structural_slice_strict_violation = [_]checker.Violation{
    .{
        .code = "structural_slice_strict",
        .message = "strict slice-backed hashing diverged across equal values",
    },
};

const structural_slice_stable_violation = [_]checker.Violation{
    .{
        .code = "structural_slice_stable",
        .message = "stable slice-backed hashing diverged across equal values",
    },
};

const structural_float_violation = [_]checker.Violation{
    .{
        .code = "float_canonicalization",
        .message = "float canonicalization or stable encoding diverged",
    },
};

const structural_budget_equivalence_violation = [_]checker.Violation{
    .{
        .code = "budget_equivalence",
        .message = "unlimited budget changed structural hashing semantics",
    },
};

const structural_budget_limit_violation = [_]checker.Violation{
    .{
        .code = "budget_limit",
        .message = "bounded structural hashing failed to reject an over-budget input",
    },
};

const structural_budget_bytes_hash_any_violation = [_]checker.Violation{
    .{
        .code = "budget_bytes_hash_any",
        .message = "hashAnyBudgeted did not reject an over-byte-limit slice",
    },
};

const structural_budget_bytes_stable_violation = [_]checker.Violation{
    .{
        .code = "budget_bytes_stable",
        .message = "stableHashAnyBudgeted did not reject an over-byte-limit slice",
    },
};

const structural_budget_elems_hash_any_violation = [_]checker.Violation{
    .{
        .code = "budget_elems_hash_any",
        .message = "hashAnyBudgeted did not reject an over-element-limit slice",
    },
};

const structural_budget_elems_stable_violation = [_]checker.Violation{
    .{
        .code = "budget_elems_stable",
        .message = "stableHashAnyBudgeted did not reject an over-element-limit slice",
    },
};

const structural_budget_depth_hash_any_violation = [_]checker.Violation{
    .{
        .code = "budget_depth_hash_any",
        .message = "hashAnyBudgeted did not reject an over-depth nested value",
    },
};

const structural_budget_depth_stable_violation = [_]checker.Violation{
    .{
        .code = "budget_depth_stable",
        .message = "stableHashAnyBudgeted did not reject an over-depth nested value",
    },
};

const structural_strict_violation = [_]checker.Violation{
    .{
        .code = "strict_alignment",
        .message = "strict and non-strict hashing diverged on pointer-free data",
    },
};

const PaddedKey = struct {
    tag: u8,
    value: u32,
};

const SliceKey = struct {
    bytes: []const u8,
    flag: bool,
};

const StrictValue = struct {
    head: u16,
    tail: [3]u8,
    mode: enum { alpha, beta, gamma },
};

const BudgetValue = struct {
    header: [3]u8,
    items: [3]PaddedKey,
    maybe: ?u16,
    mode: enum { alpha, beta, gamma },
    tagged: union(enum) {
        flag: bool,
        count: u16,
    },
};

test "deterministic replay-backed byte hash campaigns preserve streaming invariants" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const config = fuzz_runner.FuzzConfig{
        .package_name = "static_hash",
        .run_name = "byte_hash_invariants",
        .base_seed = .{ .value = 0x17b4_2026_0000_0001 },
        .build_mode = .debug,
        .case_count_max = 96,
        .reduction_budget = .{
            .max_attempts = 64,
            .max_successes = 64,
        },
    };

    var target_context = ByteHashTargetContext{};
    const ByteHashSeedReducerContext = reducer_helpers.SeedReducerContext(
        ByteHashTargetContext,
        ByteHashTargetContext.run,
    );
    var reducer_context = ByteHashSeedReducerContext{
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
            .run_fn = ByteHashTargetContext.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_hash_byte" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
        .seed_reducer = reducer_context.buildReducer(),
    };

    const summary = try runner.run();
    try expectNoFailureOrReplay(
        ByteHashTargetContext,
        io,
        tmp_dir.dir,
        summary,
        &target_context,
        ByteHashTargetContext.replay,
    );
    try std.testing.expectEqual(config.case_count_max, summary.executed_case_count);
}

test "deterministic replay-backed structural hash campaigns preserve budget and canonicalization invariants" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const config = fuzz_runner.FuzzConfig{
        .package_name = "static_hash",
        .run_name = "structural_hash_invariants",
        .base_seed = .{ .value = 0x17b4_2026_0000_0002 },
        .build_mode = .debug,
        .case_count_max = 96,
        .reduction_budget = .{
            .max_attempts = 64,
            .max_successes = 64,
        },
    };

    var target_context = StructuralHashTargetContext{};
    const StructuralSeedReducerContext = reducer_helpers.SeedReducerContext(
        StructuralHashTargetContext,
        StructuralHashTargetContext.run,
    );
    var reducer_context = StructuralSeedReducerContext{
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
            .run_fn = StructuralHashTargetContext.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_hash_structural" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
        .seed_reducer = reducer_context.buildReducer(),
    };

    const summary = try runner.run();
    try expectNoFailureOrReplay(
        StructuralHashTargetContext,
        io,
        tmp_dir.dir,
        summary,
        &target_context,
        StructuralHashTargetContext.replay,
    );
    try std.testing.expectEqual(config.case_count_max, summary.executed_case_count);
}

test "deterministic failure persistence records reduced seeds and bundle metadata" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const config = fuzz_runner.FuzzConfig{
        .package_name = "static_hash",
        .run_name = "persistence_reduction",
        .base_seed = .{ .value = 0x17b4_2026_0000_0004 },
        .build_mode = .debug,
        .case_count_max = 1,
        .reduction_budget = .{
            .max_attempts = 16,
            .max_successes = 16,
        },
    };

    const initial_case_seed = seed_mod.splitSeed(config.base_seed, 0);
    var target_context = ThresholdFailureTargetContext{
        .threshold = initial_case_seed.value >> 3,
    };
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});

    const unreduced_runner = Runner{
        .config = config,
        .target = .{
            .context = &target_context,
            .run_fn = ThresholdFailureTargetContext.run,
        },
    };
    const unreduced_summary = try unreduced_runner.run();

    try std.testing.expect(unreduced_summary.failed_case != null);

    const ThresholdSeedReducerContext = reducer_helpers.SeedReducerContext(
        ThresholdFailureTargetContext,
        ThresholdFailureTargetContext.run,
    );
    var reducer_context = ThresholdSeedReducerContext{
        .target_context = &target_context,
        .config = config,
    };

    const reduced_runner = Runner{
        .config = config,
        .target = .{
            .context = &target_context,
            .run_fn = ThresholdFailureTargetContext.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_hash_reduced_failure" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
        .seed_reducer = reducer_context.buildReducer(),
    };
    const reduced_summary = try reduced_runner.run();

    try std.testing.expect(reduced_summary.failed_case != null);
    const failed_case = reduced_summary.failed_case.?;
    try std.testing.expect(failed_case.reduced_seed != null);
    try std.testing.expect(failed_case.persisted_entry_name != null);
    try std.testing.expect(
        failed_case.run_identity.seed.value < unreduced_summary.failed_case.?.run_identity.seed.value,
    );
    try std.testing.expectEqual(
        failed_case.run_identity.seed.value,
        failed_case.reduced_seed.?.value,
    );

    var read_buffer: [512]u8 = undefined;
    const entry = try corpus.readCorpusEntry(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        &read_buffer,
    );

    const replay_outcome = try replay_runner.runReplay(error{}, read_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))], .{
        .context = &target_context,
        .run_fn = ThresholdFailureTargetContext.replay,
    }, .{
        .expected_identity_hash = entry.meta.identity_hash,
    });
    try std.testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, replay_outcome);

    var bundle_entry_name_buffer: [128]u8 = undefined;
    const bundle_name = try persistReducedFailureBundle(
        io,
        tmp_dir.dir,
        &bundle_entry_name_buffer,
        failed_case,
    );
    var manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var violations_parse_buffer: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    var stdout_buffer: [1]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    const bundle = try failure_bundle.readFailureBundle(io, tmp_dir.dir, bundle_name, .{
        .artifact_buffer = &read_buffer,
        .manifest_buffer = &manifest_buffer,
        .manifest_parse_buffer = &manifest_parse_buffer,
        .trace_buffer = &trace_buffer,
        .trace_parse_buffer = &trace_parse_buffer,
        .violations_buffer = &violations_buffer,
        .violations_parse_buffer = &violations_parse_buffer,
        .stdout_buffer = &stdout_buffer,
        .stderr_buffer = &stderr_buffer,
    });
    try std.testing.expectEqual(failed_case.run_identity.seed.value, bundle.replay_artifact_view.identity.seed.value);
    try std.testing.expectEqualStrings("static_hash_reduced_failure", bundle.manifest_document.campaign_profile.?);
    try std.testing.expect(bundle.manifest_document.base_seed != null);
}

const ByteHashTargetContext = struct {
    fn run(
        context_ptr: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const context: *const ByteHashTargetContext = @ptrCast(@alignCast(context_ptr));
        _ = context;
        const evaluation = evaluateByteHashCase(run_identity.seed);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity),
            .check_result = evaluation.toCheckResult(),
        };
    }

    fn replay(
        context_ptr: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution {
        const context: *const ByteHashTargetContext = @ptrCast(@alignCast(context_ptr));
        _ = context;
        const evaluation = evaluateByteHashCase(artifact.identity.seed);
        return .{
            .trace_metadata = makeTraceMetadata(artifact.identity),
            .check_result = evaluation.toCheckResult(),
        };
    }
};

const StructuralHashTargetContext = struct {
    fn run(
        context_ptr: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const context: *const StructuralHashTargetContext = @ptrCast(@alignCast(context_ptr));
        _ = context;
        const evaluation = evaluateStructuralCase(run_identity.seed);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity),
            .check_result = evaluation.toCheckResult(),
        };
    }

    fn replay(
        context_ptr: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution {
        const context: *const StructuralHashTargetContext = @ptrCast(@alignCast(context_ptr));
        _ = context;
        const evaluation = evaluateStructuralCase(artifact.identity.seed);
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

const threshold_failure_violation = [_]checker.Violation{
    .{
        .code = "reduced_failure",
        .message = "deterministic threshold failure for persistence coverage",
    },
};

const ThresholdFailureTargetContext = struct {
    threshold: u64,

    fn run(
        context_ptr: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const context: *const ThresholdFailureTargetContext = @ptrCast(@alignCast(context_ptr));
        const failing = run_identity.seed.value >= context.threshold;
        return .{
            .trace_metadata = makeTraceMetadata(run_identity),
            .check_result = if (failing)
                checker.CheckResult.fail(&threshold_failure_violation, checker.CheckpointDigest.init(run_identity.seed.value))
            else
                checker.CheckResult.pass(checker.CheckpointDigest.init(run_identity.seed.value)),
        };
    }

    fn replay(
        context_ptr: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution {
        const context: *const ThresholdFailureTargetContext = @ptrCast(@alignCast(context_ptr));
        const execution = try run(context, artifact.identity);
        return .{
            .trace_metadata = execution.trace_metadata,
            .check_result = execution.check_result,
        };
    }
};

fn evaluateByteHashCase(case_seed: seed_mod.Seed) Evaluation {
    var buffer: [512]u8 = undefined;
    const data = buildByteCase(case_seed.value, &buffer);
    const seed64 = mixSeed(case_seed.value, 0xa11ce5eed);
    const add_value = mixSeed(case_seed.value, 0x6a09e667f3bcc909);

    if (hash.fnv1a.hash32(0, data) != std.hash.Fnv1a_32.hash(data)) {
        return failEvaluation(&streaming_violation, hash.fnv1a.hash32(0, data));
    }
    if (hash.fnv1a.hash64(0, data) != std.hash.Fnv1a_64.hash(data)) {
        return failEvaluation(&streaming_violation, hash.fnv1a.hash64(0, data));
    }

    const wyhash_expected = hash.wyhash.hashSeeded(seed64, data);
    if (wyhash_expected != std.hash.Wyhash.hash(seed64, data)) {
        return failEvaluation(&streaming_violation, wyhash_expected);
    }

    const xxhash_expected = hash.xxhash3.hash64Seeded(seed64, data);
    if (xxhash_expected != std.hash.XxHash3.hash(seed64, data)) {
        return failEvaluation(&streaming_violation, xxhash_expected);
    }

    const crc32_expected = hash.crc32.checksum(data);
    var std_crc32 = std.hash.Crc32.init();
    std_crc32.update(data);
    if (crc32_expected != std_crc32.final()) {
        return failEvaluation(&streaming_violation, crc32_expected);
    }

    const crc32c_expected = hash.crc32.checksumCastagnoli(data);
    var std_crc32c = std.hash.crc.Crc32Iscsi.init();
    std_crc32c.update(data);
    if (crc32c_expected != std_crc32c.final()) {
        return failEvaluation(&streaming_violation, crc32c_expected);
    }

    if (hash.fingerprint.fingerprint64(data) != std.hash.Wyhash.hash(0, data)) {
        return failEvaluation(&streaming_violation, hash.fingerprint.fingerprint64(data));
    }
    if (hash.fingerprint.fingerprint64Seeded(seed64, data) != std.hash.Wyhash.hash(seed64, data)) {
        return failEvaluation(&streaming_violation, hash.fingerprint.fingerprint64Seeded(seed64, data));
    }

    const fingerprint128 = hash.fingerprint.fingerprint128(data);
    if (@as(u64, @truncate(fingerprint128)) != hash.fingerprint.fingerprint64(data)) {
        return failEvaluation(&streaming_violation, @truncate(fingerprint128));
    }

    var fingerprint_whole = hash.fingerprint.Fingerprint64V1.init();
    fingerprint_whole.update(data);
    fingerprint_whole.addU64(add_value);

    var fingerprint_chunked = hash.fingerprint.Fingerprint64V1.init();
    updateInChunks(&fingerprint_chunked, data, mixSeed(case_seed.value, 0x1007));
    fingerprint_chunked.addU64(add_value);
    if (fingerprint_whole.final() != fingerprint_chunked.final()) {
        return failEvaluation(&streaming_violation, fingerprint_whole.final());
    }

    if (hash.stable.stableFingerprint64(data) != std.hash.Fnv1a_64.hash(data)) {
        return failEvaluation(&streaming_violation, hash.stable.stableFingerprint64(data));
    }

    const siphash_key = hash.siphash.keyFromU64s(seed64, ~seed64);
    const wrapper_sip64 = hash.siphash.hash64_24(&siphash_key, data);
    const direct_sip64 = directSipHash64_24(&siphash_key, data);
    if (wrapper_sip64 != direct_sip64) {
        return failEvaluation(&streaming_violation, wrapper_sip64);
    }

    const wrapper_sip128 = hash.siphash.hash128_24(&siphash_key, data);
    const direct_sip128 = directSipHash128_24(&siphash_key, data);
    if (wrapper_sip128 != direct_sip128) {
        return failEvaluation(&streaming_violation, @truncate(wrapper_sip128));
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(makeCheckpoint(
            wyhash_expected,
            xxhash_expected,
        )),
    };
}

fn evaluateStructuralCase(case_seed: seed_mod.Seed) Evaluation {
    return switch (@as(u8, @truncate(case_seed.value % 6))) {
        0 => evaluatePaddingCase(case_seed),
        1 => evaluateSliceCase(case_seed),
        2 => evaluateFloatCase(case_seed),
        3 => evaluateBudgetEquivalenceCase(case_seed),
        4 => evaluateBudgetLimitCase(case_seed),
        else => evaluateStrictCase(case_seed),
    };
}

fn evaluatePaddingCase(case_seed: seed_mod.Seed) Evaluation {
    const tag: u8 = @truncate(case_seed.value >> 8);
    const value: u32 = @truncate(case_seed.value ^ 0xa5a5_5a5a);
    const left = makePaddedKey(0xaa, tag, value);
    const right = makePaddedKey(0x55, tag, value);

    if (!std.meta.eql(left, right)) {
        return failEvaluation(&structural_padding_violation, case_seed.value);
    }
    if (hash.hash_any.hashAnySeeded(case_seed.value, left) != hash.hash_any.hashAnySeeded(case_seed.value, right)) {
        return failEvaluation(&structural_padding_violation, case_seed.value);
    }
    if (hash.stable.stableHashAnySeeded(case_seed.value, left) != hash.stable.stableHashAnySeeded(case_seed.value, right)) {
        return failEvaluation(&structural_padding_violation, case_seed.value);
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(makeCheckpoint(
            hash.hash_any.hashAnySeeded(case_seed.value, left),
            hash.stable.stableHashAnySeeded(case_seed.value, left),
        )),
    };
}

fn evaluateSliceCase(case_seed: seed_mod.Seed) Evaluation {
    var left_storage: [64]u8 = undefined;
    var right_storage: [64]u8 = undefined;
    const len = buildStructuredBytes(case_seed.value, left_storage[0..]);
    @memcpy(right_storage[0..len], left_storage[0..len]);
    const left: SliceKey = .{
        .bytes = left_storage[0..len],
        .flag = (case_seed.value & 1) != 0,
    };
    const right: SliceKey = .{
        .bytes = right_storage[0..len],
        .flag = left.flag,
    };

    if (hash.hash_any.hashAnySeeded(case_seed.value, left) != hash.hash_any.hashAnySeeded(case_seed.value, right)) {
        return failEvaluation(&structural_slice_violation, case_seed.value);
    }
    if (hash.hash_any.hashAnySeededStrict(case_seed.value, left) != hash.hash_any.hashAnySeededStrict(case_seed.value, right)) {
        return failEvaluation(&structural_slice_strict_violation, case_seed.value);
    }
    if (hash.stable.stableHashAnySeeded(case_seed.value, left) != hash.stable.stableHashAnySeeded(case_seed.value, right)) {
        return failEvaluation(&structural_slice_stable_violation, case_seed.value);
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(makeCheckpoint(
            hash.hash_any.hashAnySeeded(case_seed.value, left),
            hash.stable.stableHashAnySeeded(case_seed.value, left),
        )),
    };
}

fn evaluateFloatCase(case_seed: seed_mod.Seed) Evaluation {
    const positive_zero: f32 = 0.0;
    const negative_zero: f32 = -0.0;
    const canonical_nan: f32 = std.math.nan(f32);
    const payload_nan: f32 = @bitCast(@as(u32, 0x7fc0_0001));

    if (hash.hash_any.hashAnySeeded(case_seed.value, positive_zero) != hash.hash_any.hashAnySeeded(case_seed.value, negative_zero)) {
        return failEvaluation(&structural_float_violation, case_seed.value);
    }
    if (hash.hash_any.hashAnySeeded(case_seed.value, canonical_nan) != hash.hash_any.hashAnySeeded(case_seed.value, payload_nan)) {
        return failEvaluation(&structural_float_violation, case_seed.value);
    }
    if (hash.stable.stableHashAnySeeded(case_seed.value, positive_zero) != hash.stable.stableHashAnySeeded(case_seed.value, negative_zero)) {
        return failEvaluation(&structural_float_violation, case_seed.value);
    }
    if (hash.stable.stableHashAnySeeded(case_seed.value, canonical_nan) != hash.stable.stableHashAnySeeded(case_seed.value, payload_nan)) {
        return failEvaluation(&structural_float_violation, case_seed.value);
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(makeCheckpoint(
            hash.hash_any.hashAnySeeded(case_seed.value, canonical_nan),
            hash.stable.stableHashAnySeeded(case_seed.value, canonical_nan),
        )),
    };
}

fn evaluateBudgetEquivalenceCase(case_seed: seed_mod.Seed) Evaluation {
    const value = makeBudgetValue(case_seed.value);

    var hash_budget = hash.budget.HashBudget.unlimited();
    const hash_any_unbounded = hash.hash_any.hashAnySeeded(case_seed.value, value);
    const hash_any_budgeted = hash.hash_any.hashAnySeededBudgeted(case_seed.value, value, &hash_budget) catch {
        return failEvaluation(&structural_budget_equivalence_violation, case_seed.value);
    };
    if (hash_any_unbounded != hash_any_budgeted) {
        return failEvaluation(&structural_budget_equivalence_violation, case_seed.value);
    }

    var stable_budget = hash.budget.HashBudget.unlimited();
    const stable_unbounded = hash.stable.stableHashAnySeeded(case_seed.value, value);
    const stable_budgeted = hash.stable.stableHashAnySeededBudgeted(case_seed.value, value, &stable_budget) catch {
        return failEvaluation(&structural_budget_equivalence_violation, case_seed.value);
    };
    if (stable_unbounded != stable_budgeted) {
        return failEvaluation(&structural_budget_equivalence_violation, case_seed.value);
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(makeCheckpoint(
            hash_any_budgeted,
            stable_budgeted,
        )),
    };
}

fn evaluateBudgetLimitCase(case_seed: seed_mod.Seed) Evaluation {
    var byte_storage: [32]u8 = undefined;
    const byte_len = buildStructuredBytes(case_seed.value ^ 0x3333, byte_storage[0..]);
    const byte_slice = byte_storage[0..@max(byte_len, 1)];

    var byte_budget_hash_any = hash.budget.HashBudget.init(.{
        .max_bytes = @as(u64, @intCast(byte_slice.len - 1)),
        .max_elems = std.math.maxInt(u64),
        .max_depth = std.math.maxInt(u16),
    });
    if (!didRejectExceededBytesHashAny(case_seed.value, byte_slice, &byte_budget_hash_any)) {
        return failEvaluation(&structural_budget_bytes_hash_any_violation, case_seed.value);
    }

    var byte_budget_stable = hash.budget.HashBudget.init(.{
        .max_bytes = @as(u64, @intCast(byte_slice.len - 1)),
        .max_elems = std.math.maxInt(u64),
        .max_depth = std.math.maxInt(u16),
    });
    if (!didRejectExceededBytesStable(case_seed.value, byte_slice, &byte_budget_stable)) {
        return failEvaluation(&structural_budget_bytes_stable_violation, case_seed.value);
    }

    const padded = [_]PaddedKey{
        makePaddedKey(0xaa, @truncate(case_seed.value), 1),
        makePaddedKey(0x55, @truncate(case_seed.value >> 8), 2),
        makePaddedKey(0x33, @truncate(case_seed.value >> 16), 3),
    };
    var elems_budget_hash_any = hash.budget.HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = 2,
        .max_depth = std.math.maxInt(u16),
    });
    if (!didRejectExceededElemsHashAny(case_seed.value, padded[0..], &elems_budget_hash_any)) {
        return failEvaluation(&structural_budget_elems_hash_any_violation, case_seed.value);
    }

    var elems_budget_stable = hash.budget.HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = 2,
        .max_depth = std.math.maxInt(u16),
    });
    if (!didRejectExceededElemsStable(case_seed.value, padded[0..], &elems_budget_stable)) {
        return failEvaluation(&structural_budget_elems_stable_violation, case_seed.value);
    }

    const nested: ?u32 = @truncate(case_seed.value);
    var depth_budget_hash_any = hash.budget.HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = std.math.maxInt(u64),
        .max_depth = 1,
    });
    if (!didRejectExceededDepthHashAny(case_seed.value, nested, &depth_budget_hash_any)) {
        return failEvaluation(&structural_budget_depth_hash_any_violation, case_seed.value);
    }

    var depth_budget_stable = hash.budget.HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = std.math.maxInt(u64),
        .max_depth = 1,
    });
    if (!didRejectExceededDepthStable(case_seed.value, nested, &depth_budget_stable)) {
        return failEvaluation(&structural_budget_depth_stable_violation, case_seed.value);
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(makeCheckpoint(
            hash.hash_any.hashAnySeeded(case_seed.value, nested),
            hash.stable.stableHashAnySeeded(case_seed.value, nested),
        )),
    };
}

fn evaluateStrictCase(case_seed: seed_mod.Seed) Evaluation {
    const value: StrictValue = .{
        .head = @truncate(case_seed.value),
        .tail = .{
            @truncate(case_seed.value >> 8),
            @truncate(case_seed.value >> 16),
            @truncate(case_seed.value >> 24),
        },
        .mode = switch (@as(u2, @truncate(case_seed.value))) {
            0 => .alpha,
            1 => .beta,
            else => .gamma,
        },
    };

    const non_strict = hash.hash_any.hashAnySeeded(case_seed.value, value);
    const strict = hash.hash_any.hashAnySeededStrict(case_seed.value, value);
    if (non_strict != strict) {
        return failEvaluation(&structural_strict_violation, case_seed.value);
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(makeCheckpoint(
            non_strict,
            hash.stable.stableHashAnySeeded(case_seed.value, value),
        )),
    };
}

fn didRejectExceededBytesHashAny(
    seed_value: u64,
    value: []const u8,
    budget: *hash.budget.HashBudget,
) bool {
    _ = hash.hash_any.hashAnySeededBudgeted(seed_value, value, budget) catch |err| {
        return err == error.ExceededBytes;
    };
    return false;
}

fn didRejectExceededBytesStable(
    seed_value: u64,
    value: []const u8,
    budget: *hash.budget.HashBudget,
) bool {
    _ = hash.stable.stableHashAnySeededBudgeted(seed_value, value, budget) catch |err| {
        return err == error.ExceededBytes;
    };
    return false;
}

fn didRejectExceededElemsHashAny(
    seed_value: u64,
    value: []const PaddedKey,
    budget: *hash.budget.HashBudget,
) bool {
    _ = hash.hash_any.hashAnySeededBudgeted(seed_value, value, budget) catch |err| {
        return err == error.ExceededElems;
    };
    return false;
}

fn didRejectExceededElemsStable(
    seed_value: u64,
    value: []const PaddedKey,
    budget: *hash.budget.HashBudget,
) bool {
    _ = hash.stable.stableHashAnySeededBudgeted(seed_value, value, budget) catch |err| {
        return err == error.ExceededElems;
    };
    return false;
}

fn didRejectExceededDepthHashAny(
    seed_value: u64,
    value: ?u32,
    budget: *hash.budget.HashBudget,
) bool {
    _ = hash.hash_any.hashAnySeededBudgeted(seed_value, value, budget) catch |err| {
        return err == error.ExceededDepth;
    };
    return false;
}

fn didRejectExceededDepthStable(
    seed_value: u64,
    value: ?u32,
    budget: *hash.budget.HashBudget,
) bool {
    _ = hash.stable.stableHashAnySeededBudgeted(seed_value, value, budget) catch |err| {
        return err == error.ExceededDepth;
    };
    return false;
}

fn expectNoFailureOrReplay(
    comptime ReplayContext: type,
    io: std.Io,
    dir: std.Io.Dir,
    summary: fuzz_runner.FuzzRunSummary,
    replay_context: *ReplayContext,
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

        if (comptime ReplayContext == StructuralHashTargetContext) {
            try persistStructuralFailureBundle(io, dir, failed_case);
        }

        std.debug.print("static_hash deterministic regression persisted at {s}\n", .{
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

fn persistStructuralFailureBundle(
    io: std.Io,
    dir: std.Io.Dir,
    failed_case: fuzz_runner.FuzzCaseResult,
) !void {
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [512]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    var detail_buffer: [256]u8 = undefined;
    const detail_text = try std.fmt.bufPrint(
        &detail_buffer,
        "seed={s} case_label={s}",
        .{
            seed_mod.formatSeed(failed_case.run_identity.seed)[0..],
            structuralCaseLabel(failed_case.run_identity.seed),
        },
    );

    _ = try failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = dir,
        .naming = .{ .prefix = "static_hash_failure", .extension = ".bundle" },
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, failed_case.run_identity, failed_case.trace_metadata, failed_case.check_result, .{
        .campaign_profile = "static_hash_structural",
        .scenario_variant_label = structuralCaseLabel(failed_case.run_identity.seed),
        .base_seed = failed_case.run_identity.seed,
        .stderr_capture = .{
            .bytes = detail_text,
            .truncated = false,
        },
    });
}

fn persistReducedFailureBundle(
    io: std.Io,
    dir: std.Io.Dir,
    entry_name_buffer: []u8,
    failed_case: fuzz_runner.FuzzCaseResult,
) ![]const u8 {
    var artifact_buffer: [512]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    var stderr_buffer: [160]u8 = undefined;
    const detail_text = try std.fmt.bufPrint(
        &stderr_buffer,
        "reduced_seed={s}",
        .{seed_mod.formatSeed(failed_case.run_identity.seed)[0..]},
    );

    const meta = try failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = dir,
        .naming = .{ .prefix = "static_hash_failure", .extension = ".bundle" },
        .entry_name_buffer = entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, failed_case.run_identity, failed_case.trace_metadata, failed_case.check_result, .{
        .campaign_profile = "static_hash_reduced_failure",
        .scenario_variant_label = "seed_reduction",
        .base_seed = failed_case.run_identity.seed,
        .stderr_capture = .{
            .bytes = detail_text,
            .truncated = false,
        },
    });
    return meta.entry_name;
}

fn structuralCaseLabel(case_seed: seed_mod.Seed) []const u8 {
    return switch (@as(u8, @truncate(case_seed.value % 6))) {
        0 => "padding",
        1 => "slice",
        2 => "float",
        3 => "budget_equivalence",
        4 => "budget_limit",
        else => "strict",
    };
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

fn buildByteCase(seed_value: u64, storage: []u8) []const u8 {
    const lengths = [_]usize{ 0, 1, 3, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 511 };
    const len = lengths[@as(usize, @intCast(seed_value % lengths.len))];
    std.debug.assert(len <= storage.len);
    const bytes = storage[0..len];

    switch (@as(u2, @truncate(seed_value >> 8))) {
        0 => @memset(bytes, 0),
        1 => for (bytes, 0..) |*byte, index| {
            byte.* = @truncate(index);
        },
        else => {
            var prng = std.Random.DefaultPrng.init(seed_value ^ 0x9e37_79b9_7f4a_7c15);
            prng.random().bytes(bytes);
        },
    }

    return bytes;
}

fn buildStructuredBytes(seed_value: u64, storage: []u8) usize {
    const len = 1 + @as(usize, @intCast(seed_value % @as(u64, @intCast(storage.len - 1))));
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x243f_6a88_85a3_08d3);
    prng.random().bytes(storage[0..len]);
    return len;
}

fn makePaddedKey(pattern: u8, tag: u8, value: u32) PaddedKey {
    var bytes: [@sizeOf(PaddedKey)]u8 = undefined;
    @memset(bytes[0..], pattern);
    bytes[@offsetOf(PaddedKey, "tag")] = tag;
    std.mem.writeInt(
        u32,
        bytes[@offsetOf(PaddedKey, "value")..][0..4],
        value,
        builtin.cpu.arch.endian(),
    );

    var key: PaddedKey = undefined;
    @memcpy(std.mem.asBytes(&key), bytes[0..]);
    return key;
}

fn makeBudgetValue(seed_value: u64) BudgetValue {
    return .{
        .header = .{
            @truncate(seed_value),
            @truncate(seed_value >> 8),
            @truncate(seed_value >> 16),
        },
        .items = .{
            makePaddedKey(0xaa, @truncate(seed_value >> 8), @truncate(seed_value)),
            makePaddedKey(0x55, @truncate(seed_value >> 16), @truncate(seed_value ^ 0x1111_1111)),
            makePaddedKey(0x33, @truncate(seed_value >> 24), @truncate(seed_value ^ 0x2222_2222)),
        },
        .maybe = if ((seed_value & 1) == 0) null else @truncate(seed_value >> 32),
        .mode = switch (@as(u2, @truncate(seed_value >> 1))) {
            0 => .alpha,
            1 => .beta,
            else => .gamma,
        },
        .tagged = if ((seed_value & 2) == 0)
            .{ .flag = (seed_value & 4) != 0 }
        else
            .{ .count = @truncate(seed_value >> 12) },
    };
}

fn updateInChunks(hasher: anytype, data: []const u8, chunk_seed: u64) void {
    var prng = std.Random.DefaultPrng.init(chunk_seed);
    const random = prng.random();
    var index: usize = 0;

    if (data.len == 0) {
        hasher.update(data);
        return;
    }

    while (index < data.len) {
        if ((random.int(u8) & 1) == 0) {
            hasher.update(data[index..index]);
        }

        const remaining = data.len - index;
        const span_cap = @min(remaining, @as(usize, 17));
        const span = 1 + random.uintAtMost(usize, span_cap - 1);
        hasher.update(data[index .. index + span]);
        index += span;
    }
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

fn mixSeed(seed_value: u64, salt: u64) u64 {
    return seed_value ^ (salt *% 0x9e37_79b9_7f4a_7c15);
}

fn directSipHash64_24(key: *const hash.siphash.Key, bytes: []const u8) u64 {
    const Direct = std.crypto.auth.siphash.SipHash64(2, 4);
    var hasher = Direct.init(key);
    hasher.update(bytes);
    var out: [8]u8 = undefined;
    hasher.final(&out);
    return std.mem.readInt(u64, &out, .little);
}

fn directSipHash128_24(key: *const hash.siphash.Key, bytes: []const u8) u128 {
    const Direct = std.crypto.auth.siphash.SipHash128(2, 4);
    var hasher = Direct.init(key);
    hasher.update(bytes);
    var out: [16]u8 = undefined;
    hasher.final(&out);
    return std.mem.readInt(u128, &out, .little);
}
