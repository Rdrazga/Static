//! `static_sync` barrier wait benchmarks.
//!
//! Scope:
//! - bounded two-party `arriveAndWait()` phase handoff cost over repeated
//!   generations with watchdog-backed deadlock detection.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.contention_benchmark_config;
const benchmark_name = "barrier_wait_baselines";

const phase_count: usize = 256;

const arrive_and_wait_tags = &[_][]const u8{
    "static_sync",
    "barrier",
    "contention",
    "arrive_and_wait",
    "baseline",
};

const stage_names = &[_][]const u8{
    "idle",
    "spawn_worker",
    "worker_arrive_and_wait",
    "main_arrive_and_wait",
};

const BarrierWaitContext = struct {
    watchdog: support.ContentionWatchdog = support.ContentionWatchdog.init(
        "barrier_arrive_and_wait_2",
        stage_names,
    ),
    completed_ops: u64 = 0,

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *BarrierWaitContext = @ptrCast(@alignCast(context_ptr));
        context.watchdog.beginRun(0);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *BarrierWaitContext = @ptrCast(@alignCast(context_ptr));

        const Worker = struct {
            barrier: *static_sync.barrier.Barrier,
            watchdog: *support.ContentionWatchdog,

            fn run(self: *@This()) void {
                var phase_index: usize = 0;
                while (phase_index < phase_count and !self.watchdog.didTimeout()) : (phase_index += 1) {
                    self.watchdog.setStage(2);
                    self.barrier.arriveAndWait();
                    self.watchdog.noteProgress(2);
                }
            }
        };

        var barrier = static_sync.barrier.Barrier.init(2) catch unreachable;
        var worker = Worker{
            .barrier = &barrier,
            .watchdog = &context.watchdog,
        };

        context.watchdog.setStage(1);
        var thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch unreachable;
        defer thread.join();

        var phase_index: usize = 0;
        while (phase_index < phase_count) : (phase_index += 1) {
            context.watchdog.setStage(3);
            barrier.arriveAndWait();
            if (context.watchdog.didTimeout()) break;
            context.watchdog.noteProgress(3);
        }

        context.watchdog.assertHealthy();
        context.completed_ops +%= bench.case.blackBox(@as(u64, phase_count));
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

    var barrier_wait_context = BarrierWaitContext{};
    var cases = [_]bench.case.BenchmarkCase{
        bench.case.BenchmarkCase.init(.{
            .name = "barrier_arrive_and_wait_2",
            .tags = arrive_and_wait_tags,
            .context = &barrier_wait_context,
            .run_fn = BarrierWaitContext.run,
            .prepare_context = &barrier_wait_context,
            .prepare_fn = BarrierWaitContext.prepare,
        }),
    };

    var sample_storage: [cases.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [cases.len]bench.runner.BenchmarkCaseResult = undefined;

    barrier_wait_context.watchdog.start() catch unreachable;
    defer barrier_wait_context.watchdog.stop();
    case_result_storage[0] = try bench.runner.runCase(
        &cases[0],
        bench_config,
        sample_storage[0..bench_config.sample_count],
    );
    barrier_wait_context.watchdog.stop();
    barrier_wait_context.watchdog.assertHealthy();

    const run_result = bench.runner.BenchmarkRunResult{
        .mode = bench_config.mode,
        .case_results = &case_result_storage,
    };

    try support.writeGroupReport(
        cases.len,
        benchmark_name,
        run_result,
        io,
        output_dir,
        support.contention_compare_config,
        .{
            .environment_note = support.default_environment_note,
            .environment_tags = support.contention_environment_tags,
        },
    );
}

fn validateSemanticPreflight() void {
    var barrier_wait_context = BarrierWaitContext{};
    barrier_wait_context.watchdog.start() catch unreachable;
    defer barrier_wait_context.watchdog.stop();
    barrier_wait_context.watchdog.beginRun(0);
    BarrierWaitContext.run(&barrier_wait_context);
    barrier_wait_context.watchdog.stop();
    barrier_wait_context.watchdog.assertHealthy();
    assert(barrier_wait_context.completed_ops == phase_count);
}
