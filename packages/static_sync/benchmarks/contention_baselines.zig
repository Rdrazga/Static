//! `static_sync` bounded contention benchmarks.
//!
//! Scope:
//! - thread spawn/join baseline for interpretation;
//! - event ping-pong handoff cost; and
//! - semaphore and wait-queue ping-pong handoff cost.

const std = @import("std");
const static_sync = @import("static_sync");
const static_testing = @import("static_testing");

const bench = static_testing.bench;

const contention_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 4,
    .measure_iterations = 64,
    .sample_count = 6,
};

const handoff_count: usize = 256;

const CaseOp = enum {
    spawn_join_noop,
    event_ping_pong,
    semaphore_ping_pong,
    wait_queue_ping_pong,
};

const ContentionContext = struct {
    name: []const u8,
    op: CaseOp,

    fn run(context_ptr: *anyopaque) void {
        const context: *ContentionContext = @ptrCast(@alignCast(context_ptr));
        switch (context.op) {
            .spawn_join_noop => runSpawnJoinNoop(),
            .event_ping_pong => runEventPingPong(),
            .semaphore_ping_pong => runSemaphorePingPong(),
            .wait_queue_ping_pong => runWaitQueuePingPong(),
        }
    }
};

pub fn main() !void {
    if (!static_sync.event.supports_blocking_wait or !static_sync.semaphore.supports_blocking_wait) {
        std.debug.print("== static_sync contention ==\nskipped: blocking wait support unavailable\n", .{});
        return;
    }

    validateSemanticPreflight();

    if (static_sync.wait_queue.supports_wait_queue) {
        var contexts = [_]ContentionContext{
            .{ .name = "thread_spawn_join_noop", .op = .spawn_join_noop },
            .{ .name = "event_ping_pong_256", .op = .event_ping_pong },
            .{ .name = "semaphore_ping_pong_256", .op = .semaphore_ping_pong },
            .{ .name = "wait_queue_ping_pong_256", .op = .wait_queue_ping_pong },
        };
        try runContentionGroup(contexts.len, &contexts);
        return;
    }

    var contexts = [_]ContentionContext{
        .{ .name = "thread_spawn_join_noop", .op = .spawn_join_noop },
        .{ .name = "event_ping_pong_256", .op = .event_ping_pong },
        .{ .name = "semaphore_ping_pong_256", .op = .semaphore_ping_pong },
    };
    try runContentionGroup(contexts.len, &contexts);
}

fn runContentionGroup(comptime context_count: usize, contexts: *[context_count]ContentionContext) !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();
    const output_dir_path = ".zig-cache/static_sync/benchmarks/contention_baselines";
    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer output_dir.close(io);

    var case_storage: [context_count]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_sync_contention",
        .config = contention_config,
    });

    inline for (contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_sync", "contention", "baseline" },
            .context = context,
            .run_fn = ContentionContext.run,
        }));
    }

    var sample_storage: [context_count * contention_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [context_count]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_sync contention ==\n", .{});
    var stats_storage: [context_count]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [16_384]u8 = undefined;
    var read_source_buffer: [16_384]u8 = undefined;
    var read_parse_buffer: [65_536]u8 = undefined;
    var comparisons: [context_count * 2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [65_536]u8 = undefined;
    var history_record_buffer: [32_768]u8 = undefined;
    var history_frame_buffer: [32_768]u8 = undefined;
    var history_output_buffer: [65_536]u8 = undefined;
    var history_file_buffer: [65_536]u8 = undefined;
    var history_cases: [context_count]bench.stats.BenchmarkStats = undefined;
    var history_names: [4096]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [context_count * 2]bench.baseline.BaselineCaseComparison = undefined;
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&aw.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .compare_config = .{
            .thresholds = .{
                .median_ratio_ppm = 350_000,
                .p95_ratio_ppm = 500_000,
            },
            .case_overrides = &[_]bench.baseline.BaselineCaseOverride{
                .{
                    .case_name = "thread_spawn_join_noop",
                    .thresholds = .{
                        .median_ratio_ppm = 500_000,
                        .p95_ratio_ppm = 750_000,
                    },
                },
            },
        },
        .enforce_gate = false,
        .stats_storage = &stats_storage,
        .baseline_document_buffer = &baseline_document_buffer,
        .read_buffers = .{
            .source_buffer = &read_source_buffer,
            .parse_buffer = &read_parse_buffer,
        },
        .comparison_storage = &comparisons,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_sync",
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_names,
                .tag_storage = &history_tags,
            },
            .comparison_storage = &history_comparisons,
        },
    });
    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{out.items});
}

fn validateSemanticPreflight() void {
    runEventPingPong();
    runSemaphorePingPong();
    if (static_sync.wait_queue.supports_wait_queue) {
        runWaitQueuePingPong();
    }
}

fn runSpawnJoinNoop() void {
    const Worker = struct {
        fn run() void {}
    };

    var thread = std.Thread.spawn(.{}, Worker.run, .{}) catch unreachable;
    thread.join();
}

fn runEventPingPong() void {
    const Worker = struct {
        request: *static_sync.event.Event,
        response: *static_sync.event.Event,

        fn run(self: *@This()) void {
            var handoff_index: usize = 0;
            while (handoff_index < handoff_count) : (handoff_index += 1) {
                self.request.wait();
                self.request.reset();
                self.response.set();
            }
        }
    };

    var request = static_sync.event.Event{};
    var response = static_sync.event.Event{};
    var worker = Worker{
        .request = &request,
        .response = &response,
    };

    var thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch unreachable;
    defer thread.join();

    var handoff_index: usize = 0;
    while (handoff_index < handoff_count) : (handoff_index += 1) {
        response.reset();
        request.set();
        response.wait();
    }
}

fn runSemaphorePingPong() void {
    const Worker = struct {
        to_worker: *static_sync.semaphore.Semaphore,
        to_main: *static_sync.semaphore.Semaphore,

        fn run(self: *@This()) void {
            var handoff_index: usize = 0;
            while (handoff_index < handoff_count) : (handoff_index += 1) {
                self.to_worker.wait();
                self.to_main.post(1);
            }
        }
    };

    var to_worker = static_sync.semaphore.Semaphore{};
    var to_main = static_sync.semaphore.Semaphore{};
    var worker = Worker{
        .to_worker = &to_worker,
        .to_main = &to_main,
    };

    var thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch unreachable;
    defer thread.join();

    var handoff_index: usize = 0;
    while (handoff_index < handoff_count) : (handoff_index += 1) {
        to_worker.post(1);
        to_main.wait();
    }
}

fn runWaitQueuePingPong() void {
    const Worker = struct {
        request: *u32,
        response: *u32,

        fn run(self: *@This()) void {
            var handoff_index: usize = 0;
            while (handoff_index < handoff_count) : (handoff_index += 1) {
                while (@atomicLoad(u32, self.request, .acquire) == 0) {
                    static_sync.wait_queue.waitValue(u32, self.request, 0, .{}) catch unreachable;
                }
                @atomicStore(u32, self.request, 0, .release);
                @atomicStore(u32, self.response, 1, .release);
                static_sync.wait_queue.wakeValue(u32, self.response, 1);
            }
        }
    };

    var request: u32 = 0;
    var response: u32 = 0;
    var worker = Worker{
        .request = &request,
        .response = &response,
    };

    var thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch unreachable;
    defer thread.join();

    var handoff_index: usize = 0;
    while (handoff_index < handoff_count) : (handoff_index += 1) {
        @atomicStore(u32, &response, 0, .release);
        @atomicStore(u32, &request, 1, .release);
        static_sync.wait_queue.wakeValue(u32, &request, 1);

        while (@atomicLoad(u32, &response, .acquire) == 0) {
            static_sync.wait_queue.waitValue(u32, &response, 0, .{}) catch unreachable;
        }
    }
}
