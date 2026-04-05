//! Thin benchmark review workflow over raw text export and baseline comparison.

const std = @import("std");
const testing = std.testing;
const runner = @import("runner.zig");
const stats = @import("stats.zig");
const baseline = @import("baseline.zig");
const history = @import("history_binary.zig");
const exports = @import("export.zig");
const builtin = @import("builtin");

pub const WorkflowMode = enum(u8) {
    report_only = 1,
    record = 2,
    compare = 3,
    record_if_missing_then_compare = 4,
};

pub const WorkflowError = baseline.BenchmarkBaselineError || error{
    RegressionDetected,
    WriteFailed,
};

pub const BaselineWorkflowConfig = struct {
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    mode: WorkflowMode = .record_if_missing_then_compare,
    report_config: exports.TextReportConfig = .{},
    compare_config: baseline.BaselineCompareConfig = .{},
    enforce_gate: bool = false,
    stats_storage: []stats.BenchmarkStats,
    baseline_document_buffer: []u8,
    read_buffers: baseline.BaselineReadBuffers,
    comparison_storage: []baseline.BaselineCaseComparison,
    history: ?HistoryWorkflowConfig = null,
};

pub const HistoryWorkflowConfig = struct {
    sub_path: []const u8,
    package_name: []const u8,
    host_label: ?[]const u8 = null,
    environment_note: ?[]const u8 = null,
    environment_tags: []const []const u8 = &.{},
    timestamp_unix_ms: ?u64 = null,
    max_records: usize = 16,
    append_buffers: history.HistoryAppendBuffers,
    read_buffers: history.HistoryReadBuffers,
    comparison_storage: []baseline.BaselineCaseComparison,
};

pub const WorkflowAction = enum(u8) {
    none = 1,
    recorded = 2,
    compared = 3,
};

pub const WorkflowSummary = struct {
    derived_stats: []const stats.BenchmarkStats,
    action: WorkflowAction,
    compare_summary: ?baseline.BaselineCompareSummary = null,
};

pub fn writeTextAndOptionalBaselineReport(
    writer: *std.Io.Writer,
    run_result: runner.BenchmarkRunResult,
    workflow_config: ?BaselineWorkflowConfig,
) WorkflowError!WorkflowSummary {
    if (workflow_config) |workflow| {
        try exports.writeTextWithConfig(writer, run_result, workflow.report_config);
    } else {
        try exports.writeText(writer, run_result);
    }
    if (workflow_config == null) {
        return .{
            .derived_stats = &.{},
            .action = .none,
        };
    }

    var workflow = workflow_config.?;
    const derived_stats = try baseline.deriveStats(run_result, workflow.stats_storage);
    const summary: WorkflowSummary = switch (workflow.mode) {
        .report_only => WorkflowSummary{
            .derived_stats = derived_stats,
            .action = .none,
        },
        .record => try recordBaseline(writer, derived_stats, run_result.mode, workflow),
        .compare => try compareBaseline(writer, derived_stats, workflow),
        .record_if_missing_then_compare => compareBaseline(writer, derived_stats, workflow) catch |err| switch (err) {
            error.FileNotFound => try recordBaseline(writer, derived_stats, run_result.mode, workflow),
            else => return err,
        },
    };
    try updateHistory(writer, derived_stats, run_result.mode, workflow, summary);
    return summary;
}

fn recordBaseline(
    writer: *std.Io.Writer,
    derived_stats: []const stats.BenchmarkStats,
    mode: @import("config.zig").BenchmarkMode,
    workflow: BaselineWorkflowConfig,
) WorkflowError!WorkflowSummary {
    _ = try baseline.writeBaselineFile(
        workflow.io,
        workflow.dir,
        workflow.sub_path,
        workflow.baseline_document_buffer,
        .{
            .version = baseline.baseline_version,
            .mode = mode,
            .cases = derived_stats,
        },
    );
    try writer.print("baseline_recorded path={s}\n", .{workflow.sub_path});
    return .{
        .derived_stats = derived_stats,
        .action = .recorded,
    };
}

fn compareBaseline(
    writer: *std.Io.Writer,
    derived_stats: []const stats.BenchmarkStats,
    workflow: BaselineWorkflowConfig,
) WorkflowError!WorkflowSummary {
    const artifact = try baseline.readBaselineFile(
        workflow.io,
        workflow.dir,
        workflow.sub_path,
        workflow.read_buffers,
    );
    const compare_summary = try baseline.compareArtifactToCandidate(
        artifact,
        derived_stats,
        workflow.compare_config,
        workflow.comparison_storage,
    );

    try writer.print("baseline_path={s}\n", .{workflow.sub_path});
    try baseline.writeComparisonText(writer, compare_summary);
    if (workflow.enforce_gate and !compare_summary.passed) return error.RegressionDetected;

    return .{
        .derived_stats = derived_stats,
        .action = .compared,
        .compare_summary = compare_summary,
    };
}

fn updateHistory(
    writer: *std.Io.Writer,
    derived_stats: []const stats.BenchmarkStats,
    mode: @import("config.zig").BenchmarkMode,
    workflow: BaselineWorkflowConfig,
    summary: WorkflowSummary,
) WorkflowError!void {
    const history_config = workflow.history orelse return;
    const environment = history.captureEnvironmentMetadata(.{
        .package_name = history_config.package_name,
        .baseline_path = workflow.sub_path,
        .benchmark_mode = mode,
        .host_label = history_config.host_label,
        .environment_note = history_config.environment_note,
        .environment_tags = history_config.environment_tags,
    });

    const latest = history.readMostRecentCompatibleRecord(
        workflow.io,
        workflow.dir,
        history_config.sub_path,
        environment,
        history_config.read_buffers,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    var latest_compare_summary: ?baseline.BaselineCompareSummary = null;
    if (latest) |record| {
        latest_compare_summary = try baseline.compareArtifactToCandidate(
            history.asBaselineArtifact(record),
            derived_stats,
            workflow.compare_config,
            history_config.comparison_storage,
        );
    }
    try history.writeLatestCompatibleComparisonText(
        writer,
        history_config.sub_path,
        latest,
        latest_compare_summary,
    );

    const timestamp_unix_ms = if (history_config.timestamp_unix_ms) |timestamp|
        timestamp
    else
        try currentUnixMs();

    _ = try history.appendRecordFile(
        workflow.io,
        workflow.dir,
        history_config.sub_path,
        history_config.append_buffers,
        history_config.max_records,
        .{
            .version = history.history_version,
            .timestamp_unix_ms = timestamp_unix_ms,
            .action = switch (summary.action) {
                .none => .report_only,
                .recorded => .recorded,
                .compared => .compared,
            },
            .comparison_passed = if (summary.compare_summary) |compare_summary| compare_summary.passed else null,
            .environment = environment,
            .cases = derived_stats,
        },
    );
}

fn currentUnixMs() WorkflowError!u64 {
    return switch (builtin.os.tag) {
        .windows => currentUnixMsWindows(),
        .wasi, .uefi => error.Unsupported,
        else => currentUnixMsPosix(),
    };
}

fn currentUnixMsPosix() WorkflowError!u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return error.Unsupported;
    if (ts.sec < 0) return error.Unsupported;
    const seconds_ms = std.math.mul(u64, @intCast(ts.sec), std.time.ms_per_s) catch return error.Overflow;
    const nanos_ms: u64 = @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms));
    return std.math.add(u64, seconds_ms, nanos_ms) catch return error.Overflow;
}

fn currentUnixMsWindows() WorkflowError!u64 {
    var file_time: std.os.windows.FILETIME = undefined;
    GetSystemTimeAsFileTime(&file_time);
    const now_ns = std.os.windows.fileTimeToNanoSeconds(file_time);
    const now_ms = now_ns.toMilliseconds();
    if (now_ms < 0) return error.Unsupported;
    return @intCast(now_ms);
}

extern "kernel32" fn GetSystemTimeAsFileTime(system_time_as_file_time: *std.os.windows.FILETIME) callconv(.winapi) void;

test "workflow records missing baseline then compares existing baseline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 100, .iteration_count = 4 },
        .{ .elapsed_ns = 120, .iteration_count = 4 },
    };
    const case_results = [_]runner.BenchmarkCaseResult{
        .{
            .name = "workflow_case",
            .warmup_iterations = 1,
            .measure_iterations = 4,
            .samples = &samples,
            .total_elapsed_ns = 220,
        },
    };
    const run_result = runner.BenchmarkRunResult{
        .mode = .smoke,
        .case_results = &case_results,
    };

    var stats_storage_a: [1]stats.BenchmarkStats = undefined;
    var write_buffer_a: [1024]u8 = undefined;
    var read_source_a: [1024]u8 = undefined;
    var names_a: [4096]u8 = undefined;
    var comparisons_a: [2]baseline.BaselineCaseComparison = undefined;
    var report_writer_a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report_writer_a.deinit();
    const first = try writeTextAndOptionalBaselineReport(&report_writer_a.writer, run_result, .{
        .io = io,
        .dir = tmp_dir.dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .stats_storage = &stats_storage_a,
        .baseline_document_buffer = &write_buffer_a,
        .read_buffers = .{
            .source_buffer = &read_source_a,
            .parse_buffer = &names_a,
        },
        .comparison_storage = &comparisons_a,
    });
    try testing.expectEqual(WorkflowAction.recorded, first.action);

    var stats_storage_b: [1]stats.BenchmarkStats = undefined;
    var write_buffer_b: [1024]u8 = undefined;
    var read_source_b: [1024]u8 = undefined;
    var names_b: [4096]u8 = undefined;
    var comparisons_b: [2]baseline.BaselineCaseComparison = undefined;
    var report_writer_b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report_writer_b.deinit();
    const second = try writeTextAndOptionalBaselineReport(&report_writer_b.writer, run_result, .{
        .io = io,
        .dir = tmp_dir.dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .stats_storage = &stats_storage_b,
        .baseline_document_buffer = &write_buffer_b,
        .read_buffers = .{
            .source_buffer = &read_source_b,
            .parse_buffer = &names_b,
        },
        .comparison_storage = &comparisons_b,
    });
    try testing.expectEqual(WorkflowAction.compared, second.action);
    try testing.expect(second.compare_summary != null);
    try testing.expect(second.compare_summary.?.passed);
}

test "workflow records bounded history metadata beside baseline reviews" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 100, .iteration_count = 4 },
        .{ .elapsed_ns = 110, .iteration_count = 4 },
    };
    const case_results = [_]runner.BenchmarkCaseResult{
        .{
            .name = "workflow_case",
            .warmup_iterations = 1,
            .measure_iterations = 4,
            .samples = &samples,
            .total_elapsed_ns = 210,
        },
    };
    const run_result = runner.BenchmarkRunResult{
        .mode = .full,
        .case_results = &case_results,
    };

    var stats_storage_a: [1]stats.BenchmarkStats = undefined;
    var write_buffer_a: [1024]u8 = undefined;
    var read_source_a: [1024]u8 = undefined;
    var names_a: [4096]u8 = undefined;
    var comparisons_a: [2]baseline.BaselineCaseComparison = undefined;
    var history_existing_a: [4096]u8 = undefined;
    var history_record_a: [2048]u8 = undefined;
    var history_frame_a: [2048]u8 = undefined;
    var history_out_a: [4096]u8 = undefined;
    var history_file_a: [4096]u8 = undefined;
    var history_cases_a: [1]stats.BenchmarkStats = undefined;
    var history_names_a: [256]u8 = undefined;
    var history_tags_a: [4][]const u8 = undefined;
    var history_comparisons_a: [2]baseline.BaselineCaseComparison = undefined;
    var report_writer_a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report_writer_a.deinit();
    _ = try writeTextAndOptionalBaselineReport(&report_writer_a.writer, run_result, .{
        .io = io,
        .dir = tmp_dir.dir,
        .sub_path = "baseline.zon",
        .mode = .record,
        .stats_storage = &stats_storage_a,
        .baseline_document_buffer = &write_buffer_a,
        .read_buffers = .{
            .source_buffer = &read_source_a,
            .parse_buffer = &names_a,
        },
        .comparison_storage = &comparisons_a,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_testing",
            .host_label = "host-a",
            .environment_note = "lab-a",
            .environment_tags = &[_][]const u8{ "workflow", "history" },
            .timestamp_unix_ms = 11,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_a,
                .record_buffer = &history_record_a,
                .frame_buffer = &history_frame_a,
                .output_file_buffer = &history_out_a,
            },
            .read_buffers = .{
                .file_buffer = &history_file_a,
                .case_storage = &history_cases_a,
                .string_buffer = &history_names_a,
                .tag_storage = &history_tags_a,
            },
            .comparison_storage = &history_comparisons_a,
        },
    });

    var stats_storage_b: [1]stats.BenchmarkStats = undefined;
    var write_buffer_b: [1024]u8 = undefined;
    var read_source_b: [1024]u8 = undefined;
    var names_b: [4096]u8 = undefined;
    var comparisons_b: [2]baseline.BaselineCaseComparison = undefined;
    var history_existing_b: [4096]u8 = undefined;
    var history_record_b: [2048]u8 = undefined;
    var history_frame_b: [2048]u8 = undefined;
    var history_out_b: [4096]u8 = undefined;
    var history_file_b: [4096]u8 = undefined;
    var history_cases_b: [1]stats.BenchmarkStats = undefined;
    var history_names_b: [256]u8 = undefined;
    var history_tags_b: [4][]const u8 = undefined;
    var history_comparisons_b: [2]baseline.BaselineCaseComparison = undefined;
    var report_writer_b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report_writer_b.deinit();
    _ = try writeTextAndOptionalBaselineReport(&report_writer_b.writer, run_result, .{
        .io = io,
        .dir = tmp_dir.dir,
        .sub_path = "baseline.zon",
        .mode = .compare,
        .stats_storage = &stats_storage_b,
        .baseline_document_buffer = &write_buffer_b,
        .read_buffers = .{
            .source_buffer = &read_source_b,
            .parse_buffer = &names_b,
        },
        .comparison_storage = &comparisons_b,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_testing",
            .host_label = "host-a",
            .environment_note = "lab-a",
            .environment_tags = &[_][]const u8{ "workflow", "history" },
            .timestamp_unix_ms = 22,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_b,
                .record_buffer = &history_record_b,
                .frame_buffer = &history_frame_b,
                .output_file_buffer = &history_out_b,
            },
            .read_buffers = .{
                .file_buffer = &history_file_b,
                .case_storage = &history_cases_b,
                .string_buffer = &history_names_b,
                .tag_storage = &history_tags_b,
            },
            .comparison_storage = &history_comparisons_b,
        },
    });

    var report = report_writer_b.toArrayList();
    defer report.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, report.items, "history_path=history.binlog") != null);
    try testing.expect(std.mem.indexOf(u8, report.items, "history_latest timestamp_unix_ms=11") != null);
    try testing.expect(std.mem.indexOf(u8, report.items, "environment_note=lab-a") != null);
    try testing.expect(std.mem.indexOf(u8, report.items, "environment_tags=workflow,history") != null);

    var stored_history: [4096]u8 = undefined;
    const history_bytes = try tmp_dir.dir.readFile(io, "history.binlog", &stored_history);
    const history_iter = try history.readMostRecentCompatibleRecord(
        io,
        tmp_dir.dir,
        "history.binlog",
        .{
            .package_name = "static_testing",
            .baseline_path = "baseline.zon",
            .target_arch = @tagName(builtin.target.cpu.arch),
            .target_os = @tagName(builtin.target.os.tag),
            .target_abi = @tagName(builtin.target.abi),
            .build_mode = @import("../testing/identity.zig").BuildMode.fromOptimizeMode(builtin.mode),
            .benchmark_mode = .full,
            .host_label = "host-a",
            .environment_note = "lab-a",
            .tags = &[_][]const u8{ "workflow", "history" },
        },
        .{
            .file_buffer = &stored_history,
            .case_storage = &history_cases_b,
            .string_buffer = &history_names_b,
            .tag_storage = &history_tags_b,
        },
    );
    try testing.expect(history_bytes.len != 0);
    try testing.expect(history_iter != null);
    try testing.expectEqual(@as(u64, 22), history_iter.?.timestamp_unix_ms);
}
