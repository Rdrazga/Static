//! Demonstrates large-run derived statistics with caller-provided scratch storage.

const std = @import("std");
const testing = @import("static_testing");

const sample_count = testing.bench.stats.stats_inline_samples_max + 1;

pub fn main() !void {
    var samples: [sample_count]testing.bench.runner.BenchmarkSample = undefined;
    for (&samples, 0..) |*sample, index| {
        sample.* = .{
            .elapsed_ns = 1_000 + @as(u64, @intCast(index)),
            .iteration_count = 1,
        };
    }

    const case_result = testing.bench.runner.BenchmarkCaseResult{
        .name = "stats_with_scratch",
        .warmup_iterations = 0,
        .measure_iterations = 1,
        .samples = &samples,
        .total_elapsed_ns = 0,
    };
    var scratch: [sample_count]u64 = undefined;
    const derived = try testing.bench.stats.computeStatsWithScratch(case_result, &scratch);

    std.debug.assert(derived.sample_count == sample_count);
    std.debug.assert(derived.min_elapsed_ns == 1_000);
    std.debug.assert(derived.max_elapsed_ns == 2_024);
    std.debug.assert(derived.mean_elapsed_ns == 1_512);
    std.debug.assert(derived.median_elapsed_ns == 1_512);
    std.debug.assert(derived.p90_elapsed_ns == 1_922);
    std.debug.assert(derived.p95_elapsed_ns == 1_973);
    std.debug.print(
        "stats median_elapsed_ns={} p95_elapsed_ns={}\n",
        .{ derived.median_elapsed_ns, derived.p95_elapsed_ns },
    );
}
