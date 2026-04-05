//! Demonstrates replay artifact encode/decode for a tiny phase-1 trace.

const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

pub fn main() !void {
    var trace_storage: [2]testing.testing.trace.TraceEvent = undefined;
    var trace_buffer = try testing.testing.trace.TraceBuffer.init(&trace_storage, .{
        .max_events = 2,
    });
    try trace_buffer.append(.{
        .timestamp_ns = 1_000,
        .category = .info,
        .label = "start",
        .value = 1,
    });
    try trace_buffer.append(.{
        .timestamp_ns = 2_000,
        .category = .decision,
        .label = "step",
        .value = 2,
    });

    const run_identity = testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "replay_roundtrip",
        .seed = .{ .value = 1234 },
        .build_mode = .debug,
    });
    const trace_metadata = trace_buffer.snapshot().metadata();

    var artifact_bytes: [256]u8 = undefined;
    const written = try testing.testing.replay_artifact.encodeReplayArtifact(
        &artifact_bytes,
        run_identity,
        trace_metadata,
    );
    const artifact_view = try testing.testing.replay_artifact.decodeReplayArtifact(
        artifact_bytes[0..written],
    );

    assert(std.mem.eql(u8, artifact_view.identity.package_name, run_identity.package_name));
    assert(std.mem.eql(u8, artifact_view.identity.run_name, run_identity.run_name));
    assert(artifact_view.trace_metadata.event_count == trace_metadata.event_count);
    assert(artifact_view.trace_metadata.last_sequence_no == trace_metadata.last_sequence_no);
}
