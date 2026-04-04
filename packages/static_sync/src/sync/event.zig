//! Event: manual-reset binary signal.
//!
//! Thread safety: all operations are safe for concurrent use.
//! Single-threaded mode: `wait` and `timedWait` are absent; `set`, `reset`, and
//!   `tryWait` remain available for cooperative single-threaded use.
const std = @import("std");
const core = @import("static_core");
const backoff = @import("backoff.zig");
const caps = @import("caps.zig");
const condvar = @import("condvar.zig");
const mutex = std.Thread;
const padded_atomic = @import("padded_atomic.zig");

const supports_parking_wait = condvar.supports_blocking_wait;

pub const supports_blocking_wait = caps.Caps.threads_enabled;
pub const supports_timed_wait = caps.Caps.threads_enabled;

comptime {
    std.debug.assert(!supports_parking_wait or supports_blocking_wait);
    core.errors.assertVocabularySubset(error{WouldBlock});
    core.errors.assertVocabularySubset(error{ Timeout, Unsupported });
}

/// Pure helper: evaluates whether `tryWait` should succeed given the current signal state.
///
/// Both the single-threaded and multi-threaded Event branches call this function so the
/// signaled-state check is defined once. Returns true when the event is signaled.
fn evaluateTryWait(is_signaled: bool) bool {
    // Precondition and postcondition: the return value is the signal state itself.
    std.debug.assert(is_signaled == true or is_signaled == false);
    return is_signaled;
}

/// Manual-reset event.
///
/// - `set()` marks the event signaled and keeps it signaled until `reset()`.
/// - `tryWait()` is always available.
/// - `wait()` / `timedWait()` are present only when `single_threaded=false`.
pub const Event = if (supports_blocking_wait) struct {
    // On its own cache line: polled by all waiting threads on every spin iteration.
    signaled: padded_atomic.PaddedAtomic(bool) = .{ .value = std.atomic.Value(bool).init(false) },
    wait_mutex: mutex.Mutex = .{},
    wait_condvar: if (supports_parking_wait) condvar.Condvar else void = if (supports_parking_wait) .{} else {},
    // Guarded by `wait_mutex` so tests can observe a real parked waiter.
    waiting_waiters: usize = 0,

    pub fn set(self: *Event) void {
        self.signaled.store(true, .release);
        std.debug.assert(self.signaled.load(.acquire));

        if (supports_parking_wait) {
            self.wait_mutex.lock();
            defer self.wait_mutex.unlock();
            self.wait_condvar.broadcast();
        }
    }

    pub fn reset(self: *Event) void {
        self.signaled.store(false, .release);
        std.debug.assert(!self.signaled.load(.acquire));
    }

    pub fn tryWait(self: *Event) error{WouldBlock}!void {
        const is_signaled = self.signaled.load(.acquire);
        if (!evaluateTryWait(is_signaled)) return error.WouldBlock;
        std.debug.assert(is_signaled);
    }

    pub fn wait(self: *Event) void {
        std.debug.assert(supports_blocking_wait);

        if (supports_parking_wait) {
            if (self.signaled.load(.acquire)) return;

            self.wait_mutex.lock();
            defer self.wait_mutex.unlock();

            while (!self.signaled.load(.acquire)) {
                std.debug.assert(self.waiting_waiters < std.math.maxInt(usize));
                self.waiting_waiters += 1;
                std.debug.assert(self.waiting_waiters > 0);
                defer {
                    std.debug.assert(self.waiting_waiters > 0);
                    self.waiting_waiters -= 1;
                }
                self.wait_condvar.wait(&self.wait_mutex);
            }
            std.debug.assert(self.signaled.load(.acquire));
            return;
        }

        var spin_backoff = backoff.Backoff{};
        while (!self.signaled.load(.acquire)) {
            spin_backoff.step();
        }
        std.debug.assert(self.signaled.load(.acquire));
    }

    pub fn timedWait(self: *Event, timeout_ns: u64) error{ Timeout, Unsupported }!void {
        std.debug.assert(supports_timed_wait);

        if (self.signaled.load(.acquire)) {
            std.debug.assert(self.signaled.load(.acquire));
            return;
        }
        var timeout_budget = core.time_budget.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Unsupported => return error.Unsupported,
        };
        if (supports_parking_wait) {
            self.wait_mutex.lock();
            defer self.wait_mutex.unlock();

            while (!self.signaled.load(.acquire)) {
                const remaining_ns = timeout_budget.remainingOrTimeout() catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                    error.Unsupported => return error.Unsupported,
                };
                std.debug.assert(remaining_ns > 0);
                std.debug.assert(self.waiting_waiters < std.math.maxInt(usize));
                self.waiting_waiters += 1;
                std.debug.assert(self.waiting_waiters > 0);
                defer {
                    std.debug.assert(self.waiting_waiters > 0);
                    self.waiting_waiters -= 1;
                }
                self.wait_condvar.timedWait(&self.wait_mutex, remaining_ns) catch |err| switch (err) {
                    error.Timeout => {
                        if (self.signaled.load(.acquire)) continue;
                        _ = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                            error.Timeout => return error.Timeout,
                            error.Unsupported => return error.Unsupported,
                        };
                    },
                };
            }
            std.debug.assert(self.signaled.load(.acquire));
            return;
        }

        var spin_backoff = backoff.Backoff{};
        while (!self.signaled.load(.acquire)) {
            _ = timeout_budget.remainingOrTimeout() catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            };
            spin_backoff.step();
        }
        std.debug.assert(self.signaled.load(.acquire));
    }
} else struct {
    signaled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn set(self: *Event) void {
        self.signaled.store(true, .release);
        std.debug.assert(self.signaled.load(.acquire));
    }

    pub fn reset(self: *Event) void {
        self.signaled.store(false, .release);
        std.debug.assert(!self.signaled.load(.acquire));
    }

    pub fn tryWait(self: *Event) error{WouldBlock}!void {
        const is_signaled = self.signaled.load(.acquire);
        if (!evaluateTryWait(is_signaled)) return error.WouldBlock;
        std.debug.assert(is_signaled);
    }
};

test "event blocking waits are gated by build mode" {
    // Goal: verify compile-time API shape tracks `single_threaded`.
    // Method: query declarations with `@hasDecl`.
    try std.testing.expectEqual(caps.Caps.threads_enabled, @hasDecl(Event, "wait"));
    try std.testing.expectEqual(caps.Caps.threads_enabled, @hasDecl(Event, "timedWait"));
}

test "event tryWait reports WouldBlock until set" {
    // Goal: verify `tryWait` reflects the signaled bit.
    // Method: observe before and after a call to `set`.
    var ev = Event{};
    try std.testing.expectError(error.WouldBlock, ev.tryWait());
    ev.set();
    try ev.tryWait();
}

test "event reset clears signal" {
    // Goal: verify `reset` returns the event to unsignaled.
    // Method: set, confirm waitability, then reset and recheck.
    var ev = Event{};
    ev.set();
    try ev.tryWait();
    ev.reset();
    try std.testing.expectError(error.WouldBlock, ev.tryWait());
}

test "event set is idempotent" {
    // Goal: verify repeated `set` calls preserve the signaled state.
    // Method: call `set` twice and ensure `tryWait` still succeeds.
    var ev = Event{};
    ev.set();
    ev.set();
    try ev.tryWait();
}

test "event timedWait reports Timeout when unset" {
    // Goal: verify timeout behavior on an unsignaled event.
    // Method: test both zero timeout and a positive timeout.
    if (!supports_timed_wait) return error.SkipZigTest;

    var ev = Event{};
    try std.testing.expectError(error.Timeout, ev.timedWait(0));
    try std.testing.expectError(error.Timeout, ev.timedWait(std.time.ns_per_ms));
}

test "event timedWait succeeds immediately when already signaled" {
    // Goal: verify signaled state takes precedence over timeout budget.
    // Method: signal first, then call `timedWait` with a zero timeout.
    if (!supports_timed_wait) return error.SkipZigTest;

    var ev = Event{};
    ev.set();
    try ev.timedWait(0);
}

test "event wait unblocks after set from another thread" {
    // Goal: verify `wait` stays blocked until `set` runs.
    // Method: wait for the waiter to park, then signal and join.
    if (!supports_blocking_wait or !supports_parking_wait) return error.SkipZigTest;

    const Context = struct {
        event: *Event,

        fn run(ctx: *@This()) void {
            ctx.event.wait();
        }
    };

    var ev = Event{};
    var ctx = Context{ .event = &ev };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});

    try waitForParkedWaiter(&ev, 100 * std.time.ns_per_ms);
    std.debug.assert(!ev.signaled.load(.acquire));
    ev.set();
    thread.join();
    try ev.tryWait();
}

test "event timedWait unblocks after set from another thread" {
    // Goal: verify `timedWait` succeeds after a later `set` and before timeout.
    // Method: wait for the waiter to park, then signal and observe success.
    if (!supports_timed_wait or !supports_parking_wait) return error.SkipZigTest;

    const Result = enum(u8) {
        success = 1,
        timeout = 2,
        unsupported = 3,
    };

    const Context = struct {
        event: *Event,
        result: *std.atomic.Value(u8),

        fn run(ctx: *@This()) void {
            ctx.event.timedWait(100 * std.time.ns_per_ms) catch |err| switch (err) {
                error.Timeout => {
                    ctx.result.store(@intFromEnum(Result.timeout), .release);
                    return;
                },
                error.Unsupported => {
                    ctx.result.store(@intFromEnum(Result.unsupported), .release);
                    return;
                },
            };
            ctx.result.store(@intFromEnum(Result.success), .release);
        }
    };

    var ev = Event{};
    var result = std.atomic.Value(u8).init(0);
    var ctx = Context{ .event = &ev, .result = &result };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});

    try waitForParkedWaiter(&ev, 100 * std.time.ns_per_ms);
    std.debug.assert(!ev.signaled.load(.acquire));
    ev.set();

    thread.join();
    try std.testing.expectEqual(@intFromEnum(Result.success), result.load(.acquire));
    try ev.tryWait();
}

fn waitForParkedWaiter(event: *Event, timeout_ns: u64) !void {
    if (!supports_parking_wait) return error.SkipZigTest;

    const start = std.time.Instant.now() catch return error.SkipZigTest;
    while (true) {
        if (event.wait_mutex.tryLock()) {
            const waiting_waiters = event.waiting_waiters;
            const is_signaled = event.signaled.load(.acquire);
            event.wait_mutex.unlock();
            if (waiting_waiters > 0) {
                std.debug.assert(!is_signaled);
                return;
            }
        }

        const elapsed = (std.time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
