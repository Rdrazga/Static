//! `static_sync` benchmark references.
//!
//! Scope:
//! - uncontended host mutex lock/unlock cost as a cross-owner reference; and
//! - zero-timeout budget rejection cost as a timeout-path attribution reference.

const std = @import("std");
const assert = std.debug.assert;
const static_core = @import("static_core");
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.fast_path_benchmark_config;
const benchmark_name = "benchmark_references";

const mutex_tags = &[_][]const u8{
    "static_sync",
    "reference",
    "mutex",
    "uncontended",
    "baseline",
};
const timeout_budget_zero_tags = &[_][]const u8{
    "static_sync",
    "reference",
    "timeout_budget",
    "zero_init",
    "baseline",
};

const MutexContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *MutexContext = @ptrCast(@alignCast(context_ptr));
        var lock: static_sync.threading.Mutex = .{};
        lock.lock();
        lock.unlock();
        context.sink +%= bench.case.blackBox(@as(u64, 1));
    }
};

const TimeoutBudgetZeroContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *TimeoutBudgetZeroContext = @ptrCast(@alignCast(context_ptr));
        _ = static_core.time_budget.TimeoutBudget.init(0) catch |err| switch (err) {
            error.Timeout => {
                context.sink +%= bench.case.blackBox(@as(u64, 1));
                return;
            },
            error.Unsupported => unreachable,
        };
        unreachable;
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, benchmark_name);
    defer output_dir.close(io);

    var mutex_context = MutexContext{};
    var timeout_budget_zero_context = TimeoutBudgetZeroContext{};

    var case_storage: [2]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_sync_benchmark_references",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "mutex_lock_unlock_uncontended",
        .tags = mutex_tags,
        .context = &mutex_context,
        .run_fn = MutexContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "timeout_budget_init_zero",
        .tags = timeout_budget_zero_tags,
        .context = &timeout_budget_zero_context,
        .run_fn = TimeoutBudgetZeroContext.run,
    }));

    var sample_storage: [2 * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [2]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeGroupReport(
        2,
        benchmark_name,
        run_result,
        io,
        output_dir,
        support.fast_path_compare_config,
        .{
            .environment_note = support.default_environment_note,
            .environment_tags = support.fast_path_environment_tags,
        },
    );
}

fn validateSemanticPreflight() void {
    var mutex_context = MutexContext{};
    MutexContext.run(&mutex_context);
    assert(mutex_context.sink == 1);

    var timeout_budget_zero_context = TimeoutBudgetZeroContext{};
    TimeoutBudgetZeroContext.run(&timeout_budget_zero_context);
    assert(timeout_budget_zero_context.sink == 1);
}
