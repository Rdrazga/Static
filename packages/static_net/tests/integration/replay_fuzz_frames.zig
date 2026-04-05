const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const corpus = static_testing.testing.corpus;
const failure_bundle = static_testing.testing.failure_bundle;
const fuzz_runner = static_testing.testing.fuzz_runner;
const identity = static_testing.testing.identity;
const replay_artifact = static_testing.testing.replay_artifact;
const replay_runner = static_testing.testing.replay_runner;
const support = @import("frame_support.zig");

const invariant_case_count: u32 = 192;

const frame_violation = [_]checker.Violation{
    .{
        .code = "static_net.frame_runtime",
        .message = "static_net frame decoding diverged from the bounded reference parser",
    },
};

const retained_checksum_violation = [_]checker.Violation{
    .{
        .code = "static_net.retained_checksum_mismatch",
        .message = "retained checksum-mismatch frame reproducer",
    },
};

const retained_truncated_violation = [_]checker.Violation{
    .{
        .code = "static_net.retained_truncated_frame",
        .message = "retained truncated frame reproducer",
    },
};

const retained_noncanonical_violation = [_]checker.Violation{
    .{
        .code = "static_net.retained_noncanonical_length",
        .message = "retained non-canonical frame-length reproducer",
    },
};

const RetainedTargetError = error{
    UnexpectedRetainedOutcome,
};

test "static_net malformed frame invariants stay replayable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var artifact_buffer: [768]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const summary = try (Runner{
        .config = .{
            .package_name = "static_net",
            .run_name = "frame_runtime_invariants",
            .base_seed = .init(0x6e47_2026_0320_0001),
            .build_mode = .debug,
            .case_count_max = invariant_case_count,
        },
        .target = .{
            .context = undefined,
            .run_fn = InvariantTarget.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_net_frames" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }).run();

    try expectNoFailureOrReplay(io, tmp_dir.dir, summary);
    try testing.expectEqual(invariant_case_count, summary.executed_case_count);
}

test "static_net retained malformed frame bundles preserve replay metadata" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var artifact_buffer: [768]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(RetainedTargetError, error{});
    const summary = try (Runner{
        .config = .{
            .package_name = "static_net",
            .run_name = "retained_malformed_frame",
            .base_seed = .init(0x6e47_2026_0320_0002),
            .build_mode = .debug,
            .case_count_max = 8,
        },
        .target = .{
            .context = undefined,
            .run_fn = RetainedMalformedTarget.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_net_retained" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }).run();

    try testing.expectEqual(@as(u32, 1), summary.executed_case_count);
    try testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try testing.expect(failed_case.persisted_entry_name != null);

    const retained_case = support.buildRetainedMalformedCase(
        failed_case.run_identity.seed.value,
        &retained_checksum_violation,
        &retained_truncated_violation,
        &retained_noncanonical_violation,
    );
    try testing.expect(support.retainedMalformedCaseMatches(retained_case));

    var corpus_buffer: [768]u8 = undefined;
    const entry = try corpus.readCorpusEntry(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        &corpus_buffer,
    );
    try testing.expectEqual(
        failed_case.run_identity.seed.value,
        entry.artifact.identity.seed.value,
    );

    const replay_outcome = try replay_runner.runReplay(
        RetainedTargetError,
        corpus_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))],
        .{
            .context = undefined,
            .run_fn = RetainedMalformedTarget.replay,
        },
        .{
            .expected_identity_hash = entry.meta.identity_hash,
        },
    );
    try testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, replay_outcome);

    var bundle_entry_name_buffer: [128]u8 = undefined;
    var bundle_artifact_buffer: [768]u8 = undefined;
    var bundle_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var bundle_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var bundle_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    const bundle_meta = try failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "static_net_bundle" },
        .entry_name_buffer = &bundle_entry_name_buffer,
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &bundle_manifest_buffer,
        .trace_buffer = &bundle_trace_buffer,
        .violations_buffer = &bundle_violations_buffer,
    }, failed_case.run_identity, failed_case.trace_metadata, failed_case.check_result, .{
        .campaign_profile = "frame_runtime",
        .scenario_variant_label = retained_case.label,
    });

    var read_manifest_source: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_source: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const bundle = try failure_bundle.readFailureBundle(io, tmp_dir.dir, bundle_meta.entry_name, .{
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try testing.expectEqualStrings("static_net", bundle.manifest_document.package_name);
    try testing.expectEqualStrings("retained_malformed_frame", bundle.manifest_document.run_name);
    try testing.expectEqualStrings(retained_case.label, bundle.manifest_document.scenario_variant_label.?);
    try testing.expectEqual(
        failed_case.run_identity.seed.value,
        bundle.replay_artifact_view.identity.seed.value,
    );
    try testing.expect(bundle.trace_document != null);
    try testing.expectEqualStrings(
        failed_case.check_result.violations[0].code,
        bundle.violations_document.violations[0].code,
    );
}

const InvariantTarget = struct {
    fn run(
        _: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const evaluation = evaluateInvariantCase(run_identity.seed.value);
        return .{
            .trace_metadata = support.makeTraceMetadata(
                run_identity,
                1,
                evaluation.checkpoint_digest.value,
            ),
            .check_result = evaluation.toCheckResult(),
        };
    }

    fn replay(
        _: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution {
        const evaluation = evaluateInvariantCase(artifact.identity.seed.value);
        return .{
            .trace_metadata = support.makeTraceMetadata(
                artifact.identity,
                1,
                evaluation.checkpoint_digest.value,
            ),
            .check_result = evaluation.toCheckResult(),
        };
    }
};

const RetainedMalformedTarget = struct {
    fn run(
        _: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) RetainedTargetError!fuzz_runner.FuzzExecution {
        const retained_case = support.buildRetainedMalformedCase(
            run_identity.seed.value,
            &retained_checksum_violation,
            &retained_truncated_violation,
            &retained_noncanonical_violation,
        );
        if (!support.retainedMalformedCaseMatches(retained_case)) {
            return error.UnexpectedRetainedOutcome;
        }
        return .{
            .trace_metadata = support.makeTraceMetadata(
                run_identity,
                1,
                retained_case.digest,
            ),
            .check_result = checker.CheckResult.fail(
                retained_case.violations,
                checker.CheckpointDigest.init(retained_case.digest),
            ),
        };
    }

    fn replay(
        _: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) RetainedTargetError!replay_runner.ReplayExecution {
        const retained_case = support.buildRetainedMalformedCase(
            artifact.identity.seed.value,
            &retained_checksum_violation,
            &retained_truncated_violation,
            &retained_noncanonical_violation,
        );
        if (!support.retainedMalformedCaseMatches(retained_case)) {
            return error.UnexpectedRetainedOutcome;
        }
        return .{
            .trace_metadata = support.makeTraceMetadata(
                artifact.identity,
                1,
                retained_case.digest,
            ),
            .check_result = checker.CheckResult.fail(
                retained_case.violations,
                checker.CheckpointDigest.init(retained_case.digest),
            ),
        };
    }
};

const Evaluation = struct {
    checkpoint_digest: checker.CheckpointDigest,
    violations: ?[]const checker.Violation,

    fn toCheckResult(self: Evaluation) checker.CheckResult {
        if (self.violations) |violations| {
            return checker.CheckResult.fail(violations, self.checkpoint_digest);
        }
        return checker.CheckResult.pass(self.checkpoint_digest);
    }
};

fn expectNoFailureOrReplay(
    io: std.Io,
    dir: std.Io.Dir,
    summary: fuzz_runner.FuzzRunSummary,
) !void {
    if (summary.failed_case) |failed_case| {
        try testing.expect(failed_case.persisted_entry_name != null);

        var read_buffer: [768]u8 = undefined;
        const entry = try corpus.readCorpusEntry(
            io,
            dir,
            failed_case.persisted_entry_name.?,
            &read_buffer,
        );
        const outcome = try replay_runner.runReplay(
            error{},
            read_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))],
            .{
                .context = undefined,
                .run_fn = InvariantTarget.replay,
            },
            .{
                .expected_identity_hash = entry.meta.identity_hash,
            },
        );
        try testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, outcome);
        return error.TestUnexpectedResult;
    }
}

fn evaluateInvariantCase(seed_value: u64) Evaluation {
    const generated = support.buildGeneratedFrameCase(seed_value);
    const check = support.evaluateGeneratedCase(generated, &frame_violation);
    return .{
        .checkpoint_digest = checker.CheckpointDigest.init(check.digest),
        .violations = check.violations,
    };
}
