//! `static_net` frame encode/decode roundtrip baseline benchmark.

const std = @import("std");
const assert = std.debug.assert;
const static_net = @import("static_net");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const payload_len: usize = 64;
const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 1_048_576,
    .sample_count = 16,
};

const ThroughputContext = struct {
    cfg: static_net.FrameConfig,
    encoder_out: [512]u8 = [_]u8{0} ** 512,
    decoded: [256]u8 = [_]u8{0} ** 256,
    payload: [payload_len]u8 = undefined,
    sink: u64 = 0,

    fn init() !ThroughputContext {
        var context = ThroughputContext{
            .cfg = try (static_net.FrameConfig{
                .max_payload_bytes = 256,
            }).init(),
        };
        for (&context.payload, 0..) |*byte, index| {
            byte.* = @intCast(index);
        }
        return context;
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *ThroughputContext = @ptrCast(@alignCast(context_ptr));
        const written = static_net.frame_encode.encodeInto(
            context.cfg,
            &context.encoder_out,
            &context.payload,
        ) catch unreachable;

        var decoder = static_net.Decoder.init(context.cfg) catch unreachable;
        const step = decoder.decode(context.encoder_out[0..written], &context.decoded);
        if (step.status != .frame) unreachable;
        if (step.status.frame.payload_len != payload_len) unreachable;
        if (!std.mem.eql(u8, context.decoded[0..payload_len], &context.payload)) unreachable;

        context.payload[0] +%= 1;
        context.sink = bench.case.blackBox(@as(u64, step.status.frame.payload_len) ^ written);
        assert(context.sink != 0);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "frame_encode_decode_throughput");
    defer output_dir.close(io);

    var context = try ThroughputContext.init();
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_net_frame_encode_decode_throughput",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "encode_then_decode_full_frame",
        .tags = &[_][]const u8{ "static_net", "frame", "encode", "decode" },
        .context = &context,
        .run_fn = ThroughputContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_net frame encode/decode roundtrip ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        "checksum-disabled full-frame encode/decode roundtrip",
    );
}

fn validateSemanticPreflight() void {
    var context = ThroughputContext.init() catch unreachable;
    ThroughputContext.run(&context);
}
