//! `static_sync` timeout-path benchmarks.
//!
//! Scope:
//! - zero-budget timeout cost for event waits;
//! - zero-budget timeout cost for semaphore waits; and
//! - zero-budget timeout cost for latch waits.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.timeout_path_benchmark_config;
const benchmark_name = "timeout_path_baselines";

const event_timeout_tags = &[_][]const u8{
    "static_sync",
    "event",
    "timeout_path",
    "zero_budget",
    "baseline",
};
const semaphore_timeout_tags = &[_][]const u8{
    "static_sync",
    "semaphore",
    "timeout_path",
    "zero_budget",
    "baseline",
};
const latch_timeout_tags = &[_][]const u8{
    "static_sync",
    "latch",
    "timeout_path",
    "zero_budget",
    "baseline",
};

const EventTimeoutContext = struct {
    timeout_count: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *EventTimeoutContext = @ptrCast(@alignCast(context_ptr));
        var event = static_sync.event.Event{};
        event.timedWait(0) catch |err| switch (err) {
            error.Timeout => {
                context.timeout_count +%= bench.case.blackBox(@as(u64, 1));
                return;
            },
            error.Unsupported => unreachable,
        };
        unreachable;
    }
};

const SemaphoreTimeoutContext = struct {
    timeout_count: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SemaphoreTimeoutContext = @ptrCast(@alignCast(context_ptr));
        var semaphore = static_sync.semaphore.Semaphore{};
        semaphore.timedWait(0) catch |err| switch (err) {
            error.Timeout => {
                context.timeout_count +%= bench.case.blackBox(@as(u64, 1));
                return;
            },
            error.Unsupported => unreachable,
        };
        unreachable;
    }
};

const LatchTimeoutContext = struct {
    timeout_count: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *LatchTimeoutContext = @ptrCast(@alignCast(context_ptr));
        var latch = static_sync.barrier.Latch.init(1);
        latch.timedWait(0) catch |err| switch (err) {
            error.Timeout => {
                context.timeout_count +%= bench.case.blackBox(@as(u64, 1));
                return;
            },
            error.Unsupported => unreachable,
        };
        unreachable;
    }
};

pub fn main() !void {
    if (!static_sync.event.supports_timed_wait or
        !static_sync.semaphore.supports_timed_wait or
        !static_sync.barrier.supports_timed_wait)
    {
        std.debug.print("== static_sync timeout_path_baselines ==\nskipped: timed wait support unavailable\n", .{});
        return;
    }

    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, benchmark_name);
    defer output_dir.close(io);

    var event_timeout_context = EventTimeoutContext{};
    var semaphore_timeout_context = SemaphoreTimeoutContext{};
    var latch_timeout_context = LatchTimeoutContext{};

    var case_storage: [3]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_sync_timeout_path_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "event_timed_wait_timeout_zero",
        .tags = event_timeout_tags,
        .context = &event_timeout_context,
        .run_fn = EventTimeoutContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "semaphore_timed_wait_timeout_zero",
        .tags = semaphore_timeout_tags,
        .context = &semaphore_timeout_context,
        .run_fn = SemaphoreTimeoutContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "latch_timed_wait_timeout_zero",
        .tags = latch_timeout_tags,
        .context = &latch_timeout_context,
        .run_fn = LatchTimeoutContext.run,
    }));

    var sample_storage: [3 * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [3]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeGroupReport(
        3,
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
    var event_timeout_context = EventTimeoutContext{};
    EventTimeoutContext.run(&event_timeout_context);
    assert(event_timeout_context.timeout_count == 1);

    var semaphore_timeout_context = SemaphoreTimeoutContext{};
    SemaphoreTimeoutContext.run(&semaphore_timeout_context);
    assert(semaphore_timeout_context.timeout_count == 1);

    var latch_timeout_context = LatchTimeoutContext{};
    LatchTimeoutContext.run(&latch_timeout_context);
    assert(latch_timeout_context.timeout_count == 1);
}
