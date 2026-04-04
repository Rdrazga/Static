//! `static_serial` checksum-framed payload roundtrip baseline benchmark.

const std = @import("std");
const static_serial = @import("static_serial");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const payload_len: usize = 48;
const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 262_144,
    .sample_count = 16,
};

const FrameContext = struct {
    payload: [payload_len]u8 = undefined,
    frame: [support_buffer_len]u8 = [_]u8{0} ** support_buffer_len,
    sink: u64 = 0,

    fn init() FrameContext {
        var context = FrameContext{};
        fillPayload(context.payload[0..], 0x5173_6265_6e63_6801);
        return context;
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *FrameContext = @ptrCast(@alignCast(context_ptr));

        var writer = static_serial.writer.Writer.init(&context.frame);
        writer.writeVarint(@as(u16, payload_len)) catch unreachable;
        writer.writeBytes(context.payload[0..]) catch unreachable;
        static_serial.checksum.writeChecksum32(&writer, context.payload[0..]) catch unreachable;

        const frame_len = writer.position();
        var reader = static_serial.reader.Reader.init(context.frame[0..frame_len]);
        const decoded_len = reader.readVarint(u16) catch unreachable;
        const payload = reader.readBytes(decoded_len) catch unreachable;
        const stored_checksum = reader.readInt(u32, .little) catch unreachable;
        static_serial.checksum.verifyChecksum32(payload, stored_checksum) catch unreachable;

        if (!std.mem.eql(u8, payload, context.payload[0..])) unreachable;
        if (reader.position() != frame_len) unreachable;

        context.payload[0] +%= 1;
        context.sink = bench.case.blackBox(@as(u64, stored_checksum) ^ decoded_len);
        std.debug.assert(context.sink != 0);
    }
};

const support_buffer_len: usize = payload_len + 8;

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "checksum_framed_payload_roundtrip");
    defer output_dir.close(io);

    var context = FrameContext.init();
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_serial_checksum_framed_payload_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "write_then_read_checksum_frame",
        .tags = &[_][]const u8{ "static_serial", "frame", "checksum", "roundtrip" },
        .context = &context,
        .run_fn = FrameContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_serial checksum framed payload roundtrip ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        "len=48 length-prefixed payload plus checksum write/read/verify roundtrip",
    );
}

fn validateSemanticPreflight() void {
    var context = FrameContext.init();
    FrameContext.run(&context);
}

fn fillPayload(buffer: []u8, seed_value: u64) void {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x5173_6265_6e63_6802);
    const random = prng.random();
    random.bytes(buffer);
    for (buffer, 0..) |*byte, index| {
        byte.* ^= @truncate(index *% 0x17);
    }
}
