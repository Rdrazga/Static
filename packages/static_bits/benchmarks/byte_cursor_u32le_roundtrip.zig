//! `static_bits` byte-cursor little-endian roundtrip baseline benchmark.

const std = @import("std");
const static_bits = @import("static_bits");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 64,
    .measure_iterations = 1_048_576,
    .sample_count = 16,
};

const CursorContext = struct {
    bytes: [4]u8 = [_]u8{0} ** 4,
    value: u32 = 0x1020_3040,
    sink: u32 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *CursorContext = @ptrCast(@alignCast(context_ptr));

        var writer = static_bits.cursor.ByteWriter.init(&context.bytes);
        writer.writeU32Le(context.value) catch unreachable;

        var reader = static_bits.cursor.ByteReader.init(&context.bytes);
        const decoded = reader.readU32Le() catch unreachable;

        context.value +%= 0x9E37_79B9;
        context.sink = bench.case.blackBox(decoded);
        std.debug.assert(context.sink == decoded);
        std.debug.assert(reader.position() == context.bytes.len);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "byte_cursor_u32le_roundtrip");
    defer output_dir.close(io);

    var context = CursorContext{};
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_bits_byte_cursor_u32le_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "write_then_read_u32le",
        .tags = &[_][]const u8{ "static_bits", "cursor", "endian", "baseline" },
        .context = &context,
        .run_fn = CursorContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_bits byte cursor u32le roundtrip ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight() void {
    var bytes = [_]u8{0} ** 4;
    var writer = static_bits.cursor.ByteWriter.init(&bytes);
    writer.writeU32Le(0x4433_2211) catch unreachable;
    std.debug.assert(std.mem.eql(u8, &bytes, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }));

    var reader = static_bits.cursor.ByteReader.init(&bytes);
    const decoded = reader.readU32Le() catch unreachable;
    std.debug.assert(decoded == 0x4433_2211);
    std.debug.assert(reader.position() == bytes.len);
}
