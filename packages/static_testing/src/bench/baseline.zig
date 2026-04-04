//! Persisted benchmark baselines and regression-gating helpers.

const std = @import("std");
const core = @import("static_core");
const artifact = @import("../artifact/root.zig");
const config = @import("config.zig");
const compare = @import("compare.zig");
const runner = @import("runner.zig");
const stats = @import("stats.zig");

pub const baseline_version: u16 = 3;

pub const BenchmarkBaselineError = error{
    InvalidInput,
    NoSpaceLeft,
    Overflow,
    CorruptData,
    Unsupported,
} || std.Io.Dir.WriteFileError || std.Io.Dir.ReadFileError || std.Io.Dir.OpenError;

pub const CasePolicy = enum(u8) {
    fail = 1,
    informational = 2,
    ignore = 3,
};

pub const BaselineThresholds = struct {
    median_ratio_ppm: u32 = 50_000,
    p95_ratio_ppm: ?u32 = null,
    p99_ratio_ppm: ?u32 = null,
};

pub const BaselineCaseOverride = struct {
    case_name: []const u8,
    thresholds: ?BaselineThresholds = null,
    regression_decision: ?CaseDecision = null,
    missing_from_candidate_policy: ?CasePolicy = null,
    new_in_candidate_policy: ?CasePolicy = null,
};

pub const BaselineCompareConfig = struct {
    thresholds: BaselineThresholds = .{},
    regression_decision: CaseDecision = .fail,
    missing_from_candidate_policy: CasePolicy = .fail,
    new_in_candidate_policy: CasePolicy = .fail,
    case_overrides: []const BaselineCaseOverride = &.{},
};

pub const BaselineArtifactView = struct {
    version: u16,
    mode: config.BenchmarkMode,
    cases: []const stats.BenchmarkStats,
};

pub const BaselineReadBuffers = struct {
    source_buffer: []u8,
    parse_buffer: []u8,
};

pub const MetricComparison = struct {
    baseline_elapsed_ns: u64,
    candidate_elapsed_ns: u64,
    delta_elapsed_ns: i64,
    delta_ratio_ppm: i64,
    kind: compare.ComparisonKind,
};

pub const CaseStatus = enum(u8) {
    compared = 1,
    missing_from_candidate = 2,
    new_in_candidate = 3,
};

pub const CaseDecision = enum(u8) {
    pass = 1,
    informational = 2,
    fail = 3,
};

pub const BaselineCaseComparison = struct {
    case_name: []const u8,
    status: CaseStatus,
    decision: CaseDecision,
    median: ?MetricComparison = null,
    p95: ?MetricComparison = null,
    p99: ?MetricComparison = null,
};

pub const BaselineCompareSummary = struct {
    passed: bool,
    comparisons: []const BaselineCaseComparison,
    passed_case_count: u32,
    informational_case_count: u32,
    failed_case_count: u32,
};

comptime {
    core.errors.assertVocabularySubset(error{
        InvalidInput,
        NoSpaceLeft,
        Overflow,
        CorruptData,
        Unsupported,
    });
    std.debug.assert(baseline_version == 3);
}

pub fn deriveStats(
    run_result: runner.BenchmarkRunResult,
    stats_storage: []stats.BenchmarkStats,
) BenchmarkBaselineError![]const stats.BenchmarkStats {
    if (stats_storage.len < run_result.case_results.len) return error.NoSpaceLeft;
    for (run_result.case_results, 0..) |case_result, index| {
        stats_storage[index] = try stats.computeStats(case_result);
    }
    return stats_storage[0..run_result.case_results.len];
}

pub fn encodeBaselineZon(
    buffer: []u8,
    baseline_artifact: BaselineArtifactView,
) BenchmarkBaselineError![]const u8 {
    try validateArtifact(baseline_artifact);
    return artifact.document.encodeZon(buffer, baseline_artifact) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.CorruptData => return error.CorruptData,
        error.Unsupported => return error.Unsupported,
        else => return err,
    };
}

pub fn decodeBaselineZon(
    zon_bytes: []const u8,
    buffers: BaselineReadBuffers,
) BenchmarkBaselineError!BaselineArtifactView {
    const decoded = artifact.document.decodeZon(BaselineArtifactView, zon_bytes, .{
        .source_buffer = buffers.source_buffer,
        .parse_buffer = buffers.parse_buffer,
    }) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.CorruptData => return error.CorruptData,
        error.Unsupported => return error.Unsupported,
        else => return err,
    };
    try validateArtifact(decoded);
    return decoded;
}

pub fn writeBaselineFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffer: []u8,
    baseline_artifact: BaselineArtifactView,
) BenchmarkBaselineError!usize {
    try validateArtifact(baseline_artifact);
    return artifact.document.writeZonFile(io, dir, sub_path, buffer, baseline_artifact) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.CorruptData => return error.CorruptData,
        error.Unsupported => return error.Unsupported,
        else => return err,
    };
}

pub fn readBaselineFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: BaselineReadBuffers,
) BenchmarkBaselineError!BaselineArtifactView {
    return artifact.document.readZonFile(BaselineArtifactView, io, dir, sub_path, .{
        .source_buffer = buffers.source_buffer,
        .parse_buffer = buffers.parse_buffer,
    }) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.CorruptData => return error.CorruptData,
        error.Unsupported => return error.Unsupported,
        else => return err,
    };
}

pub fn compareArtifactToCandidate(
    baseline_artifact: BaselineArtifactView,
    candidate_stats: []const stats.BenchmarkStats,
    compare_config: BaselineCompareConfig,
    comparison_storage: []BaselineCaseComparison,
) BenchmarkBaselineError!BaselineCompareSummary {
    try validateArtifact(baseline_artifact);
    try validateCompareConfig(compare_config);
    if (comparison_storage.len < baseline_artifact.cases.len + candidate_stats.len) return error.NoSpaceLeft;

    var written: usize = 0;
    var passed_case_count: u32 = 0;
    var informational_case_count: u32 = 0;
    var failed_case_count: u32 = 0;

    for (baseline_artifact.cases) |baseline_case| {
        const candidate_index = findCase(candidate_stats, baseline_case.case_name);
        const case_override = findCaseOverride(compare_config.case_overrides, baseline_case.case_name);
        if (candidate_index) |index| {
            const candidate_case = candidate_stats[index];
            try validateStats(candidate_case);
            comparison_storage[written] = compareMatchedCase(
                baseline_case,
                candidate_case,
                effectiveThresholds(compare_config, case_override),
                effectiveRegressionDecision(compare_config, case_override),
            ) catch |err| return err;
        } else {
            comparison_storage[written] = .{
                .case_name = baseline_case.case_name,
                .status = .missing_from_candidate,
                .decision = decisionFromPolicy(effectiveMissingPolicy(compare_config, case_override)),
            };
        }
        countDecision(
            comparison_storage[written].decision,
            &passed_case_count,
            &informational_case_count,
            &failed_case_count,
        );
        written += 1;
    }

    for (candidate_stats, 0..) |candidate_case, candidate_index| {
        try validateStats(candidate_case);
        _ = candidate_index;
        if (findCase(baseline_artifact.cases, candidate_case.case_name) != null) continue;
        const case_override = findCaseOverride(compare_config.case_overrides, candidate_case.case_name);
        comparison_storage[written] = .{
            .case_name = candidate_case.case_name,
            .status = .new_in_candidate,
            .decision = decisionFromPolicy(effectiveNewPolicy(compare_config, case_override)),
        };
        countDecision(
            comparison_storage[written].decision,
            &passed_case_count,
            &informational_case_count,
            &failed_case_count,
        );
        written += 1;
    }

    return .{
        .passed = failed_case_count == 0,
        .comparisons = comparison_storage[0..written],
        .passed_case_count = passed_case_count,
        .informational_case_count = informational_case_count,
        .failed_case_count = failed_case_count,
    };
}

pub fn writeComparisonText(
    writer: *std.Io.Writer,
    summary: BaselineCompareSummary,
) !void {
    try writer.print(
        "baseline_compare passed={} passed_cases={} informational_cases={} failed_cases={}\n",
        .{
            summary.passed,
            summary.passed_case_count,
            summary.informational_case_count,
            summary.failed_case_count,
        },
    );
    for (summary.comparisons) |comparison| {
        try writer.print(
            "case {s} status={s} decision={s}",
            .{
                comparison.case_name,
                @tagName(comparison.status),
                @tagName(comparison.decision),
            },
        );
        if (comparison.median) |median| {
            try writer.print(
                " median={s} delta_ratio_ppm={}",
                .{ @tagName(median.kind), median.delta_ratio_ppm },
            );
        }
        if (comparison.p95) |p95| {
            try writer.print(
                " p95={s} delta_ratio_ppm={}",
                .{ @tagName(p95.kind), p95.delta_ratio_ppm },
            );
        }
        if (comparison.p99) |p99| {
            try writer.print(
                " p99={s} delta_ratio_ppm={}",
                .{ @tagName(p99.kind), p99.delta_ratio_ppm },
            );
        }
        try writer.writeByte('\n');
    }
}

fn validateArtifact(baseline_artifact: BaselineArtifactView) BenchmarkBaselineError!void {
    if (!isSupportedBaselineVersion(baseline_artifact.version)) return error.InvalidInput;
    for (baseline_artifact.cases) |case_stats| {
        try validateStats(case_stats);
    }
}

fn validateCompareConfig(compare_config: BaselineCompareConfig) BenchmarkBaselineError!void {
    for (compare_config.case_overrides, 0..) |case_override, index| {
        if (case_override.case_name.len == 0) return error.InvalidInput;
        var next_index: usize = index + 1;
        while (next_index < compare_config.case_overrides.len) : (next_index += 1) {
            if (std.mem.eql(u8, case_override.case_name, compare_config.case_overrides[next_index].case_name)) {
                return error.InvalidInput;
            }
        }
    }
}

fn validateStats(case_stats: stats.BenchmarkStats) BenchmarkBaselineError!void {
    if (case_stats.case_name.len == 0) return error.InvalidInput;
    if (case_stats.sample_count == 0) return error.InvalidInput;
    if (case_stats.min_elapsed_ns > case_stats.max_elapsed_ns) return error.InvalidInput;
    if (!inClosedRange(case_stats.mean_elapsed_ns, case_stats.min_elapsed_ns, case_stats.max_elapsed_ns)) return error.InvalidInput;
    if (!inClosedRange(case_stats.median_elapsed_ns, case_stats.min_elapsed_ns, case_stats.max_elapsed_ns)) return error.InvalidInput;
    if (!inClosedRange(case_stats.p90_elapsed_ns, case_stats.min_elapsed_ns, case_stats.max_elapsed_ns)) return error.InvalidInput;
    if (!inClosedRange(case_stats.p95_elapsed_ns, case_stats.min_elapsed_ns, case_stats.max_elapsed_ns)) return error.InvalidInput;
    if (case_stats.p99_elapsed_ns) |p99_elapsed_ns| {
        if (!inClosedRange(p99_elapsed_ns, case_stats.min_elapsed_ns, case_stats.max_elapsed_ns)) return error.InvalidInput;
        if (case_stats.p95_elapsed_ns > p99_elapsed_ns) return error.InvalidInput;
    }
    if (case_stats.median_elapsed_ns > case_stats.p90_elapsed_ns) return error.InvalidInput;
    if (case_stats.p90_elapsed_ns > case_stats.p95_elapsed_ns) return error.InvalidInput;
}

fn inClosedRange(value: u64, lo: u64, hi: u64) bool {
    return value >= lo and value <= hi;
}

fn isSupportedBaselineVersion(version: u16) bool {
    return version >= 2 and version <= baseline_version;
}

fn compareMatchedCase(
    baseline_case: stats.BenchmarkStats,
    candidate_case: stats.BenchmarkStats,
    thresholds: BaselineThresholds,
    regression_decision: CaseDecision,
) BenchmarkBaselineError!BaselineCaseComparison {
    const median_cmp = try compare.compareStats(.{
        .baseline = baseline_case,
        .candidate = candidate_case,
        .threshold_ratio_ppm = thresholds.median_ratio_ppm,
    });
    const p95_cmp = if (thresholds.p95_ratio_ppm) |p95_threshold_ratio_ppm|
        try compareMetric(
            baseline_case.case_name,
            baseline_case.p95_elapsed_ns,
            candidate_case.p95_elapsed_ns,
            p95_threshold_ratio_ppm,
        )
    else
        null;
    const p99_cmp = if (thresholds.p99_ratio_ppm) |p99_threshold_ratio_ppm|
        try compareOptionalMetric(
            baseline_case.case_name,
            baseline_case.p99_elapsed_ns,
            candidate_case.p99_elapsed_ns,
            p99_threshold_ratio_ppm,
        )
    else
        null;

    const decision = decideMatchedCase(
        median_cmp.kind,
        if (p95_cmp) |p95| p95.kind else null,
        if (p99_cmp) |p99| p99.kind else null,
        regression_decision,
    );
    return .{
        .case_name = baseline_case.case_name,
        .status = .compared,
        .decision = decision,
        .median = .{
            .baseline_elapsed_ns = median_cmp.baseline_median_elapsed_ns,
            .candidate_elapsed_ns = median_cmp.candidate_median_elapsed_ns,
            .delta_elapsed_ns = median_cmp.delta_elapsed_ns,
            .delta_ratio_ppm = median_cmp.delta_ratio_ppm,
            .kind = median_cmp.kind,
        },
        .p95 = if (p95_cmp) |metric| metric else null,
        .p99 = if (p99_cmp) |metric| metric else null,
    };
}

fn decideMatchedCase(
    median_kind: compare.ComparisonKind,
    p95_kind: ?compare.ComparisonKind,
    p99_kind: ?compare.ComparisonKind,
    regression_decision: CaseDecision,
) CaseDecision {
    if (median_kind == .regressed) return regression_decision;
    if (p95_kind) |tail_kind| {
        if (tail_kind == .regressed) return regression_decision;
    }
    if (p99_kind) |tail_kind| {
        if (tail_kind == .regressed) return regression_decision;
    }
    return .pass;
}

fn effectiveThresholds(
    compare_config: BaselineCompareConfig,
    case_override: ?BaselineCaseOverride,
) BaselineThresholds {
    if (case_override) |override| {
        if (override.thresholds) |thresholds| return thresholds;
    }
    return compare_config.thresholds;
}

fn effectiveRegressionDecision(
    compare_config: BaselineCompareConfig,
    case_override: ?BaselineCaseOverride,
) CaseDecision {
    if (case_override) |override| {
        if (override.regression_decision) |decision| return decision;
    }
    return compare_config.regression_decision;
}

fn effectiveMissingPolicy(
    compare_config: BaselineCompareConfig,
    case_override: ?BaselineCaseOverride,
) CasePolicy {
    if (case_override) |override| {
        if (override.missing_from_candidate_policy) |policy| return policy;
    }
    return compare_config.missing_from_candidate_policy;
}

fn effectiveNewPolicy(
    compare_config: BaselineCompareConfig,
    case_override: ?BaselineCaseOverride,
) CasePolicy {
    if (case_override) |override| {
        if (override.new_in_candidate_policy) |policy| return policy;
    }
    return compare_config.new_in_candidate_policy;
}

fn compareMetric(
    case_name: []const u8,
    baseline_elapsed_ns: u64,
    candidate_elapsed_ns: u64,
    threshold_ratio_ppm: u32,
) BenchmarkBaselineError!MetricComparison {
    const delta_elapsed_ns = try deltaElapsedNs(baseline_elapsed_ns, candidate_elapsed_ns);
    const delta_ratio_ppm = try deltaRatioPpm(baseline_elapsed_ns, candidate_elapsed_ns);
    return .{
        .baseline_elapsed_ns = baseline_elapsed_ns,
        .candidate_elapsed_ns = candidate_elapsed_ns,
        .delta_elapsed_ns = delta_elapsed_ns,
        .delta_ratio_ppm = delta_ratio_ppm,
        .kind = classifyDelta(case_name, delta_ratio_ppm, threshold_ratio_ppm),
    };
}

fn compareOptionalMetric(
    case_name: []const u8,
    baseline_elapsed_ns: ?u64,
    candidate_elapsed_ns: ?u64,
    threshold_ratio_ppm: u32,
) BenchmarkBaselineError!?MetricComparison {
    if (baseline_elapsed_ns) |baseline_ns| {
        const candidate_ns = candidate_elapsed_ns orelse return null;
        return try compareMetric(case_name, baseline_ns, candidate_ns, threshold_ratio_ppm);
    }
    return null;
}

fn deltaElapsedNs(baseline_elapsed_ns: u64, candidate_elapsed_ns: u64) BenchmarkBaselineError!i64 {
    const delta_i = @as(i128, candidate_elapsed_ns) - @as(i128, baseline_elapsed_ns);
    if (delta_i < std.math.minInt(i64)) return error.Overflow;
    if (delta_i > std.math.maxInt(i64)) return error.Overflow;
    return @intCast(delta_i);
}

fn deltaRatioPpm(baseline_elapsed_ns: u64, candidate_elapsed_ns: u64) BenchmarkBaselineError!i64 {
    if (baseline_elapsed_ns == 0) {
        return if (candidate_elapsed_ns == 0) 0 else std.math.maxInt(i64);
    }
    const delta_i = @as(i128, candidate_elapsed_ns) - @as(i128, baseline_elapsed_ns);
    const scaled = std.math.mul(i128, delta_i, 1_000_000) catch return error.Overflow;
    const ratio = @divTrunc(scaled, baseline_elapsed_ns);
    if (ratio < std.math.minInt(i64)) return error.Overflow;
    if (ratio > std.math.maxInt(i64)) return error.Overflow;
    return @intCast(ratio);
}

fn classifyDelta(_: []const u8, delta_ratio_ppm: i64, threshold_ratio_ppm: u32) compare.ComparisonKind {
    const threshold_i: i64 = threshold_ratio_ppm;
    if (delta_ratio_ppm <= -threshold_i) return .improved;
    if (delta_ratio_ppm >= threshold_i) return .regressed;
    return .unchanged;
}

fn decisionFromPolicy(policy: CasePolicy) CaseDecision {
    return switch (policy) {
        .fail => .fail,
        .informational => .informational,
        .ignore => .pass,
    };
}

fn countDecision(
    decision: CaseDecision,
    passed_case_count: *u32,
    informational_case_count: *u32,
    failed_case_count: *u32,
) void {
    switch (decision) {
        .pass => passed_case_count.* += 1,
        .informational => informational_case_count.* += 1,
        .fail => failed_case_count.* += 1,
    }
}

fn findCase(haystack: []const stats.BenchmarkStats, name: []const u8) ?usize {
    for (haystack, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.case_name, name)) return index;
    }
    return null;
}

fn findCaseOverride(
    haystack: []const BaselineCaseOverride,
    name: []const u8,
) ?BaselineCaseOverride {
    for (haystack) |case_override| {
        if (std.mem.eql(u8, case_override.case_name, name)) return case_override;
    }
    return null;
}

test "baseline ZON round-trips escaped case names" {
    const case_stats = [_]stats.BenchmarkStats{
        .{
            .case_name = "case\"one\nnext",
            .sample_count = 3,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 20,
            .mean_elapsed_ns = 15,
            .median_elapsed_ns = 15,
            .p90_elapsed_ns = 20,
            .p95_elapsed_ns = 20,
        },
    };
    var zon_buffer: [512]u8 = undefined;
    const encoded = try encodeBaselineZon(&zon_buffer, .{
        .version = baseline_version,
        .mode = .smoke,
        .cases = &case_stats,
    });

    var source_buffer: [512]u8 = undefined;
    var parse_buffer: [4096]u8 = undefined;
    const decoded = try decodeBaselineZon(encoded, .{
        .source_buffer = &source_buffer,
        .parse_buffer = &parse_buffer,
    });

    try std.testing.expectEqual(config.BenchmarkMode.smoke, decoded.mode);
    try std.testing.expectEqual(@as(usize, 1), decoded.cases.len);
    try std.testing.expectEqualStrings("case\"one\nnext", decoded.cases[0].case_name);
    try std.testing.expectEqual(@as(?u64, null), decoded.cases[0].p99_elapsed_ns);
}

test "compareArtifactToCandidate classifies matched missing and new cases" {
    const baseline_cases = [_]stats.BenchmarkStats{
        .{
            .case_name = "fast",
            .sample_count = 3,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 12,
            .mean_elapsed_ns = 11,
            .median_elapsed_ns = 11,
            .p90_elapsed_ns = 12,
            .p95_elapsed_ns = 12,
        },
        .{
            .case_name = "gone",
            .sample_count = 3,
            .min_elapsed_ns = 20,
            .max_elapsed_ns = 22,
            .mean_elapsed_ns = 21,
            .median_elapsed_ns = 21,
            .p90_elapsed_ns = 22,
            .p95_elapsed_ns = 22,
        },
    };
    const candidate_cases = [_]stats.BenchmarkStats{
        .{
            .case_name = "fast",
            .sample_count = 3,
            .min_elapsed_ns = 30,
            .max_elapsed_ns = 32,
            .mean_elapsed_ns = 31,
            .median_elapsed_ns = 31,
            .p90_elapsed_ns = 32,
            .p95_elapsed_ns = 32,
        },
        .{
            .case_name = "new",
            .sample_count = 3,
            .min_elapsed_ns = 5,
            .max_elapsed_ns = 7,
            .mean_elapsed_ns = 6,
            .median_elapsed_ns = 6,
            .p90_elapsed_ns = 7,
            .p95_elapsed_ns = 7,
        },
    };
    var comparisons: [8]BaselineCaseComparison = undefined;
    const summary = try compareArtifactToCandidate(
        .{
            .version = baseline_version,
            .mode = .smoke,
            .cases = &baseline_cases,
        },
        &candidate_cases,
        .{
            .thresholds = .{ .median_ratio_ppm = 50_000 },
            .missing_from_candidate_policy = .informational,
            .new_in_candidate_policy = .ignore,
        },
        &comparisons,
    );

    try std.testing.expect(!summary.passed);
    try std.testing.expectEqual(@as(u32, 1), summary.failed_case_count);
    try std.testing.expectEqual(@as(u32, 1), summary.informational_case_count);
    try std.testing.expectEqual(@as(u32, 1), summary.passed_case_count);
    try std.testing.expectEqual(CaseStatus.compared, summary.comparisons[0].status);
    try std.testing.expectEqual(CaseDecision.fail, summary.comparisons[0].decision);
    try std.testing.expectEqual(CaseStatus.missing_from_candidate, summary.comparisons[1].status);
    try std.testing.expectEqual(CaseDecision.informational, summary.comparisons[1].decision);
    try std.testing.expectEqual(CaseStatus.new_in_candidate, summary.comparisons[2].status);
    try std.testing.expectEqual(CaseDecision.pass, summary.comparisons[2].decision);
}

test "compareArtifactToCandidate supports per-case thresholds and unstable-case decisions" {
    const baseline_cases = [_]stats.BenchmarkStats{
        .{
            .case_name = "wide_tolerance",
            .sample_count = 3,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 10,
            .mean_elapsed_ns = 10,
            .median_elapsed_ns = 10,
            .p90_elapsed_ns = 10,
            .p95_elapsed_ns = 10,
        },
        .{
            .case_name = "unstable_tail",
            .sample_count = 3,
            .min_elapsed_ns = 20,
            .max_elapsed_ns = 20,
            .mean_elapsed_ns = 20,
            .median_elapsed_ns = 20,
            .p90_elapsed_ns = 20,
            .p95_elapsed_ns = 20,
        },
    };
    const candidate_cases = [_]stats.BenchmarkStats{
        .{
            .case_name = "wide_tolerance",
            .sample_count = 3,
            .min_elapsed_ns = 12,
            .max_elapsed_ns = 12,
            .mean_elapsed_ns = 12,
            .median_elapsed_ns = 12,
            .p90_elapsed_ns = 12,
            .p95_elapsed_ns = 12,
        },
        .{
            .case_name = "unstable_tail",
            .sample_count = 3,
            .min_elapsed_ns = 28,
            .max_elapsed_ns = 28,
            .mean_elapsed_ns = 28,
            .median_elapsed_ns = 28,
            .p90_elapsed_ns = 28,
            .p95_elapsed_ns = 28,
        },
        .{
            .case_name = "new_case",
            .sample_count = 3,
            .min_elapsed_ns = 5,
            .max_elapsed_ns = 5,
            .mean_elapsed_ns = 5,
            .median_elapsed_ns = 5,
            .p90_elapsed_ns = 5,
            .p95_elapsed_ns = 5,
        },
    };
    const overrides = [_]BaselineCaseOverride{
        .{
            .case_name = "wide_tolerance",
            .thresholds = .{ .median_ratio_ppm = 300_000 },
        },
        .{
            .case_name = "unstable_tail",
            .regression_decision = .informational,
        },
        .{
            .case_name = "new_case",
            .new_in_candidate_policy = .informational,
        },
    };

    var comparisons: [8]BaselineCaseComparison = undefined;
    const summary = try compareArtifactToCandidate(
        .{
            .version = baseline_version,
            .mode = .smoke,
            .cases = &baseline_cases,
        },
        &candidate_cases,
        .{
            .thresholds = .{ .median_ratio_ppm = 50_000 },
            .new_in_candidate_policy = .fail,
            .case_overrides = &overrides,
        },
        &comparisons,
    );

    try std.testing.expect(summary.passed);
    try std.testing.expectEqual(@as(u32, 1), summary.passed_case_count);
    try std.testing.expectEqual(@as(u32, 2), summary.informational_case_count);
    try std.testing.expectEqual(@as(u32, 0), summary.failed_case_count);
    try std.testing.expectEqual(CaseDecision.pass, summary.comparisons[0].decision);
    try std.testing.expectEqual(CaseDecision.informational, summary.comparisons[1].decision);
    try std.testing.expectEqual(CaseDecision.informational, summary.comparisons[2].decision);
}

test "compareArtifactToCandidate can gate on optional p99 regressions" {
    const baseline_cases = [_]stats.BenchmarkStats{
        .{
            .case_name = "tail_sensitive",
            .sample_count = 8,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 20,
            .mean_elapsed_ns = 13,
            .median_elapsed_ns = 12,
            .p90_elapsed_ns = 15,
            .p95_elapsed_ns = 16,
            .p99_elapsed_ns = 16,
        },
    };
    const candidate_cases = [_]stats.BenchmarkStats{
        .{
            .case_name = "tail_sensitive",
            .sample_count = 8,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 30,
            .mean_elapsed_ns = 15,
            .median_elapsed_ns = 12,
            .p90_elapsed_ns = 15,
            .p95_elapsed_ns = 16,
            .p99_elapsed_ns = 24,
        },
    };

    var comparisons: [2]BaselineCaseComparison = undefined;
    const summary = try compareArtifactToCandidate(
        .{
            .version = baseline_version,
            .mode = .full,
            .cases = &baseline_cases,
        },
        &candidate_cases,
        .{
            .thresholds = .{
                .median_ratio_ppm = 50_000,
                .p99_ratio_ppm = 200_000,
            },
        },
        &comparisons,
    );

    try std.testing.expect(!summary.passed);
    try std.testing.expectEqual(@as(u32, 1), summary.failed_case_count);
    try std.testing.expectEqual(compare.ComparisonKind.regressed, summary.comparisons[0].p99.?.kind);
    try std.testing.expectEqual(@as(i64, 500_000), summary.comparisons[0].p99.?.delta_ratio_ppm);
}

test "compareArtifactToCandidate skips p99 gating when baseline lacks p99" {
    const baseline_cases = [_]stats.BenchmarkStats{
        .{
            .case_name = "legacy_case",
            .sample_count = 4,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 20,
            .mean_elapsed_ns = 12,
            .median_elapsed_ns = 12,
            .p90_elapsed_ns = 16,
            .p95_elapsed_ns = 16,
            .p99_elapsed_ns = null,
        },
    };
    const candidate_cases = [_]stats.BenchmarkStats{
        .{
            .case_name = "legacy_case",
            .sample_count = 4,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 25,
            .mean_elapsed_ns = 13,
            .median_elapsed_ns = 12,
            .p90_elapsed_ns = 16,
            .p95_elapsed_ns = 16,
            .p99_elapsed_ns = 25,
        },
    };

    var comparisons: [2]BaselineCaseComparison = undefined;
    const summary = try compareArtifactToCandidate(
        .{
            .version = 2,
            .mode = .full,
            .cases = &baseline_cases,
        },
        &candidate_cases,
        .{
            .thresholds = .{
                .median_ratio_ppm = 50_000,
                .p99_ratio_ppm = 100_000,
            },
        },
        &comparisons,
    );

    try std.testing.expect(summary.passed);
    try std.testing.expectEqual(@as(?MetricComparison, null), summary.comparisons[0].p99);
}

test "compareArtifactToCandidate rejects duplicate per-case overrides" {
    const overrides = [_]BaselineCaseOverride{
        .{ .case_name = "dup" },
        .{ .case_name = "dup", .regression_decision = .informational },
    };
    var comparisons: [2]BaselineCaseComparison = undefined;

    try std.testing.expectError(
        error.InvalidInput,
        compareArtifactToCandidate(
            .{
                .version = baseline_version,
                .mode = .smoke,
                .cases = &[_]stats.BenchmarkStats{},
            },
            &[_]stats.BenchmarkStats{},
            .{
                .case_overrides = &overrides,
            },
            &comparisons,
        ),
    );
}

test "deriveStats computes baseline cases from raw run results" {
    const samples_a = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 10, .iteration_count = 1 },
        .{ .elapsed_ns = 12, .iteration_count = 1 },
    };
    const samples_b = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 20, .iteration_count = 1 },
        .{ .elapsed_ns = 24, .iteration_count = 1 },
    };
    const case_results = [_]runner.BenchmarkCaseResult{
        .{
            .name = "a",
            .warmup_iterations = 0,
            .measure_iterations = 1,
            .samples = &samples_a,
            .total_elapsed_ns = 22,
        },
        .{
            .name = "b",
            .warmup_iterations = 0,
            .measure_iterations = 1,
            .samples = &samples_b,
            .total_elapsed_ns = 44,
        },
    };
    var storage: [2]stats.BenchmarkStats = undefined;
    const derived = try deriveStats(.{
        .mode = .smoke,
        .case_results = &case_results,
    }, &storage);

    try std.testing.expectEqual(@as(usize, 2), derived.len);
    try std.testing.expectEqualStrings("a", derived[0].case_name);
    try std.testing.expectEqual(@as(u64, 10), derived[0].median_elapsed_ns);
    try std.testing.expectEqualStrings("b", derived[1].case_name);
    try std.testing.expectEqual(@as(u64, 24), derived[1].p95_elapsed_ns);
    try std.testing.expectEqual(@as(?u64, 24), derived[1].p99_elapsed_ns);
}
