//! Condvar: capability-gated condition variable for package-owned blocking waits.
//!
//! Callers pair this with `static_sync.threading.Mutex` directly. The value this module adds
//! over raw std usage is compile-time gating of blocking wait support and a stable
//! unavailable shape in single-threaded or no-OS-backend builds.
//! Direct app-local host wait/signal code should still prefer `static_sync.threading.Condition`.
//!
//! Thread safety: safe for concurrent use when `-Denable_os_backends=true`.
//! Single-threaded mode: blocking `wait`/`timedWait` are absent; the type exists as a zero-size placeholder.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const time = core.time_compat;
const caps = @import("caps.zig");
const mutex = @import("threading.zig");

pub const supports_blocking_wait = caps.Caps.os_backends_enabled and caps.Caps.threads_enabled;
pub const StdCondition = mutex.Condition;

comptime {
    core.errors.assertVocabularySubset(error{Timeout});
}

/// Condition variable wrapper for blocking wait/signal semantics.
///
/// This surface is available only when `supports_blocking_wait` is true.
/// Callers must gate usage at comptime via `supports_blocking_wait`.
pub const Condvar = if (supports_blocking_wait) struct {
    impl: StdCondition = .{},

    pub fn wait(self: *Condvar, m: *mutex.Mutex) void {
        assert(supports_blocking_wait);
        self.impl.wait(m);
    }

    pub fn timedWait(self: *Condvar, m: *mutex.Mutex, timeout_ns: u64) error{Timeout}!void {
        assert(supports_blocking_wait);
        return self.impl.timedWait(m, timeout_ns);
    }

    pub fn signal(self: *Condvar) void {
        assert(supports_blocking_wait);
        self.impl.signal();
    }

    pub fn broadcast(self: *Condvar) void {
        assert(supports_blocking_wait);
        self.impl.broadcast();
    }

    pub fn raw(self: *Condvar) *StdCondition {
        return &self.impl;
    }
} else struct {
    comptime {
        _ = mutex;
    }
};

test "condvar APIs are compiled only when blocking wait is supported" {
    // Goal: verify API surface matches capability gating.
    // Method: inspect declaration presence with `@hasDecl`.
    try testing.expectEqual(supports_blocking_wait, @hasDecl(Condvar, "wait"));
    try testing.expectEqual(supports_blocking_wait, @hasDecl(Condvar, "timedWait"));
    try testing.expectEqual(supports_blocking_wait, @hasDecl(Condvar, "signal"));
    try testing.expectEqual(supports_blocking_wait, @hasDecl(Condvar, "broadcast"));
}

test "condvar wrapper stays layout-compatible with std condition when enabled" {
    if (!supports_blocking_wait) return error.SkipZigTest;

    try testing.expectEqual(@sizeOf(StdCondition), @sizeOf(Condvar));
    try testing.expectEqual(@alignOf(StdCondition), @alignOf(Condvar));

    var cv = Condvar{};
    try testing.expect(@intFromPtr(cv.raw()) == @intFromPtr(&cv));
}

test "condvar timedWait reports timeout" {
    // Goal: verify timed waits return timeout errors.
    // Method: hold mutex and call timed wait with finite budgets.
    if (!supports_blocking_wait) return error.SkipZigTest;

    var m: mutex.Mutex = .{};
    var cv = Condvar{};
    m.lock();
    defer m.unlock();
    try testing.expectError(error.Timeout, cv.timedWait(&m, std.time.ns_per_ms));
    try testing.expectError(error.Timeout, cv.timedWait(&m, 0));
}

test "condvar signal wakes exactly one waiter" {
    // Goal: verify `signal` wakes one blocked waiter and leaves the rest parked.
    // Method: wait for both waiters to block, signal once, then observe exactly
    // one waiter complete before a cleanup signal releases the second.
    if (!supports_blocking_wait) return error.SkipZigTest;

    const State = struct {
        mutex: mutex.Mutex = .{},
        cond: Condvar = .{},
        ready: bool = false,
        waiting_count: u8 = 0,
        awoken_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        fn waiter(state: *@This()) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            assert(state.waiting_count < 2);
            state.waiting_count += 1;
            while (!state.ready) {
                state.cond.wait(&state.mutex);
            }
            _ = state.awoken_count.fetchAdd(1, .acq_rel);
        }
    };

    var state = State{};
    var waiter0 = try std.Thread.spawn(.{}, State.waiter, .{&state});
    var waiter1 = try std.Thread.spawn(.{}, State.waiter, .{&state});
    defer waiter0.join();
    defer waiter1.join();
    errdefer {
        state.mutex.lock();
        state.ready = true;
        state.mutex.unlock();
        state.cond.broadcast();
    }

    try waitForBlockedWaiters(&state, 2, 100 * std.time.ns_per_ms);

    state.mutex.lock();
    state.ready = true;
    state.mutex.unlock();
    state.cond.signal();

    try waitForAwokenCount(&state.awoken_count, 1, 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u8, 1), state.awoken_count.load(.acquire));

    state.cond.signal();
    try waitForAwokenCount(&state.awoken_count, 2, 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u8, 2), state.awoken_count.load(.acquire));
}

test "condvar broadcast wakes all blocked waiters" {
    // Goal: verify `broadcast` wakes every blocked waiter once the predicate is ready.
    // Method: wait for both waiters to block, broadcast once, and observe both
    // wake before cleanup.
    if (!supports_blocking_wait) return error.SkipZigTest;

    const State = struct {
        mutex: mutex.Mutex = .{},
        cond: Condvar = .{},
        ready: bool = false,
        waiting_count: u8 = 0,
        awoken_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        fn waiter(state: *@This()) void {
            state.mutex.lock();
            defer state.mutex.unlock();

            assert(state.waiting_count < 2);
            state.waiting_count += 1;
            while (!state.ready) {
                state.cond.wait(&state.mutex);
            }
            _ = state.awoken_count.fetchAdd(1, .acq_rel);
        }
    };

    var state = State{};
    var waiter0 = try std.Thread.spawn(.{}, State.waiter, .{&state});
    var waiter1 = try std.Thread.spawn(.{}, State.waiter, .{&state});
    defer waiter0.join();
    defer waiter1.join();
    errdefer {
        state.mutex.lock();
        state.ready = true;
        state.mutex.unlock();
        state.cond.broadcast();
    }

    try waitForBlockedWaiters(&state, 2, 100 * std.time.ns_per_ms);

    state.mutex.lock();
    state.ready = true;
    state.mutex.unlock();
    state.cond.broadcast();

    try waitForAwokenCount(&state.awoken_count, 2, 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u8, 2), state.awoken_count.load(.acquire));
}

fn waitForBlockedWaiters(state: anytype, expected: u8, timeout_ns: u64) !void {
    const start = time.Instant.now() catch return error.SkipZigTest;
    while (true) {
        state.mutex.lock();
        const current = state.waiting_count;
        state.mutex.unlock();
        // Observing the full waiting count while holding the same mutex that guards
        // the pre-wait increment means every waiter counted here has already released
        // the mutex through `cond.wait(...)` and is now parked on the condvar.
        if (current == expected) return;

        const elapsed = (time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

fn waitForAwokenCount(counter: anytype, expected: u8, timeout_ns: u64) !void {
    const start = time.Instant.now() catch return error.SkipZigTest;
    while (counter.load(.acquire) != expected) {
        const elapsed = (time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
