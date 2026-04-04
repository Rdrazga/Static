//! Benchmarks replay-artifact encode and decode throughput.
//!
//! Run with:
//! - `zig build bench -Doptimize=ReleaseFast` (from `packages/static_testing`).

const std = @import("std");
const static_testing = @import("static_testing");

const bench = static_testing.bench;
const testing = static_testing.testing;

const artifact_buffer_len: usize = 256;

const EncodeContext = struct {
    run_identity: testing.identity.RunIdentity,
    trace_metadata: testing.trace.TraceMetadata,
    artifact_buffer: []u8,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        const written = testing.replay_artifact.encodeReplayArtifact(
            context.artifact_buffer,
            context.run_identity,
            context.trace_metadata,
        ) catch |err| {
            std.debug.panic("encodeReplayArtifact failed: {s}", .{@errorName(err)});
        };

        context.sink +%= written;
        context.sink +%= context.artifact_buffer[0];
        _ = bench.case.blackBox(context.sink);
    }
};

const DecodeContext = struct {
    artifact_bytes: []const u8,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        const artifact = testing.replay_artifact.decodeReplayArtifact(context.artifact_bytes) catch |err| {
            std.debug.panic("decodeReplayArtifact failed: {s}", .{@errorName(err)});
        };

        context.sink +%= artifact.trace_metadata.event_count;
        context.sink +%= artifact.trace_metadata.last_timestamp_ns;
        _ = bench.case.blackBox(context.sink);
    }
};

fn makeRunIdentity() testing.identity.RunIdentity {
    return testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "bench_replay_artifact",
        .seed = .{ .value = 2026 },
        .build_mode = .release_fast,
        .case_index = 3,
        .run_index = 9,
    });
}

fn makeTraceMetadata() testing.trace.TraceMetadata {
    return .{
        .event_count = 3,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 10,
        .last_sequence_no = 12,
        .first_timestamp_ns = 1_000,
        .last_timestamp_ns = 1_250,
    };
}

fn verifyReplayArtifactBenchmarkInputs(
    run_identity: testing.identity.RunIdentity,
    trace_metadata: testing.trace.TraceMetadata,
    artifact_buffer: []u8,
) ![]const u8 {
    const encoded_len = try testing.replay_artifact.encodeReplayArtifact(
        artifact_buffer,
        run_identity,
        trace_metadata,
    );
    const decoded = try testing.replay_artifact.decodeReplayArtifact(artifact_buffer[0..encoded_len]);

    std.debug.assert(std.mem.eql(u8, decoded.identity.package_name, run_identity.package_name));
    std.debug.assert(std.mem.eql(u8, decoded.identity.run_name, run_identity.run_name));
    std.debug.assert(decoded.identity.seed.value == run_identity.seed.value);
    std.debug.assert(decoded.trace_metadata.event_count == trace_metadata.event_count);
    std.debug.assert(decoded.trace_metadata.first_sequence_no == trace_metadata.first_sequence_no);
    std.debug.assert(decoded.trace_metadata.last_timestamp_ns == trace_metadata.last_timestamp_ns);
    return artifact_buffer[0..encoded_len];
}

fn runBenchmarkGroup(
    group: *const bench.group.BenchmarkGroup,
    sample_storage: []bench.runner.BenchmarkSample,
    case_result_storage: []bench.runner.BenchmarkCaseResult,
) !void {
    const run_result = try bench.runner.runGroup(group, sample_storage, case_result_storage);

    std.debug.print("mode: {s}\n", .{@tagName(run_result.mode)});
    for (run_result.case_results) |case_result| {
        const derived = try bench.stats.computeStats(case_result);
        std.debug.print(
            "case {s} samples={d} median_elapsed_ns={d} mean_elapsed_ns={d}\n",
            .{
                derived.case_name,
                derived.sample_count,
                derived.median_elapsed_ns,
                derived.mean_elapsed_ns,
            },
        );
    }
}

pub fn main() !void {
    const run_identity = makeRunIdentity();
    const trace_metadata = makeTraceMetadata();

    var encode_artifact_buffer: [artifact_buffer_len]u8 = undefined;
    const decode_bytes = try verifyReplayArtifactBenchmarkInputs(
        run_identity,
        trace_metadata,
        &encode_artifact_buffer,
    );

    var encode_context = EncodeContext{
        .run_identity = run_identity,
        .trace_metadata = trace_metadata,
        .artifact_buffer = &encode_artifact_buffer,
    };
    var decode_context = DecodeContext{
        .artifact_bytes = decode_bytes,
    };

    var case_storage: [2]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "bench_replay_artifact",
        .config = .{
            .mode = .full,
            .warmup_iterations = 1,
            .measure_iterations = 64,
            .sample_count = 5,
        },
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "replay_artifact.encode",
        .context = &encode_context,
        .run_fn = EncodeContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "replay_artifact.decode",
        .context = &decode_context,
        .run_fn = DecodeContext.run,
    }));

    var bench_samples: [10]bench.runner.BenchmarkSample = undefined;
    var case_results: [2]bench.runner.BenchmarkCaseResult = undefined;
    try runBenchmarkGroup(&group, &bench_samples, &case_results);

    _ = bench.case.blackBox(encode_context.sink);
    _ = bench.case.blackBox(decode_context.sink);
}
