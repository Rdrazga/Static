//! Benchmark configuration and validation for bounded, deterministic runs.

const std = @import("std");
const core = @import("static_core");

/// Operating errors surfaced by benchmark-config validation.
pub const BenchmarkConfigError = error{
    InvalidConfig,
    Overflow,
};

/// High-level benchmark runtime mode.
pub const BenchmarkMode = enum(u8) {
    smoke = 1,
    full = 2,
};

/// Bounded benchmark execution counts.
pub const BenchmarkConfig = struct {
    mode: BenchmarkMode,
    warmup_iterations: u32,
    measure_iterations: u32,
    sample_count: u32,

    /// Small fast defaults for smoke validation.
    pub fn smokeDefaults() BenchmarkConfig {
        return .{
            .mode = .smoke,
            .warmup_iterations = 1,
            .measure_iterations = 4,
            .sample_count = 3,
        };
    }

    /// Larger defaults for local measurement runs.
    pub fn fullDefaults() BenchmarkConfig {
        return .{
            .mode = .full,
            .warmup_iterations = 8,
            .measure_iterations = 128,
            .sample_count = 10,
        };
    }
};

comptime {
    core.errors.assertVocabularySubset(BenchmarkConfigError);
    std.debug.assert(std.meta.fields(BenchmarkMode).len == 2);
}

/// Validate only generic boundedness and representability.
///
/// This package intentionally leaves stronger policy caps to higher-level
/// runners so the public benchmark surface can serve both smoke and larger local
/// measurement workloads.
pub fn validateConfig(config: BenchmarkConfig) BenchmarkConfigError!void {
    if (config.measure_iterations == 0) return error.InvalidConfig;
    if (config.sample_count == 0) return error.InvalidConfig;

    std.debug.assert(config.measure_iterations > 0);
    std.debug.assert(config.sample_count > 0);
    const measure_runs_total = try measureRunsTotal(config);
    std.debug.assert(measure_runs_total >= config.measure_iterations);
    std.debug.assert(measure_runs_total >= config.sample_count);
}

fn measureRunsTotal(config: BenchmarkConfig) BenchmarkConfigError!usize {
    std.debug.assert(config.measure_iterations > 0);
    std.debug.assert(config.sample_count > 0);

    return std.math.mul(usize, config.measure_iterations, config.sample_count) catch {
        return error.Overflow;
    };
}

test "benchmark config defaults are internally consistent" {
    // Method: Validate both preset constructors and compare their sample counts
    // so the shared boundedness contract stays aligned across modes.
    try validateConfig(BenchmarkConfig.smokeDefaults());
    try validateConfig(BenchmarkConfig.fullDefaults());
    try std.testing.expect(BenchmarkConfig.smokeDefaults().sample_count < BenchmarkConfig.fullDefaults().sample_count);
}

test "validateConfig rejects zero measurement counts" {
    // Method: Hit both zero-count fields independently so invalid run shapes
    // cannot pass through by coincidence.
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .mode = .smoke,
        .warmup_iterations = 0,
        .measure_iterations = 0,
        .sample_count = 1,
    }));
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .mode = .full,
        .warmup_iterations = 0,
        .measure_iterations = 1,
        .sample_count = 0,
    }));
}

test "validateConfig rejects multiplication overflow" {
    // Method: Drive the count product to the architectural boundary so the
    // validation behavior is pinned on both 32-bit and wider `usize` targets.
    const overflow_candidate = BenchmarkConfig{
        .mode = .full,
        .warmup_iterations = 0,
        .measure_iterations = std.math.maxInt(u32),
        .sample_count = std.math.maxInt(u32),
    };
    const max_product = @as(u128, std.math.maxInt(u32)) * @as(u128, std.math.maxInt(u32));

    if (@sizeOf(usize) == 4) {
        try std.testing.expectError(error.Overflow, validateConfig(overflow_candidate));
    } else {
        comptime std.debug.assert(max_product <= std.math.maxInt(usize));
        try validateConfig(overflow_candidate);
    }
}
