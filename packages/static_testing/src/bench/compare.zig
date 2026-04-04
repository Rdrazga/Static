//! Benchmark statistics comparison for A/B regression checks.

const std = @import("std");
const core = @import("static_core");
const stats = @import("stats.zig");

/// Operating errors surfaced by benchmark A/B comparison.
pub const BenchmarkCompareError = error{
    InvalidInput,
    Overflow,
};

/// High-level comparison classification.
pub const ComparisonKind = enum(u8) {
    improved = 1,
    unchanged = 2,
    regressed = 3,
};

/// Comparison output for one baseline/candidate pair.
pub const ComparisonResult = struct {
    case_name: []const u8,
    baseline_median_elapsed_ns: u64,
    candidate_median_elapsed_ns: u64,
    delta_elapsed_ns: i64,
    delta_ratio_ppm: i64,
    kind: ComparisonKind,
};

/// Named inputs for comparing two derived benchmark summaries.
pub const CompareStatsOptions = struct {
    baseline: stats.BenchmarkStats,
    candidate: stats.BenchmarkStats,
    threshold_ratio_ppm: u32 = 50_000,
};

comptime {
    core.errors.assertVocabularySubset(BenchmarkCompareError);
    std.debug.assert(std.meta.fields(ComparisonKind).len == 3);
}

/// Compare two derived benchmark summaries for the same case.
pub fn compareStats(options: CompareStatsOptions) BenchmarkCompareError!ComparisonResult {
    try validateStatsSummary(options.baseline);
    try validateStatsSummary(options.candidate);
    if (!std.mem.eql(u8, options.baseline.case_name, options.candidate.case_name)) {
        return error.InvalidInput;
    }
    std.debug.assert(options.threshold_ratio_ppm <= std.math.maxInt(i64));

    const delta_elapsed_ns = try deltaElapsedNs(
        options.baseline.median_elapsed_ns,
        options.candidate.median_elapsed_ns,
    );
    const delta_ratio_ppm = try deltaRatioPpm(
        options.baseline.median_elapsed_ns,
        options.candidate.median_elapsed_ns,
    );

    return .{
        .case_name = options.baseline.case_name,
        .baseline_median_elapsed_ns = options.baseline.median_elapsed_ns,
        .candidate_median_elapsed_ns = options.candidate.median_elapsed_ns,
        .delta_elapsed_ns = delta_elapsed_ns,
        .delta_ratio_ppm = delta_ratio_ppm,
        .kind = classifyDelta(delta_ratio_ppm, options.threshold_ratio_ppm),
    };
}

fn validateStatsSummary(summary: stats.BenchmarkStats) BenchmarkCompareError!void {
    if (summary.case_name.len == 0) return error.InvalidInput;
    if (summary.sample_count == 0) return error.InvalidInput;
    if (summary.min_elapsed_ns > summary.max_elapsed_ns) return error.InvalidInput;
    if (!valueWithinClosedRange(summary.mean_elapsed_ns, summary.min_elapsed_ns, summary.max_elapsed_ns)) {
        return error.InvalidInput;
    }
    if (!valueWithinClosedRange(summary.median_elapsed_ns, summary.min_elapsed_ns, summary.max_elapsed_ns)) {
        return error.InvalidInput;
    }
    if (!valueWithinClosedRange(summary.p90_elapsed_ns, summary.min_elapsed_ns, summary.max_elapsed_ns)) {
        return error.InvalidInput;
    }
    if (!valueWithinClosedRange(summary.p95_elapsed_ns, summary.min_elapsed_ns, summary.max_elapsed_ns)) {
        return error.InvalidInput;
    }
    if (summary.p99_elapsed_ns) |p99_elapsed_ns| {
        if (!valueWithinClosedRange(p99_elapsed_ns, summary.min_elapsed_ns, summary.max_elapsed_ns)) {
            return error.InvalidInput;
        }
        if (summary.p95_elapsed_ns > p99_elapsed_ns) return error.InvalidInput;
    }
    if (summary.median_elapsed_ns > summary.p90_elapsed_ns) return error.InvalidInput;
    if (summary.p90_elapsed_ns > summary.p95_elapsed_ns) return error.InvalidInput;

    std.debug.assert(summary.case_name.len > 0);
    std.debug.assert(summary.sample_count > 0);
}

fn deltaElapsedNs(baseline_elapsed_ns: u64, candidate_elapsed_ns: u64) BenchmarkCompareError!i64 {
    const baseline_i = @as(i128, baseline_elapsed_ns);
    const candidate_i = @as(i128, candidate_elapsed_ns);
    const delta_i = candidate_i - baseline_i;
    if (delta_i < std.math.minInt(i64)) return error.Overflow;
    if (delta_i > std.math.maxInt(i64)) return error.Overflow;
    return @as(i64, @intCast(delta_i));
}

/// Return the elapsed-time delta as parts-per-million of the baseline.
///
/// A zero baseline saturates to `maxInt(i64)` for any non-zero candidate. This
/// keeps comparison total and classifies "something from nothing" as the
/// strongest possible regression without introducing a second error path.
fn deltaRatioPpm(baseline_elapsed_ns: u64, candidate_elapsed_ns: u64) BenchmarkCompareError!i64 {
    if (baseline_elapsed_ns == 0) {
        return if (candidate_elapsed_ns == 0) 0 else std.math.maxInt(i64);
    }

    const delta_i = @as(i128, candidate_elapsed_ns) - @as(i128, baseline_elapsed_ns);
    const scaled_i = std.math.mul(i128, delta_i, 1_000_000) catch return error.Overflow;
    const ratio_i = @divTrunc(scaled_i, baseline_elapsed_ns);
    if (ratio_i < std.math.minInt(i64)) return error.Overflow;
    if (ratio_i > std.math.maxInt(i64)) return error.Overflow;
    return @as(i64, @intCast(ratio_i));
}

fn classifyDelta(delta_ratio_ppm: i64, threshold_ratio_ppm: u32) ComparisonKind {
    const threshold_ratio_ppm_i: i64 = threshold_ratio_ppm;
    if (delta_ratio_ppm <= -threshold_ratio_ppm_i) return .improved;
    if (delta_ratio_ppm >= threshold_ratio_ppm_i) return .regressed;
    return .unchanged;
}

fn valueWithinClosedRange(value: u64, lo: u64, hi: u64) bool {
    return value >= lo and value <= hi;
}

test "compareStats classifies improvements and regressions by threshold" {
    // Method: Use three candidates around the threshold boundary so the test
    // covers improved, unchanged, and regressed classification in one place.
    const baseline: stats.BenchmarkStats = .{
        .case_name = "case_a",
        .sample_count = 5,
        .min_elapsed_ns = 90,
        .max_elapsed_ns = 110,
        .mean_elapsed_ns = 100,
        .median_elapsed_ns = 100,
        .p90_elapsed_ns = 110,
        .p95_elapsed_ns = 110,
    };
    const improved_candidate: stats.BenchmarkStats = .{
        .case_name = "case_a",
        .sample_count = 5,
        .min_elapsed_ns = 70,
        .max_elapsed_ns = 90,
        .mean_elapsed_ns = 80,
        .median_elapsed_ns = 80,
        .p90_elapsed_ns = 90,
        .p95_elapsed_ns = 90,
    };
    const unchanged_candidate: stats.BenchmarkStats = .{
        .case_name = "case_a",
        .sample_count = 5,
        .min_elapsed_ns = 101,
        .max_elapsed_ns = 105,
        .mean_elapsed_ns = 103,
        .median_elapsed_ns = 103,
        .p90_elapsed_ns = 105,
        .p95_elapsed_ns = 105,
    };
    const regressed_candidate: stats.BenchmarkStats = .{
        .case_name = "case_a",
        .sample_count = 5,
        .min_elapsed_ns = 140,
        .max_elapsed_ns = 160,
        .mean_elapsed_ns = 150,
        .median_elapsed_ns = 150,
        .p90_elapsed_ns = 160,
        .p95_elapsed_ns = 160,
    };

    const improved = try compareStats(.{
        .baseline = baseline,
        .candidate = improved_candidate,
    });
    const unchanged = try compareStats(.{
        .baseline = baseline,
        .candidate = unchanged_candidate,
    });
    const regressed = try compareStats(.{
        .baseline = baseline,
        .candidate = regressed_candidate,
    });

    try std.testing.expectEqual(ComparisonKind.improved, improved.kind);
    try std.testing.expectEqual(ComparisonKind.unchanged, unchanged.kind);
    try std.testing.expectEqual(ComparisonKind.regressed, regressed.kind);
}

test "compareStats rejects mismatched benchmark identities" {
    // Method: Keep the summaries otherwise identical so the failure is pinned
    // specifically on the cross-case identity mismatch.
    const baseline: stats.BenchmarkStats = .{
        .case_name = "case_a",
        .sample_count = 3,
        .min_elapsed_ns = 1,
        .max_elapsed_ns = 3,
        .mean_elapsed_ns = 2,
        .median_elapsed_ns = 2,
        .p90_elapsed_ns = 3,
        .p95_elapsed_ns = 3,
    };
    const candidate: stats.BenchmarkStats = .{
        .case_name = "case_b",
        .sample_count = 3,
        .min_elapsed_ns = 1,
        .max_elapsed_ns = 3,
        .mean_elapsed_ns = 2,
        .median_elapsed_ns = 2,
        .p90_elapsed_ns = 3,
        .p95_elapsed_ns = 3,
    };

    try std.testing.expectError(error.InvalidInput, compareStats(.{
        .baseline = baseline,
        .candidate = candidate,
    }));
}

test "compareStats rejects internally inconsistent stats summaries" {
    // Method: Corrupt one summary's ranges and another summary's sample count
    // so the comparison boundary rejects malformed derived stats early.
    const invalid_baseline: stats.BenchmarkStats = .{
        .case_name = "case_invalid",
        .sample_count = 1,
        .min_elapsed_ns = 20,
        .max_elapsed_ns = 10,
        .mean_elapsed_ns = 15,
        .median_elapsed_ns = 15,
        .p90_elapsed_ns = 15,
        .p95_elapsed_ns = 15,
    };
    const candidate: stats.BenchmarkStats = .{
        .case_name = "case_invalid",
        .sample_count = 1,
        .min_elapsed_ns = 10,
        .max_elapsed_ns = 20,
        .mean_elapsed_ns = 15,
        .median_elapsed_ns = 15,
        .p90_elapsed_ns = 18,
        .p95_elapsed_ns = 19,
    };

    try std.testing.expectError(error.InvalidInput, compareStats(.{
        .baseline = invalid_baseline,
        .candidate = candidate,
    }));

    try std.testing.expectError(error.InvalidInput, compareStats(.{
        .baseline = candidate,
        .candidate = .{
            .case_name = "case_invalid",
            .sample_count = 0,
            .min_elapsed_ns = 0,
            .max_elapsed_ns = 0,
            .mean_elapsed_ns = 0,
            .median_elapsed_ns = 0,
            .p90_elapsed_ns = 0,
            .p95_elapsed_ns = 0,
        },
    }));
}

test "compareStats saturates zero-baseline regressions" {
    // Method: Compare zero-to-zero and zero-to-nonzero medians so the total
    // baseline rule stays deterministic without a second error path.
    const zero_baseline: stats.BenchmarkStats = .{
        .case_name = "case_zero",
        .sample_count = 1,
        .min_elapsed_ns = 0,
        .max_elapsed_ns = 0,
        .mean_elapsed_ns = 0,
        .median_elapsed_ns = 0,
        .p90_elapsed_ns = 0,
        .p95_elapsed_ns = 0,
    };
    const zero_candidate = zero_baseline;
    const non_zero_candidate: stats.BenchmarkStats = .{
        .case_name = "case_zero",
        .sample_count = 1,
        .min_elapsed_ns = 5,
        .max_elapsed_ns = 5,
        .mean_elapsed_ns = 5,
        .median_elapsed_ns = 5,
        .p90_elapsed_ns = 5,
        .p95_elapsed_ns = 5,
    };

    const equal_zero = try compareStats(.{
        .baseline = zero_baseline,
        .candidate = zero_candidate,
    });
    const saturated = try compareStats(.{
        .baseline = zero_baseline,
        .candidate = non_zero_candidate,
    });

    try std.testing.expectEqual(@as(i64, 0), equal_zero.delta_ratio_ppm);
    try std.testing.expectEqual(std.math.maxInt(i64), saturated.delta_ratio_ppm);
    try std.testing.expectEqual(ComparisonKind.regressed, saturated.kind);
}

test "compareStats rejects elapsed deltas that exceed i64 range" {
    // Method: Use the widest representable unsigned median so the signed delta
    // conversion path proves its overflow guard.
    const baseline: stats.BenchmarkStats = .{
        .case_name = "case_overflow",
        .sample_count = 1,
        .min_elapsed_ns = 0,
        .max_elapsed_ns = 0,
        .mean_elapsed_ns = 0,
        .median_elapsed_ns = 0,
        .p90_elapsed_ns = 0,
        .p95_elapsed_ns = 0,
    };
    const candidate: stats.BenchmarkStats = .{
        .case_name = "case_overflow",
        .sample_count = 1,
        .min_elapsed_ns = std.math.maxInt(u64),
        .max_elapsed_ns = std.math.maxInt(u64),
        .mean_elapsed_ns = std.math.maxInt(u64),
        .median_elapsed_ns = std.math.maxInt(u64),
        .p90_elapsed_ns = std.math.maxInt(u64),
        .p95_elapsed_ns = std.math.maxInt(u64),
    };

    try std.testing.expectError(error.Overflow, compareStats(.{
        .baseline = baseline,
        .candidate = candidate,
    }));
}
