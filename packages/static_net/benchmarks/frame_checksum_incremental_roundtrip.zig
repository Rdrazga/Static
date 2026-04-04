//! `static_net` checksum-enabled incremental roundtrip baseline benchmark.

const std = @import("std");
const static_net = @import("static_net");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const payload_len: usize = 32;
const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 262_144,
    .sample_count = 16,
};

const IncrementalContext = struct {
    cfg: static_net.FrameConfig,
    payload: [payload_len]u8 = undefined,
    encoded: [128]u8 = [_]u8{0} ** 128,
    sink: u64 = 0,

    fn init() !IncrementalContext {
        var context = IncrementalContext{
            .cfg = try (static_net.FrameConfig{
                .max_payload_bytes = 64,
                .checksum_mode = .enabled,
            }).init(),
        };
        fillPayload(context.payload[0..], 0x6e47_6265_6e63_6801);
        return context;
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *IncrementalContext = @ptrCast(@alignCast(context_ptr));

        const written = static_net.frame_encode.encodeInto(
            context.cfg,
            &context.encoded,
            context.payload[0..],
        ) catch unreachable;

        var decoder = static_net.Decoder.init(context.cfg) catch unreachable;
        var payload_out: [64]u8 = [_]u8{0} ** 64;
        const split = 3;
        const first = decoder.decode(context.encoded[0..split], &payload_out);
        if (first.status != .need_more_input) unreachable;
        const second = decoder.decode(context.encoded[split..written], &payload_out);
        if (second.status != .frame) unreachable;
        if (second.status.frame.payload_len != payload_len) unreachable;
        if (!std.mem.eql(u8, payload_out[0..payload_len], context.payload[0..])) unreachable;

        context.payload[0] +%= 1;
        context.sink = bench.case.blackBox(@as(u64, second.status.frame.payload_len) ^ written);
        std.debug.assert(context.sink != 0);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "frame_checksum_incremental_roundtrip");
    defer output_dir.close(io);

    var context = try IncrementalContext.init();
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_net_frame_checksum_incremental_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "checksum_incremental_roundtrip",
        .tags = &[_][]const u8{ "static_net", "frame", "checksum", "incremental" },
        .context = &context,
        .run_fn = IncrementalContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_net checksum incremental roundtrip ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        "checksum-enabled two-chunk incremental decode roundtrip",
    );
}

fn validateSemanticPreflight() void {
    var context = IncrementalContext.init() catch unreachable;
    IncrementalContext.run(&context);
}

fn fillPayload(buffer: []u8, seed_value: u64) void {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x6e47_6265_6e63_6802);
    const random = prng.random();
    random.bytes(buffer);
    for (buffer, 0..) |*byte, index| {
        byte.* ^= @truncate(index *% 0x35);
    }
}
