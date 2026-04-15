//! `static_sync` bounded contention benchmarks.
//!
//! Scope:
//! - thread spawn/join baseline for interpretation;
//! - event ping-pong handoff cost;
//! - semaphore ping-pong handoff cost; and
//! - wait-queue ping-pong handoff cost when supported.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.contention_benchmark_config;
const benchmark_name = "contention_baselines_threads_only";
const wait_queue_benchmark_name = "contention_baselines_wait_queue";

const handoff_count: usize = 256;

const spawn_join_noop_tags = &[_][]const u8{
    "static_sync",
    "threads",
    "spawn_join",
    "baseline",
};
const event_ping_pong_tags = &[_][]const u8{
    "static_sync",
    "event",
    "contention",
    "ping_pong",
    "baseline",
};
const semaphore_ping_pong_tags = &[_][]const u8{
    "static_sync",
    "semaphore",
    "contention",
    "ping_pong",
    "baseline",
};
const wait_queue_ping_pong_tags = &[_][]const u8{
    "static_sync",
    "wait_queue",
    "contention",
    "ping_pong",
    "baseline",
};

const event_stage_names = &[_][]const u8{
    "idle",
    "spawn_worker",
    "worker_wait_request",
    "main_set_request",
    "main_wait_response",
};

const semaphore_stage_names = &[_][]const u8{
    "idle",
    "spawn_worker",
    "worker_wait_permit",
    "main_post_request",
    "main_wait_response",
};

const wait_queue_stage_names = &[_][]const u8{
    "idle",
    "spawn_worker",
    "worker_wait_request",
    "main_wake_request",
    "main_wait_response",
};

const SpawnJoinContext = struct {
    fn run(_: *anyopaque) void {
        const Worker = struct {
            fn run() void {}
        };

        var thread = std.Thread.spawn(.{}, Worker.run, .{}) catch unreachable;
        thread.join();
    }
};

const EventPingPongContext = struct {
    watchdog: support.ContentionWatchdog = support.ContentionWatchdog.init(
        "event_ping_pong_256",
        event_stage_names,
    ),
    completed_ops: u64 = 0,

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *EventPingPongContext = @ptrCast(@alignCast(context_ptr));
        context.watchdog.beginRun(0);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *EventPingPongContext = @ptrCast(@alignCast(context_ptr));

        const Worker = struct {
            request: *static_sync.event.Event,
            response: *static_sync.event.Event,
            watchdog: *support.ContentionWatchdog,

            fn run(self: *@This()) void {
                var handoff_index: usize = 0;
                while (handoff_index < handoff_count and !self.watchdog.didTimeout()) : (handoff_index += 1) {
                    self.watchdog.setStage(2);
                    while (true) {
                        self.request.timedWait(support.contention_wait_slice_ns) catch |err| switch (err) {
                            error.Timeout => {
                                if (self.watchdog.didTimeout()) return;
                                continue;
                            },
                            error.Unsupported => unreachable,
                        };
                        break;
                    }
                    self.request.reset();
                    self.response.set();
                    self.watchdog.noteProgress(2);
                }
            }
        };

        var request = static_sync.event.Event{};
        var response = static_sync.event.Event{};
        var worker = Worker{
            .request = &request,
            .response = &response,
            .watchdog = &context.watchdog,
        };

        context.watchdog.setStage(1);
        var thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch unreachable;
        defer thread.join();

        var handoff_index: usize = 0;
        while (handoff_index < handoff_count) : (handoff_index += 1) {
            response.reset();
            context.watchdog.setStage(3);
            request.set();

            context.watchdog.setStage(4);
            while (true) {
                response.timedWait(support.contention_wait_slice_ns) catch |err| switch (err) {
                    error.Timeout => {
                        if (context.watchdog.didTimeout()) break;
                        continue;
                    },
                    error.Unsupported => unreachable,
                };
                break;
            }
            if (context.watchdog.didTimeout()) break;
            context.watchdog.noteProgress(4);
        }

        context.watchdog.assertHealthy();
        context.completed_ops +%= bench.case.blackBox(@as(u64, handoff_count));
    }
};

const SemaphorePingPongContext = struct {
    watchdog: support.ContentionWatchdog = support.ContentionWatchdog.init(
        "semaphore_ping_pong_256",
        semaphore_stage_names,
    ),
    completed_ops: u64 = 0,

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *SemaphorePingPongContext = @ptrCast(@alignCast(context_ptr));
        context.watchdog.beginRun(0);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *SemaphorePingPongContext = @ptrCast(@alignCast(context_ptr));

        const Worker = struct {
            to_worker: *static_sync.semaphore.Semaphore,
            to_main: *static_sync.semaphore.Semaphore,
            watchdog: *support.ContentionWatchdog,

            fn run(self: *@This()) void {
                var handoff_index: usize = 0;
                while (handoff_index < handoff_count and !self.watchdog.didTimeout()) : (handoff_index += 1) {
                    self.watchdog.setStage(2);
                    while (true) {
                        self.to_worker.timedWait(support.contention_wait_slice_ns) catch |err| switch (err) {
                            error.Timeout => {
                                if (self.watchdog.didTimeout()) return;
                                continue;
                            },
                            error.Unsupported => unreachable,
                        };
                        break;
                    }
                    self.to_main.post(1);
                    self.watchdog.noteProgress(2);
                }
            }
        };

        var to_worker = static_sync.semaphore.Semaphore{};
        var to_main = static_sync.semaphore.Semaphore{};
        var worker = Worker{
            .to_worker = &to_worker,
            .to_main = &to_main,
            .watchdog = &context.watchdog,
        };

        context.watchdog.setStage(1);
        var thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch unreachable;
        defer thread.join();

        var handoff_index: usize = 0;
        while (handoff_index < handoff_count) : (handoff_index += 1) {
            context.watchdog.setStage(3);
            to_worker.post(1);

            context.watchdog.setStage(4);
            while (true) {
                to_main.timedWait(support.contention_wait_slice_ns) catch |err| switch (err) {
                    error.Timeout => {
                        if (context.watchdog.didTimeout()) break;
                        continue;
                    },
                    error.Unsupported => unreachable,
                };
                break;
            }
            if (context.watchdog.didTimeout()) break;
            context.watchdog.noteProgress(4);
        }

        context.watchdog.assertHealthy();
        context.completed_ops +%= bench.case.blackBox(@as(u64, handoff_count));
    }
};

const WaitQueuePingPongContext = struct {
    watchdog: support.ContentionWatchdog = support.ContentionWatchdog.init(
        "wait_queue_ping_pong_256",
        wait_queue_stage_names,
    ),
    completed_ops: u64 = 0,

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *WaitQueuePingPongContext = @ptrCast(@alignCast(context_ptr));
        context.watchdog.beginRun(0);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *WaitQueuePingPongContext = @ptrCast(@alignCast(context_ptr));

        const Worker = struct {
            request: *u32,
            response: *u32,
            watchdog: *support.ContentionWatchdog,

            fn run(self: *@This()) void {
                var handoff_index: usize = 0;
                while (handoff_index < handoff_count and !self.watchdog.didTimeout()) : (handoff_index += 1) {
                    self.watchdog.setStage(2);
                    while (@atomicLoad(u32, self.request, .acquire) == 0 and !self.watchdog.didTimeout()) {
                        static_sync.wait_queue.waitValue(u32, self.request, 0, .{
                            .timeout_ns = support.contention_wait_slice_ns,
                        }) catch |err| switch (err) {
                            error.Timeout => continue,
                            error.Cancelled => unreachable,
                            error.Unsupported => unreachable,
                        };
                    }
                    if (self.watchdog.didTimeout()) return;

                    @atomicStore(u32, self.request, 0, .release);
                    @atomicStore(u32, self.response, 1, .release);
                    static_sync.wait_queue.wakeValue(u32, self.response, 1);
                    self.watchdog.noteProgress(2);
                }
            }
        };

        var request: u32 = 0;
        var response: u32 = 0;
        var worker = Worker{
            .request = &request,
            .response = &response,
            .watchdog = &context.watchdog,
        };

        context.watchdog.setStage(1);
        var thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch unreachable;
        defer thread.join();

        var handoff_index: usize = 0;
        while (handoff_index < handoff_count) : (handoff_index += 1) {
            @atomicStore(u32, &response, 0, .release);
            @atomicStore(u32, &request, 1, .release);
            context.watchdog.setStage(3);
            static_sync.wait_queue.wakeValue(u32, &request, 1);

            context.watchdog.setStage(4);
            while (@atomicLoad(u32, &response, .acquire) == 0 and !context.watchdog.didTimeout()) {
                static_sync.wait_queue.waitValue(u32, &response, 0, .{
                    .timeout_ns = support.contention_wait_slice_ns,
                }) catch |err| switch (err) {
                    error.Timeout => continue,
                    error.Cancelled => unreachable,
                    error.Unsupported => unreachable,
                };
            }
            if (context.watchdog.didTimeout()) break;
            context.watchdog.noteProgress(4);
        }

        context.watchdog.assertHealthy();
        context.completed_ops +%= bench.case.blackBox(@as(u64, handoff_count));
    }
};

pub fn main() !void {
    if (!static_sync.event.supports_blocking_wait or !static_sync.semaphore.supports_blocking_wait) {
        std.debug.print("== static_sync contention ==\nskipped: blocking wait support unavailable\n", .{});
        return;
    }

    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    if (static_sync.wait_queue.supports_wait_queue) {
        const io = threaded_io.io();
        var output_dir = try support.openOutputDir(io, wait_queue_benchmark_name);
        defer output_dir.close(io);
        try runWithWaitQueue(io, output_dir, wait_queue_benchmark_name);
        return;
    }

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, benchmark_name);
    defer output_dir.close(io);
    try runWithoutWaitQueue(io, output_dir, benchmark_name);
}

fn runWithoutWaitQueue(io: std.Io, output_dir: std.Io.Dir, output_name: []const u8) !void {
    var spawn_join_context = SpawnJoinContext{};
    var event_context = EventPingPongContext{};
    var semaphore_context = SemaphorePingPongContext{};

    var cases = [_]bench.case.BenchmarkCase{
        bench.case.BenchmarkCase.init(.{
            .name = "thread_spawn_join_noop",
            .tags = spawn_join_noop_tags,
            .context = &spawn_join_context,
            .run_fn = SpawnJoinContext.run,
        }),
        bench.case.BenchmarkCase.init(.{
            .name = "event_ping_pong_256",
            .tags = event_ping_pong_tags,
            .context = &event_context,
            .run_fn = EventPingPongContext.run,
            .prepare_context = &event_context,
            .prepare_fn = EventPingPongContext.prepare,
        }),
        bench.case.BenchmarkCase.init(.{
            .name = "semaphore_ping_pong_256",
            .tags = semaphore_ping_pong_tags,
            .context = &semaphore_context,
            .run_fn = SemaphorePingPongContext.run,
            .prepare_context = &semaphore_context,
            .prepare_fn = SemaphorePingPongContext.prepare,
        }),
    };

    var sample_storage: [cases.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [cases.len]bench.runner.BenchmarkCaseResult = undefined;

    case_result_storage[0] = try bench.runner.runCase(
        &cases[0],
        bench_config,
        sample_storage[0..bench_config.sample_count],
    );

    event_context.watchdog.start() catch unreachable;
    defer event_context.watchdog.stop();
    case_result_storage[1] = try bench.runner.runCase(
        &cases[1],
        bench_config,
        sample_storage[bench_config.sample_count .. 2 * bench_config.sample_count],
    );
    event_context.watchdog.stop();
    event_context.watchdog.assertHealthy();

    semaphore_context.watchdog.start() catch unreachable;
    defer semaphore_context.watchdog.stop();
    case_result_storage[2] = try bench.runner.runCase(
        &cases[2],
        bench_config,
        sample_storage[2 * bench_config.sample_count .. 3 * bench_config.sample_count],
    );
    semaphore_context.watchdog.stop();
    semaphore_context.watchdog.assertHealthy();

    const run_result = bench.runner.BenchmarkRunResult{
        .mode = bench_config.mode,
        .case_results = &case_result_storage,
    };
    try support.writeGroupReport(
        cases.len,
        output_name,
        run_result,
        io,
        output_dir,
        support.contention_compare_config,
        .{
            .environment_note = support.default_environment_note,
            .environment_tags = if (static_sync.condvar.supports_blocking_wait)
                support.contention_environment_tags_parking
            else
                support.contention_environment_tags_polling_fallback,
        },
    );
}

fn runWithWaitQueue(io: std.Io, output_dir: std.Io.Dir, output_name: []const u8) !void {
    var spawn_join_context = SpawnJoinContext{};
    var event_context = EventPingPongContext{};
    var semaphore_context = SemaphorePingPongContext{};
    var wait_queue_context = WaitQueuePingPongContext{};

    var cases = [_]bench.case.BenchmarkCase{
        bench.case.BenchmarkCase.init(.{
            .name = "thread_spawn_join_noop",
            .tags = spawn_join_noop_tags,
            .context = &spawn_join_context,
            .run_fn = SpawnJoinContext.run,
        }),
        bench.case.BenchmarkCase.init(.{
            .name = "event_ping_pong_256",
            .tags = event_ping_pong_tags,
            .context = &event_context,
            .run_fn = EventPingPongContext.run,
            .prepare_context = &event_context,
            .prepare_fn = EventPingPongContext.prepare,
        }),
        bench.case.BenchmarkCase.init(.{
            .name = "semaphore_ping_pong_256",
            .tags = semaphore_ping_pong_tags,
            .context = &semaphore_context,
            .run_fn = SemaphorePingPongContext.run,
            .prepare_context = &semaphore_context,
            .prepare_fn = SemaphorePingPongContext.prepare,
        }),
        bench.case.BenchmarkCase.init(.{
            .name = "wait_queue_ping_pong_256",
            .tags = wait_queue_ping_pong_tags,
            .context = &wait_queue_context,
            .run_fn = WaitQueuePingPongContext.run,
            .prepare_context = &wait_queue_context,
            .prepare_fn = WaitQueuePingPongContext.prepare,
        }),
    };

    var sample_storage: [cases.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [cases.len]bench.runner.BenchmarkCaseResult = undefined;

    case_result_storage[0] = try bench.runner.runCase(
        &cases[0],
        bench_config,
        sample_storage[0..bench_config.sample_count],
    );

    event_context.watchdog.start() catch unreachable;
    defer event_context.watchdog.stop();
    case_result_storage[1] = try bench.runner.runCase(
        &cases[1],
        bench_config,
        sample_storage[bench_config.sample_count .. 2 * bench_config.sample_count],
    );
    event_context.watchdog.stop();
    event_context.watchdog.assertHealthy();

    semaphore_context.watchdog.start() catch unreachable;
    defer semaphore_context.watchdog.stop();
    case_result_storage[2] = try bench.runner.runCase(
        &cases[2],
        bench_config,
        sample_storage[2 * bench_config.sample_count .. 3 * bench_config.sample_count],
    );
    semaphore_context.watchdog.stop();
    semaphore_context.watchdog.assertHealthy();

    wait_queue_context.watchdog.start() catch unreachable;
    defer wait_queue_context.watchdog.stop();
    case_result_storage[3] = try bench.runner.runCase(
        &cases[3],
        bench_config,
        sample_storage[3 * bench_config.sample_count .. 4 * bench_config.sample_count],
    );
    wait_queue_context.watchdog.stop();
    wait_queue_context.watchdog.assertHealthy();

    const run_result = bench.runner.BenchmarkRunResult{
        .mode = bench_config.mode,
        .case_results = &case_result_storage,
    };
    try support.writeGroupReport(
        cases.len,
        output_name,
        run_result,
        io,
        output_dir,
        support.contention_compare_config,
        .{
            .environment_note = support.default_environment_note,
            .environment_tags = support.contention_environment_tags_with_wait_queue,
        },
    );
}

fn validateSemanticPreflight() void {
    var spawn_join_context = SpawnJoinContext{};
    SpawnJoinContext.run(&spawn_join_context);

    var event_context = EventPingPongContext{};
    event_context.watchdog.start() catch unreachable;
    defer event_context.watchdog.stop();
    event_context.watchdog.beginRun(0);
    EventPingPongContext.run(&event_context);
    event_context.watchdog.stop();
    event_context.watchdog.assertHealthy();
    assert(event_context.completed_ops == handoff_count);

    var semaphore_context = SemaphorePingPongContext{};
    semaphore_context.watchdog.start() catch unreachable;
    defer semaphore_context.watchdog.stop();
    semaphore_context.watchdog.beginRun(0);
    SemaphorePingPongContext.run(&semaphore_context);
    semaphore_context.watchdog.stop();
    semaphore_context.watchdog.assertHealthy();
    assert(semaphore_context.completed_ops == handoff_count);

    if (static_sync.wait_queue.supports_wait_queue) {
        var wait_queue_context = WaitQueuePingPongContext{};
        wait_queue_context.watchdog.start() catch unreachable;
        defer wait_queue_context.watchdog.stop();
        wait_queue_context.watchdog.beginRun(0);
        WaitQueuePingPongContext.run(&wait_queue_context);
        wait_queue_context.watchdog.stop();
        wait_queue_context.watchdog.assertHealthy();
        assert(wait_queue_context.completed_ops == handoff_count);
    }
}
