const std = @import("std");
const assert = std.debug.assert;
const static_testing = @import("static_testing");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .smoke,
    .warmup_iterations = 1,
    .measure_iterations = 4,
    .sample_count = 3,
};

const CounterContext = struct {
    count: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        context.count +%= 1;
        _ = bench.case.blackBox(context.count);
    }
};

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();
    const output_dir_path = ".zig-cache/static_testing/examples/bench_baseline_compare";
    cwd.deleteTree(io, output_dir_path) catch {};

    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer cleanupOutputDir(cwd, io, output_dir_path);
    defer output_dir.close(io);

    var context = CounterContext{};
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "baseline_demo",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "increment",
        .tags = &[_][]const u8{"baseline_demo"},
        .context = &context,
        .run_fn = CounterContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_results: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_results);

    var baseline_document_buffer: [1024]u8 = undefined;
    var read_source_buffer: [1024]u8 = undefined;
    var read_parse_buffer: [4096]u8 = undefined;
    var stats_storage: [1]bench.stats.BenchmarkStats = undefined;
    var comparisons: [2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [4096]u8 = undefined;
    var history_record_buffer: [2048]u8 = undefined;
    var history_frame_buffer: [2048]u8 = undefined;
    var history_output_buffer: [4096]u8 = undefined;
    var history_file_buffer: [4096]u8 = undefined;
    var history_cases: [1]bench.stats.BenchmarkStats = undefined;
    var history_name_buffer: [256]u8 = undefined;
    var history_tags_buffer: [4][]const u8 = undefined;
    var history_comparisons: [2]bench.baseline.BaselineCaseComparison = undefined;
    var report_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&report_writer.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record,
        .stats_storage = &stats_storage,
        .baseline_document_buffer = &baseline_document_buffer,
        .read_buffers = .{
            .source_buffer = &read_source_buffer,
            .parse_buffer = &read_parse_buffer,
        },
        .comparison_storage = &comparisons,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_testing",
            .host_label = "bench_baseline_compare_example",
            .environment_tags = &[_][]const u8{ "baseline_demo", "smoke" },
            .timestamp_unix_ms = 1,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_name_buffer,
                .tag_storage = &history_tags_buffer,
            },
            .comparison_storage = &history_comparisons,
        },
    });

    const baseline_zon = try output_dir.readFile(io, "baseline.zon", &read_source_buffer);
    const summary = try bench.workflow.writeTextAndOptionalBaselineReport(&report_writer.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .compare,
        .stats_storage = &stats_storage,
        .baseline_document_buffer = &baseline_document_buffer,
        .read_buffers = .{
            .source_buffer = &read_source_buffer,
            .parse_buffer = &read_parse_buffer,
        },
        .comparison_storage = &comparisons,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_testing",
            .host_label = "bench_baseline_compare_example",
            .environment_tags = &[_][]const u8{ "baseline_demo", "smoke" },
            .timestamp_unix_ms = 2,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_name_buffer,
                .tag_storage = &history_tags_buffer,
            },
            .comparison_storage = &history_comparisons,
        },
    });

    assert(summary.compare_summary != null);
    std.debug.print("{s}\n", .{baseline_zon});
    const latest_history = (try bench.history.readMostRecentCompatibleRecord(
        io,
        output_dir,
        "history.binlog",
        bench.history.captureEnvironmentMetadata(.{
            .package_name = "static_testing",
            .baseline_path = "baseline.zon",
            .benchmark_mode = run_result.mode,
            .host_label = "bench_baseline_compare_example",
            .environment_tags = &[_][]const u8{ "baseline_demo", "smoke" },
        }),
        .{
            .file_buffer = &history_file_buffer,
            .case_storage = &history_cases,
            .string_buffer = &history_name_buffer,
            .tag_storage = &history_tags_buffer,
        },
    )).?;
    std.debug.print(
        "history_latest timestamp_unix_ms={} case_count={}\n",
        .{ latest_history.timestamp_unix_ms, latest_history.cases.len },
    );
    var out = report_writer.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{out.items});
}

fn cleanupOutputDir(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) void {
    dir.deleteTree(io, sub_path) catch |err| {
        std.log.warn("Best-effort cleanupOutputDir failed for {s}: {s}.", .{
            sub_path,
            @errorName(err),
        });
    };
}
