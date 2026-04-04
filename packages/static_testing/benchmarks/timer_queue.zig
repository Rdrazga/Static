//! Benchmarks the simulation timer queue wrapper against raw timer wheel usage.
//!
//! Run with:
//! - `zig build bench -Doptimize=ReleaseFast` (from `packages/static_testing`).

const std = @import("std");
const static_scheduling = @import("static_scheduling");
const static_testing = @import("static_testing");

const bench = static_testing.bench;
const sim = static_testing.testing.sim;

const buckets: u32 = 64;
const timers_max: u32 = 256;

const QueueContext = struct {
    sim_clock: *sim.clock.SimClock,
    queue: *sim.timer_queue.TimerQueue(u32),
    schedule_count: u32,
    out: []u32,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));

        var value: u32 = 0;
        while (value < context.schedule_count) : (value += 1) {
            _ = context.queue.scheduleAfter(value, .init(1)) catch |err| {
                std.debug.panic("TimerQueue.scheduleAfter failed: {s}", .{@errorName(err)});
            };
        }

        _ = context.sim_clock.advance(.init(1)) catch |err| {
            std.debug.panic("SimClock.advance failed: {s}", .{@errorName(err)});
        };
        const drained = context.queue.drainDue(context.out) catch |err| {
            std.debug.panic("TimerQueue.drainDue failed: {s}", .{@errorName(err)});
        };
        std.debug.assert(drained == context.schedule_count);

        context.sink +%= drained;
        _ = bench.case.blackBox(context.sink);
    }
};

const WheelContext = struct {
    wheel: *static_scheduling.timer_wheel.TimerWheel(u32),
    schedule_count: u32,
    out: []u32,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));

        var value: u32 = 0;
        while (value < context.schedule_count) : (value += 1) {
            _ = context.wheel.schedule(value, 0) catch |err| {
                std.debug.panic("TimerWheel.schedule failed: {s}", .{@errorName(err)});
            };
        }

        const drained = context.wheel.tick(context.out) catch |err| {
            std.debug.panic("TimerWheel.tick failed: {s}", .{@errorName(err)});
        };
        std.debug.assert(drained == context.schedule_count);

        context.sink +%= drained;
        _ = bench.case.blackBox(context.sink);
    }
};

fn expectedValueSum(schedule_count: u32) u64 {
    const count = @as(u64, schedule_count);
    return @divFloor(count * (count - 1), 2);
}

fn expectedValueXor(schedule_count: u32) u32 {
    const value_count = schedule_count & 3;
    return switch (value_count) {
        0 => 0,
        1 => schedule_count - 1,
        2 => 1,
        else => schedule_count,
    };
}

fn observeValues(values: []const u32) struct { sum: u64, xor: u32 } {
    var sum: u64 = 0;
    var xor: u32 = 0;
    for (values) |value| {
        sum += value;
        xor ^= value;
    }
    return .{ .sum = sum, .xor = xor };
}

fn assertDeliveredSchedule(values: []const u32, schedule_count: u32) void {
    const observed = observeValues(values);
    std.debug.assert(values.len == @as(usize, schedule_count));
    std.debug.assert(observed.sum == expectedValueSum(schedule_count));
    std.debug.assert(observed.xor == expectedValueXor(schedule_count));
}

fn verifyQueueBenchmarkSemantics() !void {
    var verify_storage: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&verify_storage);
    const allocator = fba.allocator();

    var sim_clock = sim.clock.SimClock.init(.init(0));
    var queue = try sim.timer_queue.TimerQueue(u32).init(allocator, &sim_clock, .{
        .buckets = buckets,
        .timers_max = timers_max,
    });
    defer queue.deinit(allocator);

    var value: u32 = 0;
    while (value < timers_max) : (value += 1) {
        _ = try queue.scheduleAfter(value, .init(1));
    }

    _ = try sim_clock.advance(.init(1));
    var out: [timers_max]u32 = undefined;
    const drained = try queue.drainDue(&out);

    assertDeliveredSchedule(out[0..@as(usize, drained)], timers_max);
    std.debug.assert(queue.nextDueTime() == null);
    std.debug.assert(queue.dueCountUpTo(sim_clock.now()) == 0);
}

fn verifyWheelBenchmarkSemantics() !void {
    var verify_storage: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&verify_storage);
    const allocator = fba.allocator();

    var wheel = try static_scheduling.timer_wheel.TimerWheel(u32).init(allocator, .{
        .buckets = buckets,
        .entries_max = timers_max,
    });
    defer wheel.deinit();

    var value: u32 = 0;
    while (value < timers_max) : (value += 1) {
        _ = try wheel.schedule(value, 0);
    }

    var out: [timers_max]u32 = undefined;
    const drained = try wheel.tick(&out);
    assertDeliveredSchedule(out[0..@as(usize, drained)], timers_max);
}

fn runBenchmarkGroup(
    group: *const bench.group.BenchmarkGroup,
    sample_storage: []bench.runner.BenchmarkSample,
    case_result_storage: []bench.runner.BenchmarkCaseResult,
    schedule_count: u32,
) !void {
    const run_result = try bench.runner.runGroup(group, sample_storage, case_result_storage);

    std.debug.print("mode: {s}\n", .{@tagName(run_result.mode)});
    for (run_result.case_results) |case_result| {
        const derived = try bench.stats.computeStats(case_result);
        const median_per_timer = @divFloor(derived.median_elapsed_ns, schedule_count);
        std.debug.print(
            "case {s} timers={d} median_elapsed_ns={d} ns_per_timer~{d}\n",
            .{
                derived.case_name,
                schedule_count,
                derived.median_elapsed_ns,
                median_per_timer,
            },
        );
    }
}

pub fn main() !void {
    try verifyQueueBenchmarkSemantics();
    try verifyWheelBenchmarkSemantics();

    var arena_storage: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_storage);
    const allocator = fba.allocator();

    var sim_clock = sim.clock.SimClock.init(.init(0));
    var queue_value = try sim.timer_queue.TimerQueue(u32).init(allocator, &sim_clock, .{
        .buckets = buckets,
        .timers_max = timers_max,
    });
    defer queue_value.deinit(allocator);

    var wheel = try static_scheduling.timer_wheel.TimerWheel(u32).init(allocator, .{
        .buckets = buckets,
        .entries_max = timers_max,
    });
    defer wheel.deinit();

    var queue_out: [timers_max]u32 = undefined;
    var wheel_out: [timers_max]u32 = undefined;

    var queue_context = QueueContext{
        .sim_clock = &sim_clock,
        .queue = &queue_value,
        .schedule_count = timers_max,
        .out = &queue_out,
    };
    var wheel_context = WheelContext{
        .wheel = &wheel,
        .schedule_count = timers_max,
        .out = &wheel_out,
    };

    var case_storage: [2]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "bench_timer_queue",
        .config = .{
            .mode = .full,
            .warmup_iterations = 1,
            .measure_iterations = 1,
            .sample_count = 5,
        },
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "timer_queue.schedule_after+drain_due",
        .context = &queue_context,
        .run_fn = QueueContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "timer_wheel.schedule+tick",
        .context = &wheel_context,
        .run_fn = WheelContext.run,
    }));

    var bench_samples: [10]bench.runner.BenchmarkSample = undefined;
    var case_results: [2]bench.runner.BenchmarkCaseResult = undefined;
    try runBenchmarkGroup(&group, &bench_samples, &case_results, timers_max);

    _ = bench.case.blackBox(queue_context.sink);
    _ = bench.case.blackBox(wheel_context.sink);
}
