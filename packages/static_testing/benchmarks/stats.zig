//! Benchmarks derived-statistics helpers (`bench.stats`).
//!
//! Run with:
//! - `zig build bench -Doptimize=ReleaseFast` (from `packages/static_testing`).

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const static_testing = @import("static_testing");

const bench = static_testing.bench;

const sample_len_fast: usize = bench.stats.stats_inline_samples_max;
const sample_len_fallback: usize = bench.stats.stats_inline_samples_max + 1;

const ComputeStatsContext = struct {
    case_result: bench.runner.BenchmarkCaseResult,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        const derived = bench.stats.computeStats(context.case_result) catch |err| {
            panic("computeStats failed: {s}", .{@errorName(err)});
        };

        context.sink +%= derived.median_elapsed_ns;
        _ = bench.case.blackBox(context.sink);
    }
};

const ComputeStatsScratchContext = struct {
    case_result: bench.runner.BenchmarkCaseResult,
    scratch: []u64,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        assert(context.scratch.len >= context.case_result.samples.len);
        const derived = bench.stats.computeStatsWithScratch(
            context.case_result,
            context.scratch,
        ) catch |err| {
            panic("computeStatsWithScratch failed: {s}", .{@errorName(err)});
        };

        context.sink +%= derived.median_elapsed_ns;
        _ = bench.case.blackBox(context.sink);
    }
};

fn fillDeterministicSamples(samples: []bench.runner.BenchmarkSample) void {
    assert(samples.len > 0);

    var state: u64 = 0x9e37_79b9_7f4a_7c15;
    for (samples) |*sample| {
        state = state *% 6364136223846793005 +% 1;
        sample.* = .{
            .elapsed_ns = 100 + (state & 0xffff),
            .iteration_count = 1,
        };
    }
}

const StatsExpectation = struct {
    sample_count: u32,
    min_elapsed_ns: u64,
    max_elapsed_ns: u64,
    mean_elapsed_ns: u64,
    median_elapsed_ns: u64,
    p90_elapsed_ns: u64,
    p95_elapsed_ns: u64,
};

fn buildStatsExpectation(
    case_result: bench.runner.BenchmarkCaseResult,
    elapsed_scratch: []u64,
) !StatsExpectation {
    assert(case_result.samples.len > 0);
    assert(elapsed_scratch.len >= case_result.samples.len);

    var elapsed_sum_ns: u128 = 0;
    var min_elapsed_ns = case_result.samples[0].elapsed_ns;
    var max_elapsed_ns = case_result.samples[0].elapsed_ns;
    const elapsed_ns = elapsed_scratch[0..case_result.samples.len];

    for (case_result.samples, 0..) |sample, index| {
        elapsed_ns[index] = sample.elapsed_ns;
        elapsed_sum_ns = std.math.add(u128, elapsed_sum_ns, sample.elapsed_ns) catch {
            return error.Overflow;
        };
        if (sample.elapsed_ns < min_elapsed_ns) min_elapsed_ns = sample.elapsed_ns;
        if (sample.elapsed_ns > max_elapsed_ns) max_elapsed_ns = sample.elapsed_ns;
    }
    std.sort.heap(u64, elapsed_ns, {}, std.sort.asc(u64));

    return .{
        .sample_count = @as(u32, @intCast(case_result.samples.len)),
        .min_elapsed_ns = min_elapsed_ns,
        .max_elapsed_ns = max_elapsed_ns,
        .mean_elapsed_ns = try meanFromSum(elapsed_sum_ns, case_result.samples.len),
        .median_elapsed_ns = percentileFromSortedReference(elapsed_ns, 50),
        .p90_elapsed_ns = percentileFromSortedReference(elapsed_ns, 90),
        .p95_elapsed_ns = percentileFromSortedReference(elapsed_ns, 95),
    };
}

fn meanFromSum(elapsed_sum_ns: u128, sample_len: usize) !u64 {
    assert(sample_len > 0);

    const mean_elapsed_ns = @divFloor(elapsed_sum_ns, sample_len);
    if (mean_elapsed_ns > std.math.maxInt(u64)) return error.Overflow;
    return @as(u64, @intCast(mean_elapsed_ns));
}

fn percentileFromSortedReference(sorted_elapsed_ns: []const u64, percentile_percent: u8) u64 {
    assert(sorted_elapsed_ns.len > 0);
    assert(percentile_percent <= 100);

    if (percentile_percent == 0) return sorted_elapsed_ns[0];
    if (percentile_percent == 100) return sorted_elapsed_ns[sorted_elapsed_ns.len - 1];

    const numerator = @as(u128, sorted_elapsed_ns.len) * percentile_percent;
    const rank_1based = @divFloor(numerator + 99, 100);
    assert(rank_1based > 0);
    assert(rank_1based <= sorted_elapsed_ns.len);
    return sorted_elapsed_ns[@as(usize, @intCast(rank_1based - 1))];
}

fn assertExpectedStats(
    derived: bench.stats.BenchmarkStats,
    expected: StatsExpectation,
) void {
    assert(derived.sample_count == expected.sample_count);
    assert(derived.min_elapsed_ns == expected.min_elapsed_ns);
    assert(derived.max_elapsed_ns == expected.max_elapsed_ns);
    assert(derived.mean_elapsed_ns == expected.mean_elapsed_ns);
    assert(derived.median_elapsed_ns == expected.median_elapsed_ns);
    assert(derived.p90_elapsed_ns == expected.p90_elapsed_ns);
    assert(derived.p95_elapsed_ns == expected.p95_elapsed_ns);
}

fn verifyComputeStatsCase(
    case_result: bench.runner.BenchmarkCaseResult,
    verify_scratch: []u64,
) !void {
    const expected = try buildStatsExpectation(case_result, verify_scratch);
    const derived = try bench.stats.computeStats(case_result);
    assertExpectedStats(derived, expected);
}

fn verifyComputeStatsWithScratchCase(
    case_result: bench.runner.BenchmarkCaseResult,
    verify_scratch: []u64,
) !void {
    const expected = try buildStatsExpectation(case_result, verify_scratch);
    const derived = try bench.stats.computeStatsWithScratch(case_result, verify_scratch);
    assertExpectedStats(derived, expected);
}

fn runBenchmarkGroup(
    group: *const bench.group.BenchmarkGroup,
    sample_storage: []bench.runner.BenchmarkSample,
    case_result_storage: []bench.runner.BenchmarkCaseResult,
) !void {
    const run_result = try bench.runner.runGroup(group, sample_storage, case_result_storage);

    std.debug.print("mode: {s}\n", .{@tagName(run_result.mode)});
    for (run_result.case_results) |case_result| {
        const derived = try bench.stats.computeStats(case_result);
        std.debug.print(
            "case {s} samples={d} median_elapsed_ns={d} mean_elapsed_ns={d}\n",
            .{
                derived.case_name,
                derived.sample_count,
                derived.median_elapsed_ns,
                derived.mean_elapsed_ns,
            },
        );
    }
}

pub fn main() !void {
    var input_samples_fast: [sample_len_fast]bench.runner.BenchmarkSample = undefined;
    fillDeterministicSamples(&input_samples_fast);
    const case_result_fast = bench.runner.BenchmarkCaseResult{
        .name = "computeStats.fast_path.n1024",
        .warmup_iterations = 0,
        .measure_iterations = 1,
        .samples = &input_samples_fast,
        .total_elapsed_ns = 0,
    };
    var fast_context = ComputeStatsContext{
        .case_result = case_result_fast,
    };

    var input_samples_fallback: [sample_len_fallback]bench.runner.BenchmarkSample = undefined;
    fillDeterministicSamples(&input_samples_fallback);
    const case_result_fallback = bench.runner.BenchmarkCaseResult{
        .name = "computeStats.fallback.n1025",
        .warmup_iterations = 0,
        .measure_iterations = 1,
        .samples = &input_samples_fallback,
        .total_elapsed_ns = 0,
    };
    var fallback_context = ComputeStatsContext{
        .case_result = case_result_fallback,
    };

    var scratch_storage: [sample_len_fallback]u64 = undefined;
    var scratch_context = ComputeStatsScratchContext{
        .case_result = case_result_fallback,
        .scratch = &scratch_storage,
    };

    var verify_scratch_fast: [sample_len_fast]u64 = undefined;
    try verifyComputeStatsCase(case_result_fast, &verify_scratch_fast);

    var verify_scratch_fallback: [sample_len_fallback]u64 = undefined;
    try verifyComputeStatsCase(case_result_fallback, &verify_scratch_fallback);

    var verify_scratch_with_scratch: [sample_len_fallback]u64 = undefined;
    try verifyComputeStatsWithScratchCase(case_result_fallback, &verify_scratch_with_scratch);

    var case_storage: [3]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "bench_stats",
        .config = .{
            .mode = .full,
            .warmup_iterations = 1,
            .measure_iterations = 4,
            .sample_count = 5,
        },
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = case_result_fast.name,
        .context = &fast_context,
        .run_fn = ComputeStatsContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = case_result_fallback.name,
        .context = &fallback_context,
        .run_fn = ComputeStatsContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "computeStatsWithScratch.n1025",
        .context = &scratch_context,
        .run_fn = ComputeStatsScratchContext.run,
    }));

    var bench_samples: [15]bench.runner.BenchmarkSample = undefined;
    var case_results: [3]bench.runner.BenchmarkCaseResult = undefined;
    try runBenchmarkGroup(&group, &bench_samples, &case_results);

    _ = bench.case.blackBox(fast_context.sink);
    _ = bench.case.blackBox(fallback_context.sink);
    _ = bench.case.blackBox(scratch_context.sink);
}
