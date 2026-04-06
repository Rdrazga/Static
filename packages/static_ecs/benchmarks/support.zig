const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const static_testing = @import("static_testing");

const bench = static_testing.bench;
const max_environment_tag_count: usize = 4;

pub const default_benchmark_config: bench.config.BenchmarkConfig = .{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 1024,
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

pub const ReportMetadata = struct {
    environment_note: []const u8 = default_environment_note,
    environment_tags: []const []const u8 = &.{},
};

pub fn openOutputDir(io: std.Io, benchmark_name: []const u8) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    var path_buffer: [192]u8 = undefined;
    const output_dir_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/static_ecs/benchmarks/{s}",
        .{benchmark_name},
    );
    return cwd.createDirPathOpen(io, output_dir_path, .{});
}

pub fn writeGroupReport(
    comptime case_capacity: usize,
    benchmark_name: []const u8,
    run_result: bench.runner.BenchmarkRunResult,
    io: std.Io,
    output_dir: std.Io.Dir,
    metadata: ReportMetadata,
) !void {
    comptime assert(case_capacity > 0);
    assert(benchmark_name.len > 0);
    assert(run_result.case_results.len <= case_capacity);
    assert(metadata.environment_note.len > 0);
    assert(metadata.environment_tags.len <= max_environment_tag_count);

    const baseline_document_len = @max(16 * 1024, case_capacity * 2048);
    const read_source_len = @max(16 * 1024, case_capacity * 2048);
    const read_parse_len = @max(32 * 1024, case_capacity * 4096);
    const comparison_capacity = case_capacity * 2;
    const history_existing_len = @max(64 * 1024, case_capacity * 16 * 1024);
    const history_record_len = @max(16 * 1024, case_capacity * 4096);
    const history_frame_len = @max(16 * 1024, case_capacity * 4096);
    const history_output_len = @max(64 * 1024, case_capacity * 16 * 1024);
    const history_file_len = @max(64 * 1024, case_capacity * 16 * 1024);
    const history_names_len = @max(4096, case_capacity * 1024);

    var stats_storage: [case_capacity]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [baseline_document_len]u8 = undefined;
    var read_source_buffer: [read_source_len]u8 = undefined;
    var read_parse_buffer: [read_parse_len]u8 = undefined;
    var comparisons: [comparison_capacity]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [history_existing_len]u8 = undefined;
    var history_record_buffer: [history_record_len]u8 = undefined;
    var history_frame_buffer: [history_frame_len]u8 = undefined;
    var history_output_buffer: [history_output_len]u8 = undefined;
    var history_file_buffer: [history_file_len]u8 = undefined;
    var history_cases: [case_capacity]bench.stats.BenchmarkStats = undefined;
    var history_names: [history_names_len]u8 = undefined;
    var history_tags: [max_environment_tag_count][]const u8 = undefined;
    var history_comparisons: [comparison_capacity]bench.baseline.BaselineCaseComparison = undefined;
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
            .package_name = "static_ecs",
            .environment_note = metadata.environment_note,
            .environment_tags = metadata.environment_tags,
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
    std.debug.print("== static_ecs {s} ==\n", .{benchmark_name});
    std.debug.print("{s}", .{out.items});
}
