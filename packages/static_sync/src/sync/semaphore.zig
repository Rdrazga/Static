//! Semaphore: counting semaphore with optional blocking wait.
//!
//! Thread safety: all operations are safe for concurrent use via atomic CAS loops.
//! Single-threaded mode: `wait` and `timedWait` are absent; `tryWait` and `post`
//!   remain available for cooperative single-threaded use.
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

/// Pure helper: computes the next permit count after a `post` of `permit_count` permits.
///
/// Uses saturating addition so that posting more permits than `maxInt(usize)` clamps
/// rather than wrapping. Both the single-threaded and multi-threaded branches call
/// this function to keep the arithmetic in one place.
fn computePost(current: usize, permit_count: usize) usize {
    // Precondition: permit_count is positive (callers guard zero-count posts).
    std.debug.assert(permit_count > 0);
    const result = current +| permit_count;
    // Postcondition: result is at least current (saturating add never decreases).
    std.debug.assert(result >= current);
    return result;
}

/// Pure helper: computes the next permit count for a `tryWait`, or returns null when empty.
///
/// Returns `current - 1` when a permit is available, or `null` when `current == 0`.
/// Both branches call this function so the decrement logic is defined once.
fn computeTryWait(current: usize) ?usize {
    // Precondition: current is a valid (non-negative) permit count.
    std.debug.assert(current <= std.math.maxInt(usize));
    if (current == 0) return null;
    const next = current - 1;
    // Postcondition: next is strictly less than current when a permit was available.
    std.debug.assert(next < current);
    return next;
}

pub const Semaphore = if (supports_blocking_wait) struct {
    // On its own cache line: contended by every concurrent post and tryWait caller.
    permits: padded_atomic.PaddedAtomic(usize) = .{ .value = std.atomic.Value(usize).init(0) },
    wait_mutex: mutex.Mutex = .{},
    wait_condvar: if (supports_parking_wait) condvar.Condvar else void = if (supports_parking_wait) .{} else {},

    /// Releases `permit_count` permits back to the semaphore.
    ///
    /// Increments the permit count using saturating addition. If the count
    /// would overflow, it saturates at `maxInt(usize)` rather than wrapping.
    /// Callers passing `permit_count == 0` are no-ops.
    pub fn post(self: *Semaphore, permit_count: usize) void {
        if (permit_count == 0) return;
        std.debug.assert(permit_count > 0);

        // Bound CAS retries: under correct operation this loop succeeds within a few
        // attempts. Exhaustion indicates livelock or extreme contention.
        const max_cas_retries: u32 = 256;
        var previous_permits: usize = 0;
        var next_permits: usize = 0;
        var cas_attempts: u32 = 0;
        while (cas_attempts < max_cas_retries) : (cas_attempts += 1) {
            previous_permits = self.permits.load(.acquire);
            next_permits = computePost(previous_permits, permit_count);
            if (self.permits.cmpxchgWeak(
                previous_permits,
                next_permits,
                .acq_rel,
                .acquire,
            ) == null) break;
            std.atomic.spinLoopHint();
        } else @panic("Semaphore.post: CAS loop exhausted -- liveness bug or extreme contention");

        if (supports_parking_wait and previous_permits == 0 and next_permits > 0) {
            self.wait_mutex.lock();
            defer self.wait_mutex.unlock();
            self.wait_condvar.broadcast();
        }

        // Racy assertion removed: a concurrent tryWait can decrement permits between
        // the CAS success and a subsequent load, causing spurious failures. The CAS
        // success itself is the correctness guarantee for the post operation.
    }

    pub fn tryWait(self: *Semaphore) error{WouldBlock}!void {
        const max_cas_retries: u32 = 256;
        var cas_attempts: u32 = 0;
        while (cas_attempts < max_cas_retries) : (cas_attempts += 1) {
            const current_permits = self.permits.load(.acquire);
            const next_permits = computeTryWait(current_permits) orelse return error.WouldBlock;
            std.debug.assert(next_permits < current_permits);
            if (self.permits.cmpxchgWeak(
                current_permits,
                next_permits,
                .acq_rel,
                .acquire,
            ) == null) {
                std.debug.assert(self.permits.load(.acquire) <= current_permits);
                return;
            }
            std.atomic.spinLoopHint();
        }
        @panic("Semaphore.tryWait: CAS loop exhausted -- liveness bug or extreme contention");
    }

    pub fn wait(self: *Semaphore) void {
        std.debug.assert(supports_blocking_wait);

        if (supports_parking_wait) {
            self.wait_mutex.lock();
            defer self.wait_mutex.unlock();

            while (true) {
                self.tryWait() catch |err| switch (err) {
                    error.WouldBlock => {
                        self.wait_condvar.wait(&self.wait_mutex);
                        continue;
                    },
                };
                return;
            }
        }

        var spin_backoff = backoff.Backoff{};
        while (true) {
            self.tryWait() catch |err| switch (err) {
                error.WouldBlock => {
                    spin_backoff.step();
                    continue;
                },
            };
            return;
        }
    }

    pub fn timedWait(self: *Semaphore, timeout_ns: u64) error{ Timeout, Unsupported }!void {
        std.debug.assert(supports_timed_wait);

        if (self.tryWait()) {
            return;
        } else |err| switch (err) {
            error.WouldBlock => {
                if (timeout_ns == 0) return error.Timeout;
            },
        }

        var timeout_budget = core.time_budget.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Unsupported => return error.Unsupported,
        };
        if (supports_parking_wait) {
            self.wait_mutex.lock();
            defer self.wait_mutex.unlock();

            while (true) {
                self.tryWait() catch |err| switch (err) {
                    error.WouldBlock => {
                        const remaining_ns = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                            error.Timeout => return error.Timeout,
                            error.Unsupported => return error.Unsupported,
                        };
                        std.debug.assert(remaining_ns > 0);
                        self.wait_condvar.timedWait(&self.wait_mutex, remaining_ns) catch |wait_err| switch (wait_err) {
                            error.Timeout => {
                                self.tryWait() catch |try_wait_err| switch (try_wait_err) {
                                    error.WouldBlock => {
                                        _ = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                                            error.Timeout => return error.Timeout,
                                            error.Unsupported => return error.Unsupported,
                                        };
                                        continue;
                                    },
                                };
                                return;
                            },
                        };
                        continue;
                    },
                };
                return;
            }
        }

        var spin_backoff = backoff.Backoff{};
        while (true) {
            self.tryWait() catch |err| switch (err) {
                error.WouldBlock => {
                    _ = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                        error.Timeout => return error.Timeout,
                        error.Unsupported => return error.Unsupported,
                    };
                    spin_backoff.step();
                    continue;
                },
            };
            return;
        }
    }
} else struct {
    permits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn post(self: *Semaphore, permit_count: usize) void {
        if (permit_count == 0) return;
        std.debug.assert(permit_count > 0);

        const max_cas_retries: u32 = 256;
        var cas_attempts: u32 = 0;
        while (cas_attempts < max_cas_retries) : (cas_attempts += 1) {
            const previous_permits = self.permits.load(.acquire);
            const next_permits = computePost(previous_permits, permit_count);
            if (self.permits.cmpxchgWeak(
                previous_permits,
                next_permits,
                .acq_rel,
                .acquire,
            ) == null) {
                std.debug.assert(self.permits.load(.acquire) >= next_permits);
                return;
            }
            std.atomic.spinLoopHint();
        }
        @panic("Semaphore.post: CAS loop exhausted -- liveness bug or extreme contention");
    }

    pub fn tryWait(self: *Semaphore) error{WouldBlock}!void {
        const max_cas_retries: u32 = 256;
        var cas_attempts: u32 = 0;
        while (cas_attempts < max_cas_retries) : (cas_attempts += 1) {
            const current_permits = self.permits.load(.acquire);
            const next_permits = computeTryWait(current_permits) orelse return error.WouldBlock;
            std.debug.assert(next_permits < current_permits);
            if (self.permits.cmpxchgWeak(
                current_permits,
                next_permits,
                .acq_rel,
                .acquire,
            ) == null) {
                std.debug.assert(self.permits.load(.acquire) <= current_permits);
                return;
            }
            std.atomic.spinLoopHint();
        }
        @panic("Semaphore.tryWait: CAS loop exhausted -- liveness bug or extreme contention");
    }
};

test "semaphore blocking waits are gated by build mode" {
    // Goal: verify compile-time API shape tracks `single_threaded`.
    // Method: query declarations with `@hasDecl`.
    try std.testing.expectEqual(caps.Caps.threads_enabled, @hasDecl(Semaphore, "wait"));
    try std.testing.expectEqual(caps.Caps.threads_enabled, @hasDecl(Semaphore, "timedWait"));
}

test "semaphore tryWait semantics" {
    // Goal: verify permit consumption and would-block behavior.
    // Method: try wait empty, post once, then consume once.
    var semaphore = Semaphore{};
    try std.testing.expectError(error.WouldBlock, semaphore.tryWait());
    semaphore.post(1);
    try semaphore.tryWait();
}

test "semaphore post with zero permits is a no-op" {
    // Goal: verify zero-count posts do not mutate permit state.
    // Method: post zero and ensure `tryWait` still would-blocks.
    var semaphore = Semaphore{};
    semaphore.post(0);
    try std.testing.expectError(error.WouldBlock, semaphore.tryWait());
}

test "semaphore post saturates at maxInt" {
    // Goal: verify post uses saturating arithmetic.
    // Method: post max value then post one additional permit.
    var semaphore = Semaphore{};
    semaphore.post(std.math.maxInt(usize));
    semaphore.post(1);
    try std.testing.expectEqual(std.math.maxInt(usize), semaphore.permits.load(.acquire));
}

test "semaphore timedWait reports Timeout when empty" {
    // Goal: verify timeout behavior when no permits are available.
    // Method: check both zero timeout and positive timeout paths.
    if (!supports_timed_wait) return error.SkipZigTest;

    var semaphore = Semaphore{};
    try std.testing.expectError(error.Timeout, semaphore.timedWait(0));
    try std.testing.expectError(error.Timeout, semaphore.timedWait(std.time.ns_per_ms));
}

test "semaphore timedWait succeeds with preposted permit" {
    // Goal: verify available permits bypass timeout checks.
    // Method: prepost one permit and call timed wait with zero timeout.
    if (!supports_timed_wait) return error.SkipZigTest;

    var semaphore = Semaphore{};
    semaphore.post(1);
    try semaphore.timedWait(0);
}

test "semaphore wait unblocks after post from another thread" {
    // Goal: verify cross-thread wakeup for unbounded wait.
    // Method: spawn a worker that posts one permit.
    if (!supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        semaphore: *Semaphore,

        fn run(ctx: *@This()) void {
            ctx.semaphore.post(1);
        }
    };

    var semaphore = Semaphore{};
    var ctx = Context{ .semaphore = &semaphore };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    defer thread.join();

    semaphore.wait();
    try std.testing.expectError(error.WouldBlock, semaphore.tryWait());
}

test "semaphore timedWait unblocks after post from another thread" {
    // Goal: verify cross-thread wakeup for bounded wait.
    // Method: wait until the waiter holds the internal mutex, then post from
    // a second thread and confirm the permit is consumed exactly once.
    if (!supports_timed_wait or !supports_parking_wait) return error.SkipZigTest;

    const Result = enum(u8) {
        success = 1,
        timeout = 2,
        unsupported = 3,
    };

    const Context = struct {
        semaphore: *Semaphore,
        waiter_started: *std.atomic.Value(bool),
        waiter_finished: *std.atomic.Value(bool),
        waiter_result: *std.atomic.Value(u8),

        fn run(ctx: *@This()) void {
            ctx.waiter_started.store(true, .release);
            ctx.semaphore.timedWait(100 * std.time.ns_per_ms) catch |err| switch (err) {
                error.Timeout => {
                    ctx.waiter_result.store(@intFromEnum(Result.timeout), .release);
                    ctx.waiter_finished.store(true, .release);
                    return;
                },
                error.Unsupported => {
                    ctx.waiter_result.store(@intFromEnum(Result.unsupported), .release);
                    ctx.waiter_finished.store(true, .release);
                    return;
                },
            };
            ctx.waiter_result.store(@intFromEnum(Result.success), .release);
            ctx.waiter_finished.store(true, .release);
        }
    };

    const Poster = struct {
        semaphore: *Semaphore,
        poster_released: *std.atomic.Value(bool),
        poster_finished: *std.atomic.Value(bool),

        fn run(ctx: *@This()) void {
            while (!ctx.poster_released.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            ctx.semaphore.post(1);
            ctx.poster_finished.store(true, .release);
        }
    };

    var semaphore = Semaphore{};
    var waiter_started = std.atomic.Value(bool).init(false);
    var poster_released = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);
    var poster_finished = std.atomic.Value(bool).init(false);
    var waiter_result = std.atomic.Value(u8).init(0);
    var ctx = Context{
        .semaphore = &semaphore,
        .waiter_started = &waiter_started,
        .waiter_finished = &waiter_finished,
        .waiter_result = &waiter_result,
    };
    var poster = Poster{
        .semaphore = &semaphore,
        .poster_released = &poster_released,
        .poster_finished = &poster_finished,
    };

    var waiter_thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});

    var poster_thread = try std.Thread.spawn(.{}, Poster.run, .{&poster});

    try waitForFlag(&waiter_started, 100 * std.time.ns_per_ms);
    try waitForMutexHold(&semaphore.wait_mutex, 100 * std.time.ns_per_ms);
    poster_released.store(true, .release);

    poster_thread.join();
    waiter_thread.join();

    try std.testing.expect(poster_finished.load(.acquire));
    try std.testing.expect(waiter_finished.load(.acquire));
    try std.testing.expectEqual(@intFromEnum(Result.success), waiter_result.load(.acquire));
    try std.testing.expectError(error.WouldBlock, semaphore.tryWait());
}

fn waitForFlag(flag: *std.atomic.Value(bool), timeout_ns: u64) !void {
    const start = std.time.Instant.now() catch return error.SkipZigTest;
    while (!flag.load(.acquire)) {
        const elapsed = (std.time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

fn waitForMutexHold(m: *std.Thread.Mutex, timeout_ns: u64) !void {
    const start = std.time.Instant.now() catch return error.SkipZigTest;
    while (true) {
        if (!m.tryLock()) return;
        m.unlock();

        const elapsed = (std.time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
