//! Demonstrates high-level replay execution over a stored replay artifact.

const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

pub fn main() !void {
    const trace_metadata: testing.testing.trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 3,
        .last_sequence_no = 3,
        .first_timestamp_ns = 77,
        .last_timestamp_ns = 77,
    };
    const run_identity = testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "replay_runner_roundtrip",
        .seed = .{ .value = 1234 },
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 0,
    });

    var artifact_storage: [256]u8 = undefined;
    const artifact_len = try testing.testing.replay_artifact.encodeReplayArtifact(
        &artifact_storage,
        run_identity,
        trace_metadata,
    );

    const outcome = try testing.testing.replay_runner.runReplay(
        error{},
        artifact_storage[0..artifact_len],
        .{
            .context = undefined,
            .run_fn = ReplayContext.run,
        },
        .{
            .expected_identity_hash = testing.testing.identity.identityHash(run_identity),
        },
    );

    assert(outcome == .matched);
}

const ReplayContext = struct {
    fn run(
        _: *const anyopaque,
        artifact: testing.testing.replay_artifact.ReplayArtifactView,
    ) error{}!testing.testing.replay_runner.ReplayExecution {
        return .{
            .trace_metadata = artifact.trace_metadata,
            .check_result = testing.testing.checker.CheckResult.pass(
                testing.testing.checker.CheckpointDigest.init(1),
            ),
        };
    }
};
