//! Replay execution helpers over a caller-provided target callback.
//!
//! Phase 2 keeps replay simple and bounded:
//! - decode a replay artifact;
//! - optionally validate its identity hash against the caller's expectation;
//! - execute a deterministic replay target; and
//! - compare the observed trace metadata with the stored artifact metadata.
//!
//! Current scope intentionally excludes checkpoint-digest matching because
//! replay artifacts do not yet persist a checkpoint digest. The replay target
//! may still return one for caller diagnostics, but `runReplay()` does not use
//! it for classification in this phase.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const checker = @import("checker.zig");
const identity = @import("identity.zig");
const replay_artifact = @import("replay_artifact.zig");
const trace = @import("trace.zig");

/// Operating errors surfaced by `runReplay`.
pub const ReplayRunError = error{
    InvalidInput,
};

/// The replay result classification after decoding and executing an artifact.
pub const ReplayOutcome = enum(u8) {
    matched = 1,
    violation_reproduced = 2,
    trace_mismatch = 3,
};

/// The replay target's deterministic execution result.
pub const ReplayExecution = struct {
    trace_metadata: trace.TraceMetadata,
    check_result: checker.CheckResult,
};

/// Optional replay validation knobs.
pub const ReplayOptions = struct {
    expected_identity_hash: ?u64 = null,
};

/// Replay target callback contract.
pub fn ReplayTarget(comptime ReplayError: type) type {
    return struct {
        context: *const anyopaque,
        run_fn: *const fn (
            context: *const anyopaque,
            artifact: replay_artifact.ReplayArtifactView,
        ) ReplayError!ReplayExecution,

        pub fn run(
            self: @This(),
            artifact: replay_artifact.ReplayArtifactView,
        ) ReplayError!ReplayExecution {
            return self.run_fn(self.context, artifact);
        }
    };
}

comptime {
    core.errors.assertVocabularySubset(ReplayRunError);
    assert(std.meta.fields(ReplayOutcome).len == 3);
}

/// Decode and replay an artifact against a caller-provided target.
///
/// Returns:
/// - `.matched` when the replayed trace metadata matches and the checker passes;
/// - `.violation_reproduced` when the trace metadata matches and the checker fails; and
/// - `.trace_mismatch` when the replay target did not reproduce the stored trace metadata.
///
/// `check_result.checkpoint_digest` is currently observational only because the
/// artifact format persists trace metadata but not checkpoint digests.
pub fn runReplay(
    comptime ReplayError: type,
    artifact_bytes: []const u8,
    target: ReplayTarget(ReplayError),
    options: ReplayOptions,
) (ReplayRunError || replay_artifact.ReplayArtifactError || ReplayError)!ReplayOutcome {
    const artifact = try replay_artifact.decodeReplayArtifact(artifact_bytes);
    try validateIdentityExpectation(artifact.identity, options);

    const execution = try target.run(artifact);
    assertCheckResult(execution.check_result);

    if (!traceMetadataEql(artifact.trace_metadata, execution.trace_metadata)) {
        return .trace_mismatch;
    }
    if (!execution.check_result.passed) {
        return .violation_reproduced;
    }
    return .matched;
}

fn validateIdentityExpectation(
    run_identity: identity.RunIdentity,
    options: ReplayOptions,
) ReplayRunError!void {
    if (options.expected_identity_hash) |expected_identity_hash| {
        if (identity.identityHash(run_identity) != expected_identity_hash) {
            return error.InvalidInput;
        }
    }
}

fn assertCheckResult(result: checker.CheckResult) void {
    if (result.passed) {
        assert(result.violations.len == 0);
    } else {
        assert(result.violations.len > 0);
    }
}

fn traceMetadataEql(a: trace.TraceMetadata, b: trace.TraceMetadata) bool {
    return a.event_count == b.event_count and
        a.truncated == b.truncated and
        a.has_range == b.has_range and
        a.first_sequence_no == b.first_sequence_no and
        a.last_sequence_no == b.last_sequence_no and
        a.first_timestamp_ns == b.first_timestamp_ns and
        a.last_timestamp_ns == b.last_timestamp_ns;
}

fn makeReplayArtifact(
    storage: []u8,
    run_name: []const u8,
    trace_metadata: trace.TraceMetadata,
) replay_artifact.ReplayArtifactError![]const u8 {
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = run_name,
        .seed = .{ .value = 1234 },
        .build_mode = .debug,
        .case_index = 2,
        .run_index = 9,
    });

    const written = try replay_artifact.encodeReplayArtifact(storage, run_identity, trace_metadata);
    return storage[0..written];
}

test "runReplay returns matched when replay reproduces the trace and passes" {
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 2,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 4,
        .last_sequence_no = 5,
        .first_timestamp_ns = 10,
        .last_timestamp_ns = 20,
    };
    var artifact_storage: [128]u8 = undefined;
    const artifact_bytes = try makeReplayArtifact(&artifact_storage, "replay_match", trace_metadata);
    const artifact = try replay_artifact.decodeReplayArtifact(artifact_bytes);

    const Context = struct {
        fn run(
            _: *const anyopaque,
            replay_view: replay_artifact.ReplayArtifactView,
        ) error{}!ReplayExecution {
            return .{
                .trace_metadata = replay_view.trace_metadata,
                .check_result = checker.CheckResult.pass(checker.CheckpointDigest.init(1)),
            };
        }
    };

    const outcome = try runReplay(error{}, artifact_bytes, .{
        .context = undefined,
        .run_fn = Context.run,
    }, .{
        .expected_identity_hash = identity.identityHash(artifact.identity),
    });

    try testing.expectEqual(ReplayOutcome.matched, outcome);
}

test "runReplay returns violation_reproduced when replayed trace matches and checker fails" {
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 7,
        .last_sequence_no = 7,
        .first_timestamp_ns = 99,
        .last_timestamp_ns = 99,
    };
    const violations = [_]checker.Violation{
        .{ .code = "expected_failure", .message = "failure reproduced" },
    };
    var artifact_storage: [128]u8 = undefined;
    const artifact_bytes = try makeReplayArtifact(&artifact_storage, "replay_fail", trace_metadata);

    const Context = struct {
        fn run(
            _: *const anyopaque,
            replay_view: replay_artifact.ReplayArtifactView,
        ) error{}!ReplayExecution {
            return .{
                .trace_metadata = replay_view.trace_metadata,
                .check_result = checker.CheckResult.fail(&violations, null),
            };
        }
    };

    const outcome = try runReplay(error{}, artifact_bytes, .{
        .context = undefined,
        .run_fn = Context.run,
    }, .{});

    try testing.expectEqual(ReplayOutcome.violation_reproduced, outcome);
}

test "runReplay rejects identity hash mismatches" {
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 0,
        .truncated = false,
        .has_range = false,
        .first_sequence_no = 0,
        .last_sequence_no = 0,
        .first_timestamp_ns = 0,
        .last_timestamp_ns = 0,
    };
    var artifact_storage: [128]u8 = undefined;
    const artifact_bytes = try makeReplayArtifact(&artifact_storage, "identity_mismatch", trace_metadata);

    const Context = struct {
        fn run(
            _: *const anyopaque,
            replay_view: replay_artifact.ReplayArtifactView,
        ) error{}!ReplayExecution {
            return .{
                .trace_metadata = replay_view.trace_metadata,
                .check_result = checker.CheckResult.pass(null),
            };
        }
    };

    try testing.expectError(
        error.InvalidInput,
        runReplay(error{}, artifact_bytes, .{
            .context = undefined,
            .run_fn = Context.run,
        }, .{
            .expected_identity_hash = 1,
        }),
    );
}

test "runReplay returns trace_mismatch when deterministic replay diverges" {
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 3,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 8,
        .last_sequence_no = 10,
        .first_timestamp_ns = 11,
        .last_timestamp_ns = 15,
    };
    var artifact_storage: [128]u8 = undefined;
    const artifact_bytes = try makeReplayArtifact(&artifact_storage, "trace_mismatch", trace_metadata);

    const Context = struct {
        fn run(
            _: *const anyopaque,
            replay_view: replay_artifact.ReplayArtifactView,
        ) error{}!ReplayExecution {
            var observed = replay_view.trace_metadata;
            observed.last_timestamp_ns += 1;
            return .{
                .trace_metadata = observed,
                .check_result = checker.CheckResult.pass(null),
            };
        }
    };

    const outcome = try runReplay(error{}, artifact_bytes, .{
        .context = undefined,
        .run_fn = Context.run,
    }, .{});

    try testing.expectEqual(ReplayOutcome.trace_mismatch, outcome);
}

test "runReplay ignores checkpoint digest mismatches in the current artifact phase" {
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 3,
        .last_sequence_no = 3,
        .first_timestamp_ns = 77,
        .last_timestamp_ns = 77,
    };
    var artifact_storage: [128]u8 = undefined;
    const artifact_bytes = try makeReplayArtifact(&artifact_storage, "checkpoint_observational", trace_metadata);

    const Context = struct {
        fn run(
            _: *const anyopaque,
            replay_view: replay_artifact.ReplayArtifactView,
        ) error{}!ReplayExecution {
            return .{
                .trace_metadata = replay_view.trace_metadata,
                .check_result = checker.CheckResult.pass(checker.CheckpointDigest.init(999)),
            };
        }
    };

    const outcome = try runReplay(error{}, artifact_bytes, .{
        .context = undefined,
        .run_fn = Context.run,
    }, .{});

    try testing.expectEqual(ReplayOutcome.matched, outcome);
}
