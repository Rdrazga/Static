//! Raw benchmark execution and sample collection.

const std = @import("std");
const config_mod = @import("config.zig");
const timer_mod = @import("timer.zig");
const case_mod = @import("case.zig");
const group_mod = @import("group.zig");

/// Operating errors surfaced by in-process benchmark execution.
pub const BenchmarkRunError = error{
    InvalidConfig,
    Overflow,
    Unsupported,
    NoSpaceLeft,
};

/// One measured benchmark sample.
pub const BenchmarkSample = struct {
    elapsed_ns: u64,
    iteration_count: u32,
};

/// Raw benchmark result for one case.
pub const BenchmarkCaseResult = struct {
    name: []const u8,
    warmup_iterations: u32,
    measure_iterations: u32,
    samples: []const BenchmarkSample,
    total_elapsed_ns: u64,
};

/// Raw benchmark run result for one group execution.
pub const BenchmarkRunResult = struct {
    mode: config_mod.BenchmarkMode,
    case_results: []const BenchmarkCaseResult,
};

/// Run one in-process benchmark case into caller-provided sample storage.
pub fn runCase(
    benchmark_case: *const case_mod.BenchmarkCase,
    config: config_mod.BenchmarkConfig,
    sample_storage: []BenchmarkSample,
) BenchmarkRunError!BenchmarkCaseResult {
    try validateCaseInputs(benchmark_case, config, sample_storage);
    runWarmups(benchmark_case.*, config.warmup_iterations);

    var timer = timer_mod.MonotonicTimer.init();
    var total_elapsed_ns: u64 = 0;
    var sample_index: usize = 0;
    while (sample_index < config.sample_count) : (sample_index += 1) {
        try timer.start();
        runIterations(benchmark_case.*, config.measure_iterations);
        const elapsed_ns = try timer.stop();

        sample_storage[sample_index] = .{
            .elapsed_ns = elapsed_ns,
            .iteration_count = config.measure_iterations,
        };
        total_elapsed_ns = std.math.add(u64, total_elapsed_ns, elapsed_ns) catch {
            return error.Overflow;
        };
    }

    const result: BenchmarkCaseResult = .{
        .name = benchmark_case.name,
        .warmup_iterations = config.warmup_iterations,
        .measure_iterations = config.measure_iterations,
        .samples = sample_storage[0..config.sample_count],
        .total_elapsed_ns = total_elapsed_ns,
    };
    assertCaseResultShape(result, benchmark_case, config);
    return result;
}

/// Run all cases in a group into caller-provided sample and result storage.
pub fn runGroup(
    group: *const group_mod.BenchmarkGroup,
    sample_storage: []BenchmarkSample,
    case_result_storage: []BenchmarkCaseResult,
) BenchmarkRunError!BenchmarkRunResult {
    const cases = group.iter();
    const required_case_results = cases.len;
    const required_samples = requiredSampleSlots(cases.len, group.config.sample_count) catch {
        return error.Overflow;
    };

    if (case_result_storage.len < required_case_results) return error.NoSpaceLeft;
    if (sample_storage.len < required_samples) return error.NoSpaceLeft;

    for (cases, 0..) |*benchmark_case, case_index| {
        const sample_offset = std.math.mul(usize, case_index, group.config.sample_count) catch {
            return error.Overflow;
        };
        const sample_slice = sample_storage[sample_offset .. sample_offset + group.config.sample_count];
        case_result_storage[case_index] = try runCase(benchmark_case, group.config, sample_slice);
    }

    const result: BenchmarkRunResult = .{
        .mode = group.config.mode,
        .case_results = case_result_storage[0..required_case_results],
    };
    assertRunResultShape(result, group);
    return result;
}

fn validateCaseInputs(
    benchmark_case: *const case_mod.BenchmarkCase,
    config: config_mod.BenchmarkConfig,
    sample_storage: []BenchmarkSample,
) BenchmarkRunError!void {
    config_mod.validateConfig(config) catch |err| return switch (err) {
        error.InvalidConfig => error.InvalidConfig,
        error.Overflow => error.Overflow,
    };
    std.debug.assert(benchmark_case.name.len > 0);
    std.debug.assert(config.measure_iterations > 0);
    std.debug.assert(config.sample_count > 0);
    if (sample_storage.len < config.sample_count) return error.NoSpaceLeft;
    std.debug.assert(sample_storage.len >= config.sample_count);
}

fn runWarmups(benchmark_case: case_mod.BenchmarkCase, warmup_iterations: u32) void {
    var warmup_index: u32 = 0;
    while (warmup_index < warmup_iterations) : (warmup_index += 1) {
        benchmark_case.run();
    }
}

fn runIterations(benchmark_case: case_mod.BenchmarkCase, iteration_count: u32) void {
    std.debug.assert(iteration_count > 0);
    var iteration_index: u32 = 0;
    while (iteration_index < iteration_count) : (iteration_index += 1) {
        benchmark_case.run();
    }
}

fn requiredSampleSlots(case_count: usize, sample_count: u32) error{Overflow}!usize {
    return std.math.mul(usize, case_count, sample_count);
}

fn assertCaseResultShape(
    result: BenchmarkCaseResult,
    benchmark_case: *const case_mod.BenchmarkCase,
    config: config_mod.BenchmarkConfig,
) void {
    std.debug.assert(result.name.len > 0);
    std.debug.assert(std.mem.eql(u8, result.name, benchmark_case.name));
    std.debug.assert(result.warmup_iterations == config.warmup_iterations);
    std.debug.assert(result.measure_iterations == config.measure_iterations);
    std.debug.assert(result.samples.len == config.sample_count);

    var elapsed_sum_ns: u128 = 0;
    for (result.samples) |sample| {
        std.debug.assert(sample.iteration_count == config.measure_iterations);
        elapsed_sum_ns += sample.elapsed_ns;
    }
    std.debug.assert(elapsed_sum_ns <= std.math.maxInt(u64));
    std.debug.assert(result.total_elapsed_ns == @as(u64, @intCast(elapsed_sum_ns)));
}

fn assertRunResultShape(result: BenchmarkRunResult, group: *const group_mod.BenchmarkGroup) void {
    const cases = group.iter();

    std.debug.assert(result.case_results.len == cases.len);
    std.debug.assert(result.mode == group.config.mode);
    for (result.case_results, cases) |case_result, benchmark_case| {
        assertCaseResultShape(case_result, &benchmark_case, group.config);
    }
}

test "runCase excludes warmups from sample count and preserves call totals" {
    // Method: Count callback invocations directly so the assertion covers both
    // warmup exclusion and measured-iteration multiplication.
    var call_count: u32 = 0;
    const Context = struct {
        fn run(ctx: *anyopaque) void {
            const counter: *u32 = @ptrCast(@alignCast(ctx));
            counter.* += 1;
        }
    };
    const benchmark_case = case_mod.BenchmarkCase.init(.{
        .name = "single_case",
        .context = &call_count,
        .run_fn = Context.run,
    });
    const config = config_mod.BenchmarkConfig{
        .mode = .smoke,
        .warmup_iterations = 2,
        .measure_iterations = 3,
        .sample_count = 4,
    };
    var samples: [4]BenchmarkSample = undefined;

    const result = try runCase(&benchmark_case, config, &samples);
    const expected_calls = config.warmup_iterations + config.measure_iterations * config.sample_count;

    try std.testing.expectEqual(@as(usize, 4), result.samples.len);
    try std.testing.expectEqual(expected_calls, call_count);
}

test "runGroup preserves group order and sample allocation" {
    // Method: Execute two independent counters through one group so ordering,
    // per-case sample slicing, and callback totals are checked together.
    var first_count: u32 = 0;
    var second_count: u32 = 0;
    const Context = struct {
        fn run(ctx: *anyopaque) void {
            const counter: *u32 = @ptrCast(@alignCast(ctx));
            counter.* += 1;
        }
    };
    const first_case = case_mod.BenchmarkCase.init(.{
        .name = "first",
        .context = &first_count,
        .run_fn = Context.run,
    });
    const second_case = case_mod.BenchmarkCase.init(.{
        .name = "second",
        .context = &second_count,
        .run_fn = Context.run,
    });
    var group_storage: [2]case_mod.BenchmarkCase = undefined;
    var group = try group_mod.BenchmarkGroup.init(&group_storage, .{
        .name = "group",
        .config = config_mod.BenchmarkConfig{
            .mode = .smoke,
            .warmup_iterations = 1,
            .measure_iterations = 2,
            .sample_count = 2,
        },
    });
    try group.addCase(first_case);
    try group.addCase(second_case);

    var samples: [4]BenchmarkSample = undefined;
    var case_results: [2]BenchmarkCaseResult = undefined;
    const run_result = try runGroup(&group, &samples, &case_results);

    try std.testing.expectEqualStrings("first", run_result.case_results[0].name);
    try std.testing.expectEqualStrings("second", run_result.case_results[1].name);
    try std.testing.expectEqual(@as(u32, 5), first_count);
    try std.testing.expectEqual(@as(u32, 5), second_count);
}

test "runCase rejects invalid config and undersized sample storage" {
    // Method: Keep the benchmark callback valid while varying only config and
    // storage shape so each rejected boundary is isolated.
    var call_count: u32 = 0;
    const Context = struct {
        fn run(ctx: *anyopaque) void {
            const counter: *u32 = @ptrCast(@alignCast(ctx));
            counter.* += 1;
        }
    };
    const benchmark_case = case_mod.BenchmarkCase.init(.{
        .name = "invalid_case",
        .context = &call_count,
        .run_fn = Context.run,
    });
    var samples: [1]BenchmarkSample = undefined;

    try std.testing.expectError(error.InvalidConfig, runCase(
        &benchmark_case,
        .{
            .mode = .smoke,
            .warmup_iterations = 0,
            .measure_iterations = 0,
            .sample_count = 1,
        },
        &samples,
    ));
    try std.testing.expectError(error.NoSpaceLeft, runCase(
        &benchmark_case,
        .{
            .mode = .smoke,
            .warmup_iterations = 0,
            .measure_iterations = 1,
            .sample_count = 2,
        },
        &samples,
    ));
}

test "runGroup rejects undersized result and sample storage" {
    // Method: Reuse one valid two-case group and shrink each caller-provided
    // buffer independently so both storage contracts are pinned.
    var call_count: u32 = 0;
    const Context = struct {
        fn run(ctx: *anyopaque) void {
            const counter: *u32 = @ptrCast(@alignCast(ctx));
            counter.* += 1;
        }
    };
    const first_case = case_mod.BenchmarkCase.init(.{
        .name = "first",
        .context = &call_count,
        .run_fn = Context.run,
    });
    const second_case = case_mod.BenchmarkCase.init(.{
        .name = "second",
        .context = &call_count,
        .run_fn = Context.run,
    });
    var group_storage: [2]case_mod.BenchmarkCase = undefined;
    var group = try group_mod.BenchmarkGroup.init(&group_storage, .{
        .name = "group",
        .config = .{
            .mode = .smoke,
            .warmup_iterations = 0,
            .measure_iterations = 1,
            .sample_count = 2,
        },
    });
    try group.addCase(first_case);
    try group.addCase(second_case);

    var small_samples: [3]BenchmarkSample = undefined;
    var small_results: [1]BenchmarkCaseResult = undefined;
    var enough_samples: [4]BenchmarkSample = undefined;
    var enough_results: [2]BenchmarkCaseResult = undefined;

    try std.testing.expectError(error.NoSpaceLeft, runGroup(&group, &small_samples, &enough_results));
    try std.testing.expectError(error.NoSpaceLeft, runGroup(&group, &enough_samples, &small_results));
}
