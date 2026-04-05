const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const static_testing = @import("static_testing");

const bench = static_testing.bench;

pub const default_benchmark_config: bench.config.BenchmarkConfig = .{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 4096,
    .sample_count = 8,
};

pub const default_compare_config: bench.baseline.BaselineCompareConfig = .{
    .thresholds = .{
        .median_ratio_ppm = 300_000,
        .p95_ratio_ppm = 400_000,
        .p99_ratio_ppm = 500_000,
    },
};

pub const default_environment_note =
    std.fmt.comptimePrint("os={s},arch={s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });

pub fn openOutputDir(
    io: std.Io,
    benchmark_name: []const u8,
) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    var path_buffer: [192]u8 = undefined;
    const output_dir_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/static_memory/benchmarks/{s}",
        .{benchmark_name},
    );
    return cwd.createDirPathOpen(io, output_dir_path, .{});
}

pub fn writeSingleCaseReport(
    benchmark_name: []const u8,
    run_result: bench.runner.BenchmarkRunResult,
    io: std.Io,
    output_dir: std.Io.Dir,
    environment_note: []const u8,
) !void {
    assert(run_result.case_results.len == 1);
    assert(benchmark_name.len > 0);
    assert(environment_note.len > 0);

    var stats_storage: [1]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [1024]u8 = undefined;
    var read_source_buffer: [1024]u8 = undefined;
    var read_parse_buffer: [4096]u8 = undefined;
    var comparisons: [2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [8192]u8 = undefined;
    var history_record_buffer: [2048]u8 = undefined;
    var history_frame_buffer: [2048]u8 = undefined;
    var history_output_buffer: [8192]u8 = undefined;
    var history_file_buffer: [8192]u8 = undefined;
    var history_cases: [1]bench.stats.BenchmarkStats = undefined;
    var history_names: [256]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [2]bench.baseline.BaselineCaseComparison = undefined;
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&aw.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .compare_config = default_compare_config,
        .enforce_gate = false,
        .stats_storage = &stats_storage,
        .baseline_document_buffer = &baseline_document_buffer,
        .read_buffers = .{
            .source_buffer = &read_source_buffer,
            .parse_buffer = &read_parse_buffer,
        },
        .comparison_storage = &comparisons,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_memory",
            .environment_note = environment_note,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_names,
                .tag_storage = &history_tags,
            },
            .comparison_storage = &history_comparisons,
        },
    });
    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("== static_memory {s} ==\n", .{benchmark_name});
    std.debug.print("{s}", .{out.items});
}
