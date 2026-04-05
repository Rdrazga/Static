const std = @import("std");
const testing = std.testing;
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

test "benchmark baseline persists across file boundary and compares deterministically" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();

    var context = CounterContext{};
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "baseline_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "increment",
        .tags = &[_][]const u8{"baseline_roundtrip"},
        .context = &context,
        .run_fn = CounterContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_results: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_results);

    var stats_storage: [1]bench.stats.BenchmarkStats = undefined;
    const derived = try bench.baseline.deriveStats(run_result, &stats_storage);

    var baseline_document_buffer: [1024]u8 = undefined;
    _ = try bench.baseline.writeBaselineFile(
        io,
        tmp_dir.dir,
        "baseline.zon",
        &baseline_document_buffer,
        .{
            .version = bench.baseline.baseline_version,
            .mode = run_result.mode,
            .cases = derived,
        },
    );

    var read_source_buffer: [1024]u8 = undefined;
    var read_parse_buffer: [4096]u8 = undefined;
    const artifact = try bench.baseline.readBaselineFile(
        io,
        tmp_dir.dir,
        "baseline.zon",
        .{
            .source_buffer = &read_source_buffer,
            .parse_buffer = &read_parse_buffer,
        },
    );

    var comparisons: [2]bench.baseline.BaselineCaseComparison = undefined;
    const summary = try bench.baseline.compareArtifactToCandidate(
        artifact,
        derived,
        .{},
        &comparisons,
    );

    try testing.expect(summary.passed);
    try testing.expectEqual(@as(u32, 1), summary.passed_case_count);
    try testing.expectEqual(@as(usize, 1), summary.comparisons.len);
    try testing.expectEqualStrings("increment", summary.comparisons[0].case_name);
    try testing.expectEqual(bench.baseline.CaseStatus.compared, summary.comparisons[0].status);
    try testing.expectEqual(bench.baseline.CaseDecision.pass, summary.comparisons[0].decision);
}
