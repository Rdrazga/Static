//! `static_sync` uncontended fast-path benchmark.
//!
//! Scope:
//! - event signal/query/reset hot paths;
//! - semaphore post/tryWait hot path;
//! - clear-state cancellation queries; and
//! - the already-done `Once.call` fast path.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.fast_path_benchmark_config;
const benchmark_name = "fast_paths";

const CaseOp = enum {
    event_set_reset_cycle,
    event_try_wait_signaled,
    semaphore_post_try_wait_cycle,
    semaphore_try_wait_success_restore,
    cancel_is_cancelled_clear,
    cancel_throw_if_cancelled_clear,
    once_call_done_fastpath,
};

const event_set_reset_cycle_tags = &[_][]const u8{
    "static_sync",
    "event",
    "uncontended",
    "set_reset_cycle",
    "baseline",
};
const event_try_wait_signaled_tags = &[_][]const u8{
    "static_sync",
    "event",
    "uncontended",
    "try_wait_signaled",
    "baseline",
};
const semaphore_post_try_wait_cycle_tags = &[_][]const u8{
    "static_sync",
    "semaphore",
    "uncontended",
    "post_try_wait_cycle",
    "baseline",
};
const semaphore_try_wait_success_restore_tags = &[_][]const u8{
    "static_sync",
    "semaphore",
    "uncontended",
    "try_wait_success_restore",
    "baseline",
};
const cancel_is_cancelled_clear_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "uncontended",
    "is_cancelled_clear",
    "baseline",
};
const cancel_throw_if_cancelled_clear_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "uncontended",
    "throw_if_cancelled_clear",
    "baseline",
};
const once_call_done_fastpath_tags = &[_][]const u8{
    "static_sync",
    "once",
    "uncontended",
    "done_fastpath",
    "baseline",
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
    var output_dir = try support.openOutputDir(io, benchmark_name);
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
            .tags = tagsForOp(context.op),
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

    try support.writeGroupReport(
        contexts.len,
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
    var event = static_sync.event.Event{};
    event.set();
    event.tryWait() catch unreachable;
    event.reset();
    event.tryWait() catch |err| {
        assert(err == error.WouldBlock);
    };

    var semaphore = static_sync.semaphore.Semaphore{};
    semaphore.post(1);
    semaphore.tryWait() catch unreachable;
    semaphore.tryWait() catch |err| {
        assert(err == error.WouldBlock);
    };

    var cancel_source = static_sync.cancel.CancelSource{};
    const token = cancel_source.token();
    assert(!token.isCancelled());
    token.throwIfCancelled() catch unreachable;
    cancel_source.cancel();
    assert(token.isCancelled());

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

fn tagsForOp(op: CaseOp) []const []const u8 {
    return switch (op) {
        .event_set_reset_cycle => event_set_reset_cycle_tags,
        .event_try_wait_signaled => event_try_wait_signaled_tags,
        .semaphore_post_try_wait_cycle => semaphore_post_try_wait_cycle_tags,
        .semaphore_try_wait_success_restore => semaphore_try_wait_success_restore_tags,
        .cancel_is_cancelled_clear => cancel_is_cancelled_clear_tags,
        .cancel_throw_if_cancelled_clear => cancel_throw_if_cancelled_clear_tags,
        .once_call_done_fastpath => once_call_done_fastpath_tags,
    };
}

fn noop() void {}
