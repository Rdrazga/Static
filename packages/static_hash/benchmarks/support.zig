const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const static_testing = @import("static_testing");

const bench = static_testing.bench;

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

pub const CommonBuffers = struct {
    stats_storage: []bench.stats.BenchmarkStats,
    baseline_document_buffer: []u8,
    read_source_buffer: []u8,
    read_parse_buffer: []u8,
    comparison_storage: []bench.baseline.BaselineCaseComparison,
};

pub const HistoryBuffers = struct {
    sub_path: []const u8,
    package_name: []const u8,
    environment_note: ?[]const u8 = null,
    host_label: ?[]const u8 = null,
    environment_tags: []const []const u8 = &.{},
    timestamp_unix_ms: ?u64 = null,
    max_records: usize = 16,
    append_buffers: bench.history.HistoryAppendBuffers,
    read_buffers: bench.history.HistoryReadBuffers,
    comparison_storage: []bench.baseline.BaselineCaseComparison,
};

pub fn openOutputDir(
    io: std.Io,
    benchmark_name: []const u8,
) !std.Io.Dir {
    assert(benchmark_name.len > 0);

    const cwd = std.Io.Dir.cwd();
    var path_buffer: [192]u8 = undefined;
    const output_dir_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/static_hash/benchmarks/{s}",
        .{benchmark_name},
    );
    assert(output_dir_path.len > 0);
    return cwd.createDirPathOpen(io, output_dir_path, .{});
}

pub fn writeReport(
    writer: *std.Io.Writer,
    run_result: bench.runner.BenchmarkRunResult,
    io: std.Io,
    output_dir: std.Io.Dir,
    benchmark_name: []const u8,
    report_buffers: CommonBuffers,
    mode: bench.workflow.WorkflowMode,
    compare_config: bench.baseline.BaselineCompareConfig,
    enforce_gate: bool,
    history: ?HistoryBuffers,
    report_config: bench.exports.TextReportConfig,
) !bench.workflow.WorkflowSummary {
    assert(benchmark_name.len > 0);
    assert(report_buffers.stats_storage.len > 0);
    assert(report_buffers.baseline_document_buffer.len > 0);
    assert(report_buffers.read_source_buffer.len > 0);
    assert(report_buffers.read_parse_buffer.len > 0);
    assert(report_buffers.comparison_storage.len > 0);

    return bench.workflow.writeTextAndOptionalBaselineReport(writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = mode,
        .report_config = report_config,
        .compare_config = compare_config,
        .enforce_gate = enforce_gate,
        .stats_storage = report_buffers.stats_storage,
        .baseline_document_buffer = report_buffers.baseline_document_buffer,
        .read_buffers = .{
            .source_buffer = report_buffers.read_source_buffer,
            .parse_buffer = report_buffers.read_parse_buffer,
        },
        .comparison_storage = report_buffers.comparison_storage,
        .history = if (history) |history_buffers| .{
            .sub_path = history_buffers.sub_path,
            .package_name = history_buffers.package_name,
            .host_label = history_buffers.host_label,
            .environment_note = history_buffers.environment_note,
            .environment_tags = history_buffers.environment_tags,
            .timestamp_unix_ms = history_buffers.timestamp_unix_ms,
            .max_records = history_buffers.max_records,
            .append_buffers = history_buffers.append_buffers,
            .read_buffers = history_buffers.read_buffers,
            .comparison_storage = history_buffers.comparison_storage,
        } else null,
    });
}
