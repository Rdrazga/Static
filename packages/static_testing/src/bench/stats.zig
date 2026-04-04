//! Derived statistics over benchmark samples without heap allocation.

const std = @import("std");
const core = @import("static_core");
const runner = @import("runner.zig");

/// Maximum sample count that `computeStats()` will sort on the stack.
///
/// This is a performance fast path that avoids the O(n²) fallback selection.
/// Callers with larger sample sets should use `computeStatsWithScratch()`.
pub const stats_inline_samples_max: usize = 1024;

/// Operating errors surfaced by derived benchmark statistics.
pub const BenchmarkStatsError = error{
    InvalidInput,
    Overflow,
};

/// Derived summary statistics for one benchmark case result.
pub const BenchmarkStats = struct {
    case_name: []const u8,
    sample_count: u32,
    min_elapsed_ns: u64,
    max_elapsed_ns: u64,
    mean_elapsed_ns: u64,
    median_elapsed_ns: u64,
    p90_elapsed_ns: u64,
    p95_elapsed_ns: u64,
    p99_elapsed_ns: ?u64 = null,
};

comptime {
    core.errors.assertVocabularySubset(BenchmarkStatsError);
    std.debug.assert(stats_inline_samples_max > 0);
}

/// Derive min/max/mean/median/percentiles for one raw case result.
///
/// For sample counts up to `stats_inline_samples_max`, this uses stack scratch
/// to sort elapsed times in O(n log n). Larger sample sets fall back to the
/// allocation-free O(n²) selection path; prefer `computeStatsWithScratch()` when
/// computing percentiles for large runs.
pub fn computeStats(case_result: runner.BenchmarkCaseResult) BenchmarkStatsError!BenchmarkStats {
    if (case_result.name.len == 0) return error.InvalidInput;
    if (case_result.samples.len == 0) return error.InvalidInput;

    if (case_result.samples.len <= stats_inline_samples_max) {
        var scratch_storage: [stats_inline_samples_max]u64 = undefined;
        return computeStatsWithScratch(case_result, scratch_storage[0..case_result.samples.len]);
    }

    const min_elapsed_ns, const max_elapsed_ns = computeMinMax(case_result.samples);
    const mean_elapsed_ns = try computeMean(case_result.samples);
    const median_elapsed_ns = try percentileElapsedNs(case_result.samples, 50);
    const p90_elapsed_ns = try percentileElapsedNs(case_result.samples, 90);
    const p95_elapsed_ns = try percentileElapsedNs(case_result.samples, 95);
    const p99_elapsed_ns = try percentileElapsedNs(case_result.samples, 99);

    return .{
        .case_name = case_result.name,
        .sample_count = @as(u32, @intCast(case_result.samples.len)),
        .min_elapsed_ns = min_elapsed_ns,
        .max_elapsed_ns = max_elapsed_ns,
        .mean_elapsed_ns = mean_elapsed_ns,
        .median_elapsed_ns = median_elapsed_ns,
        .p90_elapsed_ns = p90_elapsed_ns,
        .p95_elapsed_ns = p95_elapsed_ns,
        .p99_elapsed_ns = p99_elapsed_ns,
    };
}

/// Derive benchmark stats using caller-provided scratch storage.
///
/// This is the preferred entrypoint for large sample sets because it can sort
/// in O(n log n) time without allocating.
pub fn computeStatsWithScratch(
    case_result: runner.BenchmarkCaseResult,
    elapsed_scratch: []u64,
) BenchmarkStatsError!BenchmarkStats {
    if (case_result.name.len == 0) return error.InvalidInput;
    if (case_result.samples.len == 0) return error.InvalidInput;
    if (elapsed_scratch.len < case_result.samples.len) return error.InvalidInput;

    const samples = case_result.samples;
    const elapsed_ns = elapsed_scratch[0..samples.len];

    var elapsed_sum_ns: u128 = 0;
    var min_elapsed_ns = samples[0].elapsed_ns;
    var max_elapsed_ns = samples[0].elapsed_ns;

    for (samples, 0..) |sample, index| {
        elapsed_ns[index] = sample.elapsed_ns;
        elapsed_sum_ns = std.math.add(u128, elapsed_sum_ns, sample.elapsed_ns) catch {
            return error.Overflow;
        };
        if (sample.elapsed_ns < min_elapsed_ns) min_elapsed_ns = sample.elapsed_ns;
        if (sample.elapsed_ns > max_elapsed_ns) max_elapsed_ns = sample.elapsed_ns;
    }

    std.sort.heap(u64, elapsed_ns, {}, std.sort.asc(u64));

    const mean_elapsed_ns = meanFromSum(elapsed_sum_ns, samples.len) catch |err| return switch (err) {
        error.Overflow => error.Overflow,
    };
    const median_elapsed_ns = try percentileFromSorted(elapsed_ns, 50);
    const p90_elapsed_ns = try percentileFromSorted(elapsed_ns, 90);
    const p95_elapsed_ns = try percentileFromSorted(elapsed_ns, 95);
    const p99_elapsed_ns = try percentileFromSorted(elapsed_ns, 99);

    return .{
        .case_name = case_result.name,
        .sample_count = @as(u32, @intCast(samples.len)),
        .min_elapsed_ns = min_elapsed_ns,
        .max_elapsed_ns = max_elapsed_ns,
        .mean_elapsed_ns = mean_elapsed_ns,
        .median_elapsed_ns = median_elapsed_ns,
        .p90_elapsed_ns = p90_elapsed_ns,
        .p95_elapsed_ns = p95_elapsed_ns,
        .p99_elapsed_ns = p99_elapsed_ns,
    };
}

/// Compute one percentile directly from raw sample elapsed times.
///
/// For sample counts up to `stats_inline_samples_max`, this sorts elapsed times
/// on the stack. Larger sample sets fall back to an O(n²) allocation-free nth
/// selection; callers with large sample sets should sort into scratch storage
/// and then apply the same nearest-rank percentile policy.
pub fn percentileElapsedNs(
    samples: []const runner.BenchmarkSample,
    percentile_percent: u8,
) BenchmarkStatsError!u64 {
    if (samples.len == 0) return error.InvalidInput;
    if (percentile_percent > 100) return error.InvalidInput;

    if (samples.len <= stats_inline_samples_max) {
        var scratch_storage: [stats_inline_samples_max]u64 = undefined;
        const elapsed_ns = scratch_storage[0..samples.len];
        for (samples, 0..) |sample, index| elapsed_ns[index] = sample.elapsed_ns;
        std.sort.heap(u64, elapsed_ns, {}, std.sort.asc(u64));
        return percentileFromSorted(elapsed_ns, percentile_percent);
    }

    if (percentile_percent == 0) {
        return computeMinMax(samples)[0];
    }
    if (percentile_percent == 100) {
        return computeMinMax(samples)[1];
    }

    const rank_1based = try nearestRank1Based(samples.len, percentile_percent);
    std.debug.assert(rank_1based > 0);
    std.debug.assert(rank_1based <= samples.len);

    return nthSmallestElapsedNs(samples, rank_1based - 1);
}

fn percentileFromSorted(sorted_elapsed_ns: []const u64, percentile_percent: u8) BenchmarkStatsError!u64 {
    std.debug.assert(sorted_elapsed_ns.len > 0);
    if (percentile_percent > 100) return error.InvalidInput;

    if (percentile_percent == 0) {
        return sorted_elapsed_ns[0];
    }
    if (percentile_percent == 100) {
        return sorted_elapsed_ns[sorted_elapsed_ns.len - 1];
    }

    const rank_1based = try nearestRank1Based(sorted_elapsed_ns.len, percentile_percent);
    std.debug.assert(rank_1based > 0);
    std.debug.assert(rank_1based <= sorted_elapsed_ns.len);

    return sorted_elapsed_ns[rank_1based - 1];
}

fn nearestRank1Based(sample_len: usize, percentile_percent: u8) BenchmarkStatsError!usize {
    std.debug.assert(sample_len > 0);
    std.debug.assert(percentile_percent > 0);
    std.debug.assert(percentile_percent < 100);

    const numerator = std.math.mul(usize, sample_len, percentile_percent) catch {
        return error.Overflow;
    };
    const adjusted_numerator = std.math.add(usize, numerator, 99) catch {
        return error.Overflow;
    };
    return @divFloor(adjusted_numerator, 100);
}

fn computeMean(samples: []const runner.BenchmarkSample) BenchmarkStatsError!u64 {
    var elapsed_sum_ns: u128 = 0;
    for (samples) |sample| {
        elapsed_sum_ns = std.math.add(u128, elapsed_sum_ns, sample.elapsed_ns) catch {
            return error.Overflow;
        };
    }

    return meanFromSum(elapsed_sum_ns, samples.len) catch |err| return switch (err) {
        error.Overflow => error.Overflow,
    };
}

fn meanFromSum(elapsed_sum_ns: u128, sample_len: usize) error{Overflow}!u64 {
    std.debug.assert(sample_len > 0);
    const mean_elapsed_ns = @divFloor(elapsed_sum_ns, sample_len);
    if (mean_elapsed_ns > std.math.maxInt(u64)) return error.Overflow;
    return @as(u64, @intCast(mean_elapsed_ns));
}

fn computeMinMax(samples: []const runner.BenchmarkSample) struct { u64, u64 } {
    std.debug.assert(samples.len > 0);

    var min_elapsed_ns = samples[0].elapsed_ns;
    var max_elapsed_ns = samples[0].elapsed_ns;
    for (samples[1..]) |sample| {
        if (sample.elapsed_ns < min_elapsed_ns) min_elapsed_ns = sample.elapsed_ns;
        if (sample.elapsed_ns > max_elapsed_ns) max_elapsed_ns = sample.elapsed_ns;
    }

    std.debug.assert(min_elapsed_ns <= max_elapsed_ns);
    return .{ min_elapsed_ns, max_elapsed_ns };
}

fn nthSmallestElapsedNs(samples: []const runner.BenchmarkSample, nth_index: usize) u64 {
    std.debug.assert(samples.len > 0);
    std.debug.assert(nth_index < samples.len);

    for (samples) |candidate| {
        var less_total: usize = 0;
        var equal_total: usize = 0;

        for (samples) |sample| {
            if (sample.elapsed_ns < candidate.elapsed_ns) {
                less_total += 1;
            } else if (sample.elapsed_ns == candidate.elapsed_ns) {
                equal_total += 1;
            }
        }

        if (nth_index >= less_total and nth_index < less_total + equal_total) {
            return candidate.elapsed_ns;
        }
    }

    unreachable;
}

test "computeStats returns min mean median max and percentiles" {
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 50, .iteration_count = 1 },
        .{ .elapsed_ns = 10, .iteration_count = 1 },
        .{ .elapsed_ns = 30, .iteration_count = 1 },
        .{ .elapsed_ns = 40, .iteration_count = 1 },
        .{ .elapsed_ns = 20, .iteration_count = 1 },
    };
    const case_result = runner.BenchmarkCaseResult{
        .name = "ordered_stats",
        .warmup_iterations = 0,
        .measure_iterations = 1,
        .samples = &samples,
        .total_elapsed_ns = 150,
    };

    const derived = try computeStats(case_result);

    try std.testing.expectEqual(@as(u32, 5), derived.sample_count);
    try std.testing.expectEqual(@as(u64, 10), derived.min_elapsed_ns);
    try std.testing.expectEqual(@as(u64, 50), derived.max_elapsed_ns);
    try std.testing.expectEqual(@as(u64, 30), derived.mean_elapsed_ns);
    try std.testing.expectEqual(@as(u64, 30), derived.median_elapsed_ns);
    try std.testing.expectEqual(@as(u64, 50), derived.p90_elapsed_ns);
    try std.testing.expectEqual(@as(u64, 50), derived.p95_elapsed_ns);
    try std.testing.expectEqual(@as(?u64, 50), derived.p99_elapsed_ns);
}

test "percentileElapsedNs accepts edge percentiles and rejects invalid inputs" {
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 4, .iteration_count = 1 },
        .{ .elapsed_ns = 1, .iteration_count = 1 },
        .{ .elapsed_ns = 2, .iteration_count = 1 },
        .{ .elapsed_ns = 3, .iteration_count = 1 },
    };

    try std.testing.expectEqual(@as(u64, 1), try percentileElapsedNs(&samples, 0));
    try std.testing.expectEqual(@as(u64, 4), try percentileElapsedNs(&samples, 100));
    try std.testing.expectEqual(@as(u64, 2), try percentileElapsedNs(&samples, 50));
    try std.testing.expectError(error.InvalidInput, percentileElapsedNs(&samples, 101));
    try std.testing.expectError(error.InvalidInput, percentileElapsedNs(&.{}, 50));
}

test "computeStatsWithScratch matches computeStats and rejects undersized scratch" {
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 5, .iteration_count = 1 },
        .{ .elapsed_ns = 1, .iteration_count = 1 },
        .{ .elapsed_ns = 9, .iteration_count = 1 },
        .{ .elapsed_ns = 7, .iteration_count = 1 },
    };
    const case_result = runner.BenchmarkCaseResult{
        .name = "scratch_stats",
        .warmup_iterations = 0,
        .measure_iterations = 1,
        .samples = &samples,
        .total_elapsed_ns = 22,
    };
    const derived_default = try computeStats(case_result);

    var scratch: [4]u64 = undefined;
    const derived_scratch = try computeStatsWithScratch(case_result, &scratch);

    try std.testing.expectEqual(derived_default.min_elapsed_ns, derived_scratch.min_elapsed_ns);
    try std.testing.expectEqual(derived_default.max_elapsed_ns, derived_scratch.max_elapsed_ns);
    try std.testing.expectEqual(derived_default.mean_elapsed_ns, derived_scratch.mean_elapsed_ns);
    try std.testing.expectEqual(derived_default.median_elapsed_ns, derived_scratch.median_elapsed_ns);
    try std.testing.expectEqual(derived_default.p90_elapsed_ns, derived_scratch.p90_elapsed_ns);
    try std.testing.expectEqual(derived_default.p99_elapsed_ns, derived_scratch.p99_elapsed_ns);

    var tiny: [0]u64 = .{};
    try std.testing.expectError(error.InvalidInput, computeStatsWithScratch(case_result, &tiny));
}

test "nearest-rank percentile detects adjustment overflow" {
    try std.testing.expectError(
        error.Overflow,
        nearestRank1Based(std.math.maxInt(usize), 1),
    );
}
