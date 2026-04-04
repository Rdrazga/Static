//! `static_string` text validation and normalization baselines.

const std = @import("std");
const static_string = @import("static_string");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 1_048_576,
    .sample_count = 16,
};

const ascii_source = " \tX-Request-Id\r\n";
const utf8_source = "caf\xc3\xa9-na\xc3\xafve-\xf0\x9f\x98\x80";

const AsciiContext = struct {
    sink: u64 = 0,
    buffer: [32]u8 = undefined,

    fn run(context_ptr: *anyopaque) void {
        const context: *AsciiContext = @ptrCast(@alignCast(context_ptr));
        @memcpy(context.buffer[0..ascii_source.len], ascii_source);
        const trimmed = static_string.ascii.trimWhitespace(context.buffer[0..ascii_source.len]);
        @memcpy(context.buffer[0..trimmed.len], trimmed);
        static_string.ascii.toLowerInPlace(context.buffer[0..trimmed.len]);
        const normalized = context.buffer[0..trimmed.len];
        if (!std.mem.eql(u8, normalized, "x-request-id")) unreachable;
        context.sink = bench.case.blackBox(@as(u64, @intCast(normalized.len)));
        std.debug.assert(context.sink != 0);
    }
};

const Utf8Context = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *Utf8Context = @ptrCast(@alignCast(context_ptr));
        if (!static_string.utf8.isValid(utf8_source)) unreachable;
        context.sink = bench.case.blackBox(@as(u64, @intCast(utf8_source.len)));
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
    var output_dir = try support.openOutputDir(io, "text_validation_normalize");
    defer output_dir.close(io);

    var ascii_context = AsciiContext{};
    var utf8_context = Utf8Context{};
    var case_storage: [2]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_string_text_validation_normalize",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "ascii_header_normalize",
        .tags = &[_][]const u8{ "static_string", "ascii", "normalize" },
        .context = &ascii_context,
        .run_fn = AsciiContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "utf8_validate_multibyte",
        .tags = &[_][]const u8{ "static_string", "utf8", "validate" },
        .context = &utf8_context,
        .run_fn = Utf8Context.run,
    }));

    var sample_storage: [bench_config.sample_count * 2]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [2]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_string text validation and normalize ==\n", .{});
    try support.writeGroupReport(
        run_result,
        io,
        output_dir,
        "ascii header normalize and multibyte utf8 validation",
    );
}

fn validateSemanticPreflight() void {
    var ascii_context = AsciiContext{};
    AsciiContext.run(&ascii_context);

    var utf8_context = Utf8Context{};
    Utf8Context.run(&utf8_context);
}
