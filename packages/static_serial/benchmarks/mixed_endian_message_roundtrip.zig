//! `static_serial` mixed-endian message roundtrip baseline benchmark.

const std = @import("std");
const static_serial = @import("static_serial");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const payload_len: usize = 12;
const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 64,
    .measure_iterations = 1_048_576,
    .sample_count = 16,
};

const MessageContext = struct {
    kind: u16 = 0xcafe,
    sequence_id: u32 = 0x0102_0304,
    signed_delta: i32 = -42,
    payload: [payload_len]u8 = undefined,
    frame: [64]u8 = [_]u8{0} ** 64,
    sink: u64 = 0,

    fn init() MessageContext {
        var context = MessageContext{};
        fillPayload(context.payload[0..], 0x5173_6265_6e63_6803);
        return context;
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *MessageContext = @ptrCast(@alignCast(context_ptr));

        var writer = static_serial.writer.Writer.init(&context.frame);
        writer.writeInt(context.kind, .big) catch unreachable;
        writer.writeVarint(@as(u16, payload_len)) catch unreachable;
        writer.writeInt(context.sequence_id, .little) catch unreachable;
        writer.writeZigZag(context.signed_delta) catch unreachable;
        writer.writeBytes(context.payload[0..]) catch unreachable;

        const frame_len = writer.position();
        var reader = static_serial.reader.Reader.init(context.frame[0..frame_len]);
        const decoded_kind = reader.readInt(u16, .big) catch unreachable;
        const decoded_len = reader.readVarint(u16) catch unreachable;
        const decoded_sequence = reader.readInt(u32, .little) catch unreachable;
        const decoded_delta = reader.readZigZag(i32) catch unreachable;
        const decoded_payload = reader.readBytes(decoded_len) catch unreachable;

        if (decoded_kind != context.kind) unreachable;
        if (decoded_sequence != context.sequence_id) unreachable;
        if (decoded_delta != context.signed_delta) unreachable;
        if (!std.mem.eql(u8, decoded_payload, context.payload[0..])) unreachable;
        if (reader.position() != frame_len) unreachable;

        const delta_bits: u32 = @bitCast(decoded_delta);
        context.sequence_id +%= 1;
        context.signed_delta -%= 1;
        context.payload[0] +%= 3;
        context.sink = bench.case.blackBox(
            @as(u64, decoded_kind) ^
                decoded_sequence ^
                delta_bits,
        );
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
    var output_dir = try support.openOutputDir(io, "mixed_endian_message_roundtrip");
    defer output_dir.close(io);

    var context = MessageContext.init();
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_serial_mixed_endian_message_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "write_then_read_structured_message",
        .tags = &[_][]const u8{ "static_serial", "message", "endian", "varint" },
        .context = &context,
        .run_fn = MessageContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_serial mixed-endian message roundtrip ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight() void {
    var context = MessageContext.init();
    MessageContext.run(&context);
}

fn fillPayload(buffer: []u8, seed_value: u64) void {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x5173_6265_6e63_6804);
    const random = prng.random();
    random.bytes(buffer);
    for (buffer, 0..) |*byte, index| {
        byte.* ^= @truncate(index *% 0x29);
    }
}
