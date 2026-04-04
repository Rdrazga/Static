//! Wait queue primitive for waiting on aligned 32-bit values.
//!
//! This module exposes futex-style semantics:
//! - wait only when the observed value equals `expected`
//! - tolerate spurious wakeups (caller loops)
//! - explicit timeout and cancellation inputs

const std = @import("std");
const core = @import("static_core");
const builtin = @import("builtin");
const caps = @import("caps.zig");
const cancel = @import("cancel.zig");

const platform_supports_futex = switch (builtin.os.tag) {
    .windows,
    .linux,
    .macos,
    .freebsd,
    .openbsd,
    .netbsd,
    .dragonfly,
    => true,
    else => false,
};

pub const supports_wait_queue = caps.Caps.os_backends_enabled and
    caps.Caps.threads_enabled and
    platform_supports_futex;

pub const WaitOptions = struct {
    timeout_ns: ?u64 = null,
    cancel: ?cancel.CancelToken = null,
};

pub const WaitError = error{
    Timeout,
    Cancelled,
    Unsupported,
};

const cancel_poll_ns: u64 = std.time.ns_per_ms;

comptime {
    core.errors.assertVocabularySubset(WaitError);
}

pub fn waitValue(
    comptime T: type,
    ptr: *align(@alignOf(u32)) const T,
    expected: T,
    options: WaitOptions,
) WaitError!void {
    comptime {
        std.debug.assert(@sizeOf(T) == @sizeOf(u32));
    }
    if (!supports_wait_queue) return error.Unsupported;

    if (options.cancel) |token| try token.throwIfCancelled();
    if (atomicLoadValue(T, ptr) != expected) return;

    const futex_ptr = asFutexPtr(T, ptr);
    const futex_expected: u32 = @bitCast(expected);

    if (options.timeout_ns) |timeout_ns| {
        var timeout_budget = core.time_budget.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Unsupported => return error.Unsupported,
        };
        while (atomicLoadValue(T, ptr) == expected) {
            if (options.cancel) |token| try token.throwIfCancelled();

            const remaining_ns = timeout_budget.remainingOrTimeout() catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            };
            const wait_ns = if (options.cancel != null and remaining_ns > cancel_poll_ns)
                cancel_poll_ns
            else
                remaining_ns;

            std.Thread.Futex.timedWait(futex_ptr, futex_expected, wait_ns) catch |err| switch (err) {
                error.Timeout => {
                    if (options.cancel) |token| {
                        token.throwIfCancelled() catch return error.Cancelled;
                    }
                    if (wait_ns != remaining_ns) continue;
                    if (atomicLoadValue(T, ptr) != expected) return;
                    return error.Timeout;
                },
            };
        }
        return;
    }

    while (atomicLoadValue(T, ptr) == expected) {
        if (options.cancel) |token| try token.throwIfCancelled();
        std.Thread.Futex.wait(futex_ptr, futex_expected);
    }
}

pub fn wakeValue(
    comptime T: type,
    ptr: *align(@alignOf(u32)) const T,
    max_waiters: u32,
) void {
    comptime {
        std.debug.assert(@sizeOf(T) == @sizeOf(u32));
    }
    if (!supports_wait_queue) return;
    if (max_waiters == 0) return;

    const futex_ptr = asFutexPtr(T, ptr);
    std.Thread.Futex.wake(futex_ptr, max_waiters);
}

fn asFutexPtr(comptime T: type, ptr: *align(@alignOf(u32)) const T) *const std.atomic.Value(u32) {
    return @ptrCast(ptr);
}

fn atomicLoadValue(comptime T: type, ptr: *align(@alignOf(u32)) const T) T {
    return @atomicLoad(T, ptr, .acquire);
}

fn elapsedSince(start: std.time.Instant) ?u64 {
    const now = std.time.Instant.now() catch return null;
    return now.since(start);
}

test "wait queue unsupported without os backends" {
    if (supports_wait_queue) return error.SkipZigTest;

    var state: u32 = 0;
    try std.testing.expectError(error.Unsupported, waitValue(u32, &state, 0, .{}));
    wakeValue(u32, &state, 1);
}

test "wait queue timeout semantics" {
    if (!supports_wait_queue) return error.SkipZigTest;

    var state: u32 = 0;
    try std.testing.expectError(error.Timeout, waitValue(u32, &state, 0, .{ .timeout_ns = 0 }));
    try std.testing.expectError(error.Timeout, waitValue(u32, &state, 0, .{ .timeout_ns = std.time.ns_per_ms }));
}

test "wait queue wake before wait returns immediately" {
    if (!supports_wait_queue) return error.SkipZigTest;

    var state: u32 = 0;
    @atomicStore(u32, &state, 1, .release);
    wakeValue(u32, &state, 1);
    try waitValue(u32, &state, 0, .{ .timeout_ns = std.time.ns_per_ms });
}

test "wait queue tolerates spurious wakeups" {
    if (!supports_wait_queue) return error.SkipZigTest;

    const Result = struct {
        err: ?WaitError = null,
    };

    const Worker = struct {
        state: *u32,
        result: *Result,

        fn run(self: *@This()) void {
            waitValue(u32, self.state, 0, .{ .timeout_ns = 5 * std.time.ns_per_ms }) catch |err| {
                self.result.err = err;
                return;
            };
            self.result.err = null;
        }
    };

    var state: u32 = 0;
    var result = Result{};
    var worker = Worker{
        .state = &state,
        .result = &result,
    };

    var thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    sleepBusy(std.time.ns_per_ms);
    wakeValue(u32, &state, 1);
    sleepBusy(std.time.ns_per_ms);
    wakeValue(u32, &state, 1);

    thread.join();
    try std.testing.expectEqual(@as(?WaitError, error.Timeout), result.err);
}

test "wait queue wake one then wake all" {
    if (!supports_wait_queue) return error.SkipZigTest;

    const Waiter = struct {
        state: *u32,
        ready_count: *std.atomic.Value(u32),
        done_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            _ = self.ready_count.fetchAdd(1, .acq_rel);
            while (@atomicLoad(u32, self.state, .acquire) == 0) {
                waitValue(u32, self.state, 0, .{}) catch unreachable;
            }
            _ = self.done_count.fetchAdd(1, .acq_rel);
        }
    };

    var state: u32 = 0;
    var ready_count = std.atomic.Value(u32).init(0);
    var done_count = std.atomic.Value(u32).init(0);

    var waiter_a = Waiter{
        .state = &state,
        .ready_count = &ready_count,
        .done_count = &done_count,
    };
    var waiter_b = Waiter{
        .state = &state,
        .ready_count = &ready_count,
        .done_count = &done_count,
    };

    var thread_a = try std.Thread.spawn(.{}, Waiter.run, .{&waiter_a});
    var thread_b = try std.Thread.spawn(.{}, Waiter.run, .{&waiter_b});
    defer thread_a.join();
    defer thread_b.join();

    const ready_start = std.time.Instant.now() catch return error.SkipZigTest;
    while (ready_count.load(.acquire) < 2) {
        if ((elapsedSince(ready_start) orelse std.math.maxInt(u64)) >= 100 * std.time.ns_per_ms) return error.Timeout;
        std.Thread.yield() catch {};
    }

    @atomicStore(u32, &state, 1, .release);
    wakeValue(u32, &state, 1);

    const first_start = std.time.Instant.now() catch return error.SkipZigTest;
    while (done_count.load(.acquire) == 0) {
        if ((elapsedSince(first_start) orelse std.math.maxInt(u64)) >= 100 * std.time.ns_per_ms) return error.Timeout;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(done_count.load(.acquire) >= 1);

    wakeValue(u32, &state, std.math.maxInt(u32));
    const all_start = std.time.Instant.now() catch return error.SkipZigTest;
    while (done_count.load(.acquire) < 2) {
        if ((elapsedSince(all_start) orelse std.math.maxInt(u64)) >= 100 * std.time.ns_per_ms) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

test "wait queue cancellation is cooperative and explicit" {
    if (!supports_wait_queue) return error.SkipZigTest;

    var state: u32 = 0;
    var cancel_source = cancel.CancelSource{};
    const token = cancel_source.token();

    cancel_source.cancel();
    try std.testing.expectError(error.Cancelled, waitValue(u32, &state, 0, .{ .cancel = token }));
}

test "wait queue cancellation wins over pending timeout after wait starts" {
    if (!supports_wait_queue) return error.SkipZigTest;

    const Result = struct {
        err: ?WaitError = null,
    };

    const Worker = struct {
        state: *u32,
        started: *std.atomic.Value(bool),
        finished: *std.atomic.Value(bool),
        result: *Result,
        token: cancel.CancelToken,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            waitValue(u32, self.state, 0, .{
                .timeout_ns = 5 * std.time.ns_per_s,
                .cancel = self.token,
            }) catch |err| {
                self.result.err = err;
                self.finished.store(true, .release);
                return;
            };
            self.result.err = null;
            self.finished.store(true, .release);
        }
    };

    var state: u32 = 0;
    var result = Result{};
    var started = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    var cancel_source = cancel.CancelSource{}; 
    const token = cancel_source.token();

    var worker = Worker{
        .state = &state,
        .started = &started,
        .finished = &finished,
        .result = &result,
        .token = token,
    };
    var thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer thread.join();

    const start_wait = std.time.Instant.now() catch return error.SkipZigTest;
    while (!started.load(.acquire)) {
        if ((elapsedSince(start_wait) orelse std.math.maxInt(u64)) >= 100 * std.time.ns_per_ms) return error.Timeout;
        std.Thread.yield() catch {};
    }

    sleepBusy(2 * cancel_poll_ns);
    cancel_source.cancel();

    const finish_wait = std.time.Instant.now() catch return error.SkipZigTest;
    while (!finished.load(.acquire)) {
        if ((elapsedSince(finish_wait) orelse std.math.maxInt(u64)) >= 100 * std.time.ns_per_ms) {
            @atomicStore(u32, &state, 1, .release);
            wakeValue(u32, &state, std.math.maxInt(u32));
            return error.Timeout;
        }
        std.Thread.yield() catch {};
    }

    try std.testing.expectEqual(@as(?WaitError, error.Cancelled), result.err);
}

fn sleepBusy(duration_ns: u64) void {
    const start = std.time.Instant.now() catch return;
    while ((elapsedSince(start) orelse duration_ns) < duration_ns) {
        std.Thread.yield() catch {};
    }
}
