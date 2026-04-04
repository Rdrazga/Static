//! `static_sync` uncontended fast-path benchmark.
//!
//! Scope:
//! - event signal/query/reset hot paths;
//! - semaphore post/tryWait hot path;
//! - clear-state cancellation queries; and
//! - the already-done `Once.call` fast path.

const std = @import("std");
const static_sync = @import("static_sync");
const static_testing = @import("static_testing");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 16,
    .measure_iterations = 8192,
    .sample_count = 8,
};

const CaseOp = enum {
    event_set_reset_cycle,
    event_try_wait_signaled,
    semaphore_post_try_wait_cycle,
    semaphore_try_wait_success_restore,
    cancel_is_cancelled_clear,
    cancel_throw_if_cancelled_clear,
    once_call_done_fastpath,
};

const FastPathContext = struct {
    name: []const u8,
    op: CaseOp,
    event: static_sync.event.Event = .{},
    semaphore: static_sync.semaphore.Semaphore = .{},
    cancel_source: static_sync.cancel.CancelSource = .{},
    once: static_sync.once.Once = .{},
    sink_bool: bool = false,

    fn run(context_ptr: *anyopaque) void {
        const context: *FastPathContext = @ptrCast(@alignCast(context_ptr));
        switch (context.op) {
            .event_set_reset_cycle => {
                context.event.set();
                context.event.tryWait() catch unreachable;
                context.event.reset();
                context.sink_bool = bench.case.blackBox(false);
            },
            .event_try_wait_signaled => {
                context.event.tryWait() catch unreachable;
                context.sink_bool = bench.case.blackBox(true);
            },
            .semaphore_post_try_wait_cycle => {
                context.semaphore.post(1);
                context.semaphore.tryWait() catch unreachable;
                context.sink_bool = bench.case.blackBox(false);
            },
            .semaphore_try_wait_success_restore => {
                context.semaphore.tryWait() catch unreachable;
                context.semaphore.post(1);
                context.sink_bool = bench.case.blackBox(true);
            },
            .cancel_is_cancelled_clear => {
                context.sink_bool = bench.case.blackBox(context.cancel_source.token().isCancelled());
            },
            .cancel_throw_if_cancelled_clear => {
                context.cancel_source.token().throwIfCancelled() catch unreachable;
                context.sink_bool = bench.case.blackBox(false);
            },
            .once_call_done_fastpath => {
                context.once.call(noop);
                context.sink_bool = bench.case.blackBox(true);
            },
        }
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();
    const output_dir_path = ".zig-cache/static_sync/benchmarks/fast_paths";
    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer output_dir.close(io);

    var contexts = [_]FastPathContext{
        .{ .name = "event_set_reset_cycle", .op = .event_set_reset_cycle },
        .{ .name = "event_try_wait_signaled", .op = .event_try_wait_signaled, .event = preSignaledEvent() },
        .{ .name = "semaphore_post_try_wait_cycle", .op = .semaphore_post_try_wait_cycle },
        .{ .name = "semaphore_try_wait_success_restore", .op = .semaphore_try_wait_success_restore, .semaphore = prePostedSemaphore() },
        .{ .name = "cancel_is_cancelled_clear", .op = .cancel_is_cancelled_clear },
        .{ .name = "cancel_throw_if_cancelled_clear", .op = .cancel_throw_if_cancelled_clear },
        .{ .name = "once_call_done_fastpath", .op = .once_call_done_fastpath, .once = preCompletedOnce() },
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_sync_fast_paths",
        .config = bench_config,
    });

    inline for (&contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_sync", "fast_path", "baseline" },
            .context = context,
            .run_fn = FastPathContext.run,
        }));
    }

    var sample_storage: [contexts.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [contexts.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_sync fast paths ==\n", .{});
    var stats_storage: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [4096]u8 = undefined;
    var read_source_buffer: [4096]u8 = undefined;
    var read_parse_buffer: [16_384]u8 = undefined;
    var comparisons: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [32_768]u8 = undefined;
    var history_record_buffer: [16_384]u8 = undefined;
    var history_frame_buffer: [16_384]u8 = undefined;
    var history_output_buffer: [32_768]u8 = undefined;
    var history_file_buffer: [32_768]u8 = undefined;
    var history_cases: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var history_names: [2048]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&aw.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .compare_config = .{
            .thresholds = .{
                .median_ratio_ppm = 250_000,
                .p95_ratio_ppm = 350_000,
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
    var event = static_sync.event.Event{};
    event.set();
    event.tryWait() catch unreachable;
    event.reset();
    event.tryWait() catch |err| {
        std.debug.assert(err == error.WouldBlock);
    };

    var semaphore = static_sync.semaphore.Semaphore{};
    semaphore.post(1);
    semaphore.tryWait() catch unreachable;
    semaphore.tryWait() catch |err| {
        std.debug.assert(err == error.WouldBlock);
    };

    var cancel_source = static_sync.cancel.CancelSource{};
    const token = cancel_source.token();
    std.debug.assert(!token.isCancelled());
    token.throwIfCancelled() catch unreachable;
    cancel_source.cancel();
    std.debug.assert(token.isCancelled());

    var once = static_sync.once.Once{};
    once.call(noop);
    once.call(noop);
}

fn preSignaledEvent() static_sync.event.Event {
    var event = static_sync.event.Event{};
    event.set();
    return event;
}

fn prePostedSemaphore() static_sync.semaphore.Semaphore {
    var semaphore = static_sync.semaphore.Semaphore{};
    semaphore.post(1);
    return semaphore;
}

fn preCompletedOnce() static_sync.once.Once {
    var once = static_sync.once.Once{};
    once.call(noop);
    return once;
}

fn noop() void {}
