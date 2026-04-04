//! Latch and Barrier: countdown latch and reusable cyclic barrier.
//!
//! Thread safety: all operations are safe for concurrent use; atomic CAS loops
//!   protect the latch, and a mutex protects the barrier's arrival state.
//! Single-threaded mode: blocking `wait`/`arriveAndWait` methods are absent;
//!   `tryWait` and `arrive` remain available for cooperative single-threaded use.
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
    core.errors.assertVocabularySubset(BarrierError);
    core.errors.assertVocabularySubset(error{WouldBlock});
    core.errors.assertVocabularySubset(error{ Timeout, Unsupported });
}

pub const BarrierError = error{InvalidConfig};

/// Pure helper: computes the next remaining count for a `countDown` of `decrement_count`.
///
/// Both the single-threaded and multi-threaded Latch branches call this function so
/// the decrement arithmetic is defined exactly once.
fn computeCountDown(current: usize, decrement_count: usize) usize {
    // Precondition: decrement_count must not exceed the remaining count.
    std.debug.assert(decrement_count > 0);
    std.debug.assert(current >= decrement_count);
    const next = current - decrement_count;
    // Postcondition: next is strictly less than current when decrement is positive.
    std.debug.assert(next < current);
    return next;
}

/// One-shot countdown latch.
///
/// The latch starts with a fixed remaining count and transitions permanently
/// to the open state once the count reaches zero.
pub const Latch = if (supports_blocking_wait) struct {
    initial_count: usize = 0,
    remaining_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    wait_mutex: mutex.Mutex = .{},
    wait_condvar: if (supports_parking_wait) condvar.Condvar else void = if (supports_parking_wait) .{} else {},

    pub fn init(initial_count: usize) Latch {
        return .{
            .initial_count = initial_count,
            .remaining_count = std.atomic.Value(usize).init(initial_count),
        };
    }

    pub fn remaining(self: *const Latch) usize {
        const rem = self.remaining_count.load(.acquire);
        // Postcondition: remaining can never exceed the count at init time.
        std.debug.assert(rem <= self.initial_count);
        // Postcondition: latch counts only go down, never below zero (unsigned).
        std.debug.assert(rem <= self.initial_count);
        return rem;
    }

    pub fn countDown(self: *Latch, decrement_count: usize) void {
        if (decrement_count == 0) return;
        std.debug.assert(decrement_count > 0);

        // Bound CAS retries: under correct operation this loop succeeds within a few
        // attempts. Exhaustion indicates livelock, extreme contention, or corruption.
        const max_cas_retries: u32 = 256;
        var cas_attempts: u32 = 0;
        while (cas_attempts < max_cas_retries) : (cas_attempts += 1) {
            const current_remaining = self.remaining_count.load(.acquire);
            const next_remaining = computeCountDown(current_remaining, decrement_count);
            if (self.remaining_count.cmpxchgWeak(
                current_remaining,
                next_remaining,
                .acq_rel,
                .acquire,
            ) == null) {
                if (supports_parking_wait and next_remaining == 0 and current_remaining != 0) {
                    self.wait_mutex.lock();
                    defer self.wait_mutex.unlock();
                    self.wait_condvar.broadcast();
                }
                std.debug.assert(self.remaining_count.load(.acquire) <= current_remaining);
                return;
            }
            std.atomic.spinLoopHint();
        }
        @panic("Latch.countDown: CAS loop exhausted -- liveness bug or extreme contention");
    }

    pub fn tryWait(self: *const Latch) error{WouldBlock}!void {
        const current_remaining = self.remaining_count.load(.acquire);
        if (current_remaining != 0) return error.WouldBlock;
        std.debug.assert(current_remaining == 0);
    }

    pub fn wait(self: *Latch) void {
        std.debug.assert(supports_blocking_wait);

        if (supports_parking_wait) {
            if (self.remaining_count.load(.acquire) == 0) return;

            self.wait_mutex.lock();
            defer self.wait_mutex.unlock();

            while (self.remaining_count.load(.acquire) != 0) {
                self.wait_condvar.wait(&self.wait_mutex);
            }
            std.debug.assert(self.remaining_count.load(.acquire) == 0);
            return;
        }

        var spin_backoff = backoff.Backoff{};
        while (self.remaining_count.load(.acquire) != 0) {
            spin_backoff.step();
        }
        std.debug.assert(self.remaining_count.load(.acquire) == 0);
    }

    pub fn timedWait(self: *Latch, timeout_ns: u64) error{ Timeout, Unsupported }!void {
        std.debug.assert(supports_timed_wait);

        if (self.remaining_count.load(.acquire) == 0) {
            std.debug.assert(self.remaining_count.load(.acquire) == 0);
            return;
        }
        var timeout_budget = core.time_budget.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Unsupported => return error.Unsupported,
        };
        if (supports_parking_wait) {
            self.wait_mutex.lock();
            defer self.wait_mutex.unlock();

            while (self.remaining_count.load(.acquire) != 0) {
                const remaining_ns = timeout_budget.remainingOrTimeout() catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                    error.Unsupported => return error.Unsupported,
                };
                std.debug.assert(remaining_ns > 0);
                self.wait_condvar.timedWait(&self.wait_mutex, remaining_ns) catch |err| switch (err) {
                    error.Timeout => {
                        if (self.remaining_count.load(.acquire) == 0) continue;
                        _ = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                            error.Timeout => return error.Timeout,
                            error.Unsupported => return error.Unsupported,
                        };
                    },
                };
            }
            std.debug.assert(self.remaining_count.load(.acquire) == 0);
            return;
        }

        var spin_backoff = backoff.Backoff{};
        while (self.remaining_count.load(.acquire) != 0) {
            _ = timeout_budget.remainingOrTimeout() catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            };
            spin_backoff.step();
        }
        std.debug.assert(self.remaining_count.load(.acquire) == 0);
    }
} else struct {
    initial_count: usize = 0,
    remaining_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(initial_count: usize) Latch {
        return .{
            .initial_count = initial_count,
            .remaining_count = std.atomic.Value(usize).init(initial_count),
        };
    }

    pub fn remaining(self: *const Latch) usize {
        const rem = self.remaining_count.load(.acquire);
        // Postcondition: remaining can never exceed the count at init time.
        std.debug.assert(rem <= self.initial_count);
        // Postcondition: latch counts only go down, never below zero (unsigned).
        std.debug.assert(rem <= self.initial_count);
        return rem;
    }

    pub fn countDown(self: *Latch, decrement_count: usize) void {
        if (decrement_count == 0) return;
        std.debug.assert(decrement_count > 0);

        const max_cas_retries: u32 = 256;
        var cas_attempts: u32 = 0;
        while (cas_attempts < max_cas_retries) : (cas_attempts += 1) {
            const current_remaining = self.remaining_count.load(.acquire);
            const next_remaining = computeCountDown(current_remaining, decrement_count);
            if (self.remaining_count.cmpxchgWeak(
                current_remaining,
                next_remaining,
                .acq_rel,
                .acquire,
            ) == null) {
                std.debug.assert(self.remaining_count.load(.acquire) <= current_remaining);
                return;
            }
            std.atomic.spinLoopHint();
        }
        @panic("Latch.countDown: CAS loop exhausted -- liveness bug or extreme contention");
    }

    pub fn tryWait(self: *const Latch) error{WouldBlock}!void {
        const current_remaining = self.remaining_count.load(.acquire);
        if (current_remaining != 0) return error.WouldBlock;
        std.debug.assert(current_remaining == 0);
    }
};

/// Reusable cyclic barrier.
///
/// Each phase completes when exactly `parties_count` arrivals have occurred.
pub const Barrier = if (supports_blocking_wait) struct {
    parties_count: usize,
    state_mutex: mutex.Mutex = .{},
    wait_condvar: if (supports_parking_wait) condvar.Condvar else void = if (supports_parking_wait) .{} else {},
    arrived_count: usize = 0,
    // On its own cache line: all waiting threads poll this on every spin iteration.
    generation: padded_atomic.PaddedAtomic(u64) = .{ .value = std.atomic.Value(u64).init(0) },

    pub fn init(parties_count: usize) BarrierError!Barrier {
        if (parties_count == 0) return error.InvalidConfig;
        const barrier = Barrier{ .parties_count = parties_count };
        std.debug.assert(barrier.parties_count > 0);
        return barrier;
    }

    pub fn parties(self: *const Barrier) usize {
        std.debug.assert(self.parties_count > 0);
        return self.parties_count;
    }

    pub fn generationNow(self: *const Barrier) u64 {
        std.debug.assert(self.parties_count > 0);
        return self.generation.load(.acquire);
    }

    pub fn arrive(self: *Barrier) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const result = self.arriveInner();
        if (result.is_last and supports_parking_wait) self.wait_condvar.broadcast();
        return result.is_last;
    }

    pub fn tryWait(self: *const Barrier, observed_generation: u64) error{WouldBlock}!void {
        const current_generation = self.generation.load(.acquire);
        std.debug.assert(observed_generation <= current_generation);
        if (current_generation == observed_generation) return error.WouldBlock;
        std.debug.assert(current_generation > observed_generation);
    }

    pub fn arriveAndWait(self: *Barrier) void {
        std.debug.assert(supports_blocking_wait);
        self.state_mutex.lock();

        const result = self.arriveInner();
        const observed_generation = result.observed_generation;

        if (result.is_last) {
            if (supports_parking_wait) self.wait_condvar.broadcast();
            self.state_mutex.unlock();
            return;
        }

        if (supports_parking_wait) {
            while (self.generation.load(.acquire) == observed_generation) {
                self.wait_condvar.wait(&self.state_mutex);
            }
            std.debug.assert(self.generation.load(.acquire) > observed_generation);
            self.state_mutex.unlock();
            return;
        }

        self.state_mutex.unlock();
        // Under correct usage the generation must advance: all remaining parties
        // will arrive and increment it. A bound of 10_000 iterations with exponential
        // backoff covers very long waits; exhaustion means a party has stalled.
        const max_spin_iterations: u32 = 10_000;
        var spin_count: u32 = 0;
        var spin_backoff = backoff.Backoff{};
        while (spin_count < max_spin_iterations) : (spin_count += 1) {
            if (self.generation.load(.acquire) != observed_generation) break;
            spin_backoff.step();
        }
        // If the bound was exhausted without the generation advancing, this assertion
        // fires and indicates a stalled or crashed barrier party.
        std.debug.assert(self.generation.load(.acquire) > observed_generation);
    }

    /// Decrements the arrival counter and returns whether this call was the last
    /// arrival, along with the observed generation for the caller to wait on.
    ///
    /// Must be called with `state_mutex` held. Advances `generation` and resets
    /// `arrived_count` when the last party arrives.
    fn arriveInner(self: *Barrier) struct { is_last: bool, observed_generation: u64 } {
        // Precondition: parties_count is always positive (enforced in init).
        std.debug.assert(self.parties_count > 0);
        // Precondition: arrived_count has not yet reached parties_count.
        std.debug.assert(self.arrived_count < self.parties_count);

        const observed_generation = self.generation.load(.acquire);
        self.arrived_count += 1;
        std.debug.assert(self.arrived_count <= self.parties_count);

        if (self.arrived_count != self.parties_count) {
            return .{ .is_last = false, .observed_generation = observed_generation };
        }

        // Last arrival: close the phase.
        std.debug.assert(observed_generation < std.math.maxInt(u64));
        self.arrived_count = 0;
        self.generation.store(observed_generation + 1, .release);
        // Postcondition: generation advanced exactly once.
        std.debug.assert(self.generation.load(.acquire) == observed_generation + 1);
        return .{ .is_last = true, .observed_generation = observed_generation };
    }
} else struct {
    parties_count: usize,
    arrived_count: usize = 0,
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(parties_count: usize) BarrierError!Barrier {
        if (parties_count == 0) return error.InvalidConfig;
        const barrier = Barrier{ .parties_count = parties_count };
        std.debug.assert(barrier.parties_count > 0);
        return barrier;
    }

    pub fn parties(self: *const Barrier) usize {
        std.debug.assert(self.parties_count > 0);
        return self.parties_count;
    }

    pub fn generationNow(self: *const Barrier) u64 {
        std.debug.assert(self.parties_count > 0);
        return self.generation.load(.acquire);
    }

    pub fn arrive(self: *Barrier) bool {
        const result = self.arriveInner();
        return result.is_last;
    }

    pub fn tryWait(self: *const Barrier, observed_generation: u64) error{WouldBlock}!void {
        const current_generation = self.generation.load(.acquire);
        std.debug.assert(observed_generation <= current_generation);
        if (current_generation == observed_generation) return error.WouldBlock;
        std.debug.assert(current_generation > observed_generation);
    }

    /// Decrements the arrival counter and returns whether this call was the last
    /// arrival, along with the observed generation for the caller to wait on.
    ///
    /// In the single-threaded branch there is no mutex; callers must ensure
    /// single-threaded access to the barrier.
    fn arriveInner(self: *Barrier) struct { is_last: bool, observed_generation: u64 } {
        // Precondition: parties_count is always positive (enforced in init).
        std.debug.assert(self.parties_count > 0);
        // Precondition: arrived_count has not yet reached parties_count.
        std.debug.assert(self.arrived_count < self.parties_count);

        const observed_generation = self.generation.load(.acquire);
        self.arrived_count += 1;
        std.debug.assert(self.arrived_count <= self.parties_count);

        if (self.arrived_count != self.parties_count) {
            return .{ .is_last = false, .observed_generation = observed_generation };
        }

        // Last arrival: close the phase.
        std.debug.assert(observed_generation < std.math.maxInt(u64));
        self.arrived_count = 0;
        self.generation.store(observed_generation + 1, .release);
        // Postcondition: generation advanced exactly once.
        std.debug.assert(self.generation.load(.acquire) == observed_generation + 1);
        return .{ .is_last = true, .observed_generation = observed_generation };
    }
};

test "latch blocking waits are gated by build mode" {
    // Goal: verify compile-time API shape tracks `single_threaded`.
    // Method: query declarations with `@hasDecl`.
    try std.testing.expectEqual(caps.Caps.threads_enabled, @hasDecl(Latch, "wait"));
    try std.testing.expectEqual(caps.Caps.threads_enabled, @hasDecl(Latch, "timedWait"));
}

test "latch countDown opens latch" {
    // Goal: verify countdown reaches the open state at zero.
    // Method: decrement in two steps and observe `tryWait`.
    var latch = Latch.init(2);
    try std.testing.expectError(error.WouldBlock, latch.tryWait());
    latch.countDown(1);
    try std.testing.expectError(error.WouldBlock, latch.tryWait());
    latch.countDown(1);
    try latch.tryWait();
}

test "latch countDown with zero is a no-op" {
    // Goal: verify a zero decrement does not change latch state.
    // Method: call `countDown(0)` and compare `remaining`.
    var latch = Latch.init(3);
    try std.testing.expectEqual(@as(usize, 3), latch.remaining());
    latch.countDown(0);
    try std.testing.expectEqual(@as(usize, 3), latch.remaining());
}

test "latch timedWait reports Timeout while pending" {
    // Goal: verify timeout behavior on a pending latch.
    // Method: test both zero timeout and a positive timeout.
    if (!supports_timed_wait) return error.SkipZigTest;

    var latch = Latch.init(1);
    try std.testing.expectError(error.Timeout, latch.timedWait(0));
    try std.testing.expectError(error.Timeout, latch.timedWait(std.time.ns_per_ms));
}

test "latch timedWait succeeds when already open" {
    // Goal: verify open latch returns immediately.
    // Method: initialize at zero and call timed wait with zero timeout.
    if (!supports_timed_wait) return error.SkipZigTest;

    var latch = Latch.init(0);
    try latch.timedWait(0);
}

test "latch wait unblocks after countDown from another thread" {
    // Goal: verify cross-thread wakeup for unbounded wait.
    // Method: spawn a worker that performs the final decrement.
    if (!supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        latch: *Latch,

        fn run(ctx: *@This()) void {
            ctx.latch.countDown(1);
        }
    };

    var latch = Latch.init(1);
    var ctx = Context{ .latch = &latch };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    defer thread.join();

    latch.wait();
    try latch.tryWait();
}

test "latch timedWait unblocks after countDown from another thread" {
    // Goal: verify cross-thread wakeup for bounded wait.
    // Method: spawn a worker and wait with a finite timeout.
    if (!supports_timed_wait) return error.SkipZigTest;

    const Context = struct {
        latch: *Latch,

        fn run(ctx: *@This()) void {
            ctx.latch.countDown(1);
        }
    };

    var latch = Latch.init(1);
    var ctx = Context{ .latch = &latch };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    defer thread.join();

    try latch.timedWait(100 * std.time.ns_per_ms);
    try latch.tryWait();
}

test "barrier blocking waits are gated by build mode" {
    // Goal: verify compile-time API gating for blocking waits.
    // Method: query declaration presence with `@hasDecl`.
    try std.testing.expectEqual(caps.Caps.threads_enabled, @hasDecl(Barrier, "arriveAndWait"));
}

test "barrier requires at least one party" {
    // Goal: verify barrier configuration rejects zero parties.
    // Method: call `init(0)` and assert error contract.
    try std.testing.expectError(error.InvalidConfig, Barrier.init(0));
}

test "barrier generation changes after required arrivals" {
    // Goal: verify generation advances exactly at quorum.
    // Method: inspect `tryWait` before and after required arrivals.
    var barrier = try Barrier.init(2);
    const generation_0 = barrier.generationNow();
    try std.testing.expectError(error.WouldBlock, barrier.tryWait(generation_0));
    try std.testing.expect(!barrier.arrive());
    try std.testing.expectError(error.WouldBlock, barrier.tryWait(generation_0));
    try std.testing.expect(barrier.arrive());
    try barrier.tryWait(generation_0);
}

test "barrier arriveAndWait is reusable across phases" {
    // Goal: verify cyclic behavior over many phases.
    // Method: run two-party synchronization for multiple iterations.
    if (!supports_blocking_wait) return error.SkipZigTest;

    const iterations: u32 = 256;
    const Context = struct {
        barrier: *Barrier,
        worker_phase_counter: *std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            var phase_index: u32 = 0;
            while (phase_index < iterations) : (phase_index += 1) {
                _ = ctx.worker_phase_counter.fetchAdd(1, .acq_rel);
                ctx.barrier.arriveAndWait();
                ctx.barrier.arriveAndWait();
            }
        }
    };

    var barrier = try Barrier.init(2);
    var worker_phase_counter = std.atomic.Value(u32).init(0);
    var ctx = Context{
        .barrier = &barrier,
        .worker_phase_counter = &worker_phase_counter,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    defer thread.join();

    var phase_index: u32 = 0;
    while (phase_index < iterations) : (phase_index += 1) {
        barrier.arriveAndWait();
        const observed_phases = worker_phase_counter.load(.acquire);
        try std.testing.expectEqual(phase_index + 1, observed_phases);
        barrier.arriveAndWait();
    }
}

test "barrier arriveAndWait keeps non-final arrival blocked until final party arrives" {
    // Goal: verify the first arrival stays blocked until the second party arrives.
    // Method: observe the worker increment `arrived_count` under the barrier mutex
    // before the main thread performs the final arrival.
    if (!supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        barrier: *Barrier,
        finished: *std.atomic.Value(bool),

        fn run(ctx: *@This()) void {
            ctx.barrier.arriveAndWait();
            ctx.finished.store(true, .release);
        }
    };

    var barrier = try Barrier.init(2);
    var finished = std.atomic.Value(bool).init(false);
    var ctx = Context{
        .barrier = &barrier,
        .finished = &finished,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    defer thread.join();

    const generation_0 = barrier.generationNow();
    try std.testing.expectEqual(@as(u64, 0), generation_0);
    try waitForBarrierArrival(&barrier, 1, generation_0, 100 * std.time.ns_per_ms);
    try std.testing.expectError(error.WouldBlock, barrier.tryWait(generation_0));
    try std.testing.expect(!finished.load(.acquire));

    barrier.arriveAndWait();
    try waitForFlag(&finished, 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 1), barrier.generationNow());
    try barrier.tryWait(generation_0);
}

fn waitForFlag(flag: *std.atomic.Value(bool), timeout_ns: u64) !void {
    const start = std.time.Instant.now() catch return error.SkipZigTest;
    while (!flag.load(.acquire)) {
        const elapsed = (std.time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

fn waitForBarrierArrival(
    barrier: *Barrier,
    expected_arrived_count: usize,
    expected_generation: u64,
    timeout_ns: u64,
) !void {
    if (!supports_blocking_wait) return error.SkipZigTest;

    const start = std.time.Instant.now() catch return error.SkipZigTest;
    while (true) {
        barrier.state_mutex.lock();
        const arrived_count = barrier.arrived_count;
        const generation_now = barrier.generation.load(.acquire);
        barrier.state_mutex.unlock();

        if (arrived_count == expected_arrived_count and generation_now == expected_generation) return;

        const elapsed = (std.time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
