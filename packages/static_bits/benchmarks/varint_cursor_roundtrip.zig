//! `static_bits` cursor-based varint roundtrip baseline benchmark.

const std = @import("std");
const assert = std.debug.assert;
const static_bits = @import("static_bits");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 524_288,
    .sample_count = 16,
};

const uleb_values = [_]u64{
    0,
    1,
    127,
    128,
    624485,
    std.math.maxInt(u16),
    std.math.maxInt(u32),
    std.math.maxInt(u64),
};

const sleb_values = [_]i64{
    0,
    -1,
    1,
    -64,
    63,
    -129,
    624485,
    -624485,
    std.math.minInt(i64),
    std.math.maxInt(i64),
};

const VarintContext = struct {
    bytes: [10]u8 = [_]u8{0} ** 10,
    uleb_index: usize = 0,
    sleb_index: usize = 0,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *VarintContext = @ptrCast(@alignCast(context_ptr));

        var writer = static_bits.cursor.ByteWriter.init(&context.bytes);
        const uleb_value = uleb_values[context.uleb_index];
        static_bits.varint.writeUleb128(&writer, uleb_value) catch unreachable;
        const uleb_len = writer.position();
        var uleb_reader = static_bits.cursor.ByteReader.init(context.bytes[0..uleb_len]);
        const uleb_decoded = static_bits.varint.readUleb128(&uleb_reader) catch unreachable;

        writer = static_bits.cursor.ByteWriter.init(&context.bytes);
        const sleb_value = sleb_values[context.sleb_index];
        static_bits.varint.writeSleb128(&writer, sleb_value) catch unreachable;
        const sleb_len = writer.position();
        var sleb_reader = static_bits.cursor.ByteReader.init(context.bytes[0..sleb_len]);
        const sleb_decoded = static_bits.varint.readSleb128(&sleb_reader) catch unreachable;

        context.uleb_index = (context.uleb_index + 1) % uleb_values.len;
        context.sleb_index = (context.sleb_index + 1) % sleb_values.len;
        const sleb_bits: u64 = @bitCast(sleb_decoded);
        context.sink = bench.case.blackBox(uleb_decoded ^ sleb_bits);
        assert(uleb_reader.position() == uleb_len);
        assert(sleb_reader.position() == sleb_len);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "varint_cursor_roundtrip");
    defer output_dir.close(io);

    var context = VarintContext{};
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_bits_varint_cursor_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "uleb_and_sleb_cursor_roundtrip",
        .tags = &[_][]const u8{ "static_bits", "varint", "cursor", "baseline" },
        .context = &context,
        .run_fn = VarintContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_bits varint cursor roundtrip ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight() void {
    var bytes = [_]u8{0} ** 10;

    var writer = static_bits.cursor.ByteWriter.init(&bytes);
    static_bits.varint.writeUleb128(&writer, 624485) catch unreachable;
    var reader = static_bits.cursor.ByteReader.init(bytes[0..writer.position()]);
    const uleb_value = static_bits.varint.readUleb128(&reader) catch unreachable;
    assert(uleb_value == 624485);

    writer = static_bits.cursor.ByteWriter.init(&bytes);
    static_bits.varint.writeSleb128(&writer, -624485) catch unreachable;
    reader = static_bits.cursor.ByteReader.init(bytes[0..writer.position()]);
    const sleb_value = static_bits.varint.readSleb128(&reader) catch unreachable;
    assert(sleb_value == -624485);
}
