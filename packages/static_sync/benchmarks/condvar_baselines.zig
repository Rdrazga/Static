//! `static_sync` condvar contention benchmarks.
//!
//! Scope:
//! - one-waiter signal handoff cost over a fixed cycle count; and
//! - two-waiter broadcast handoff cost over a fixed cycle count.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.contention_benchmark_config;
const benchmark_name = "condvar_baselines";

const signal_handoff_count: u32 = 256;
const broadcast_handoff_count: u32 = 128;
const broadcast_waiter_count: u32 = 2;

const signal_tags = &[_][]const u8{
    "static_sync",
    "condvar",
    "contention",
    "signal",
    "baseline",
};
const broadcast_tags = &[_][]const u8{
    "static_sync",
    "condvar",
    "contention",
    "broadcast",
    "baseline",
};

const signal_stage_names = &[_][]const u8{
    "idle",
    "spawn_worker",
    "worker_wait_request",
    "main_signal_request",
    "main_wait_ack",
};

const broadcast_stage_names = &[_][]const u8{
    "idle",
    "spawn_workers",
    "worker_wait_epoch",
    "main_broadcast_epoch",
    "main_wait_arrivals",
};

const SignalContext = struct {
    watchdog: support.ContentionWatchdog = support.ContentionWatchdog.init(
        "condvar_signal_handoff_256",
        signal_stage_names,
    ),
    completed_ops: u64 = 0,

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *SignalContext = @ptrCast(@alignCast(context_ptr));
        context.watchdog.beginRun(0);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *SignalContext = @ptrCast(@alignCast(context_ptr));

        const Shared = struct {
            mutex: static_sync.threading.Mutex = .{},
            cond: static_sync.condvar.Condvar = .{},
            request_epoch: u32 = 0,
            ack_epoch: u32 = 0,
        };

        const Worker = struct {
            shared: *Shared,
            watchdog: *support.ContentionWatchdog,

            fn run(self: *@This()) void {
                var observed_request: u32 = 0;
                var handoff_index: u32 = 0;
                while (handoff_index < signal_handoff_count and !self.watchdog.didTimeout()) : (handoff_index += 1) {
                    self.shared.mutex.lock();
                    defer self.shared.mutex.unlock();

                    while (self.shared.request_epoch == observed_request and !self.watchdog.didTimeout()) {
                        self.watchdog.setStage(2);
                        self.shared.cond.timedWait(
                            &self.shared.mutex,
                            support.contention_wait_slice_ns,
                        ) catch |err| switch (err) {
                            error.Timeout => continue,
                        };
                    }
                    if (self.watchdog.didTimeout()) return;

                    observed_request = self.shared.request_epoch;
                    self.shared.ack_epoch = observed_request;
                    self.shared.cond.signal();
                    self.watchdog.noteProgress(2);
                }
            }
        };

        var shared = Shared{};
        var worker = Worker{
            .shared = &shared,
            .watchdog = &context.watchdog,
        };

        context.watchdog.setStage(1);
        var thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch unreachable;
        defer thread.join();

        var handoff_index: u32 = 0;
        while (handoff_index < signal_handoff_count) : (handoff_index += 1) {
            shared.mutex.lock();
            shared.request_epoch +%= 1;
            context.watchdog.setStage(3);
            shared.cond.signal();

            while (shared.ack_epoch != shared.request_epoch and !context.watchdog.didTimeout()) {
                context.watchdog.setStage(4);
                shared.cond.timedWait(
                    &shared.mutex,
                    support.contention_wait_slice_ns,
                ) catch |err| switch (err) {
                    error.Timeout => continue,
                };
            }
            shared.mutex.unlock();

            if (context.watchdog.didTimeout()) break;
            context.watchdog.noteProgress(4);
        }

        context.watchdog.assertHealthy();
        context.completed_ops +%= bench.case.blackBox(@as(u64, signal_handoff_count));
    }
};

const BroadcastContext = struct {
    watchdog: support.ContentionWatchdog = support.ContentionWatchdog.init(
        "condvar_broadcast_handoff_128x2",
        broadcast_stage_names,
    ),
    completed_ops: u64 = 0,

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *BroadcastContext = @ptrCast(@alignCast(context_ptr));
        context.watchdog.beginRun(0);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *BroadcastContext = @ptrCast(@alignCast(context_ptr));

        const Shared = struct {
            mutex: static_sync.threading.Mutex = .{},
            cond: static_sync.condvar.Condvar = .{},
            request_epoch: u32 = 0,
            arrived_count: u32 = 0,
        };

        const Worker = struct {
            shared: *Shared,
            watchdog: *support.ContentionWatchdog,

            fn run(self: *@This()) void {
                var observed_request: u32 = 0;
                while (observed_request < broadcast_handoff_count and !self.watchdog.didTimeout()) {
                    self.shared.mutex.lock();
                    defer self.shared.mutex.unlock();

                    while (self.shared.request_epoch == observed_request and !self.watchdog.didTimeout()) {
                        self.watchdog.setStage(2);
                        self.shared.cond.timedWait(
                            &self.shared.mutex,
                            support.contention_wait_slice_ns,
                        ) catch |err| switch (err) {
                            error.Timeout => continue,
                        };
                    }
                    if (self.watchdog.didTimeout()) return;

                    observed_request = self.shared.request_epoch;
                    self.shared.arrived_count += 1;
                    self.shared.cond.broadcast();
                    self.watchdog.noteProgress(2);
                }
            }
        };

        var shared = Shared{};
        var workers = [_]Worker{
            .{ .shared = &shared, .watchdog = &context.watchdog },
            .{ .shared = &shared, .watchdog = &context.watchdog },
        };

        context.watchdog.setStage(1);
        var thread_a = std.Thread.spawn(.{}, Worker.run, .{&workers[0]}) catch unreachable;
        defer thread_a.join();
        var thread_b = std.Thread.spawn(.{}, Worker.run, .{&workers[1]}) catch unreachable;
        defer thread_b.join();

        var handoff_index: u32 = 0;
        while (handoff_index < broadcast_handoff_count) : (handoff_index += 1) {
            shared.mutex.lock();
            shared.arrived_count = 0;
            shared.request_epoch +%= 1;
            context.watchdog.setStage(3);
            shared.cond.broadcast();

            while (shared.arrived_count != broadcast_waiter_count and !context.watchdog.didTimeout()) {
                context.watchdog.setStage(4);
                shared.cond.timedWait(
                    &shared.mutex,
                    support.contention_wait_slice_ns,
                ) catch |err| switch (err) {
                    error.Timeout => continue,
                };
            }
            shared.mutex.unlock();

            if (context.watchdog.didTimeout()) break;
            context.watchdog.noteProgress(4);
        }

        context.watchdog.assertHealthy();
        context.completed_ops +%= bench.case.blackBox(@as(u64, broadcast_handoff_count * broadcast_waiter_count));
    }
};

pub fn main() !void {
    if (!static_sync.condvar.supports_blocking_wait) {
        std.debug.print("== static_sync condvar_baselines ==\nskipped: blocking wait support unavailable\n", .{});
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

    var signal_context = SignalContext{};
    var broadcast_context = BroadcastContext{};

    var cases = [_]bench.case.BenchmarkCase{
        bench.case.BenchmarkCase.init(.{
            .name = "condvar_signal_handoff_256",
            .tags = signal_tags,
            .context = &signal_context,
            .run_fn = SignalContext.run,
            .prepare_context = &signal_context,
            .prepare_fn = SignalContext.prepare,
        }),
        bench.case.BenchmarkCase.init(.{
            .name = "condvar_broadcast_handoff_128x2",
            .tags = broadcast_tags,
            .context = &broadcast_context,
            .run_fn = BroadcastContext.run,
            .prepare_context = &broadcast_context,
            .prepare_fn = BroadcastContext.prepare,
        }),
    };

    var sample_storage: [cases.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [cases.len]bench.runner.BenchmarkCaseResult = undefined;

    signal_context.watchdog.start() catch unreachable;
    defer signal_context.watchdog.stop();
    case_result_storage[0] = try bench.runner.runCase(
        &cases[0],
        bench_config,
        sample_storage[0..bench_config.sample_count],
    );
    signal_context.watchdog.stop();
    signal_context.watchdog.assertHealthy();

    broadcast_context.watchdog.start() catch unreachable;
    defer broadcast_context.watchdog.stop();
    const broadcast_offset = bench_config.sample_count;
    case_result_storage[1] = try bench.runner.runCase(
        &cases[1],
        bench_config,
        sample_storage[broadcast_offset .. broadcast_offset + bench_config.sample_count],
    );
    broadcast_context.watchdog.stop();
    broadcast_context.watchdog.assertHealthy();

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
            .environment_tags = support.contention_environment_tags_parking,
        },
    );
}

fn validateSemanticPreflight() void {
    var signal_context = SignalContext{};
    signal_context.watchdog.start() catch unreachable;
    defer signal_context.watchdog.stop();
    signal_context.watchdog.beginRun(0);
    SignalContext.run(&signal_context);
    signal_context.watchdog.stop();
    signal_context.watchdog.assertHealthy();
    assert(signal_context.completed_ops == signal_handoff_count);

    var broadcast_context = BroadcastContext{};
    broadcast_context.watchdog.start() catch unreachable;
    defer broadcast_context.watchdog.stop();
    broadcast_context.watchdog.beginRun(0);
    BroadcastContext.run(&broadcast_context);
    broadcast_context.watchdog.stop();
    broadcast_context.watchdog.assertHealthy();
    assert(broadcast_context.completed_ops == broadcast_handoff_count * broadcast_waiter_count);
}
