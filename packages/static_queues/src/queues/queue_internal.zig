//! Internal shared helpers for queue implementations.
//!
//! Capacity: not applicable (utilities only).
//! Thread safety: utilities are stateless; synchronization helpers are safe when callers
//! hold the documented lock ownership contract.
//! Blocking behavior: mostly non-blocking helpers; mutex guard helpers may block while
//! waiting to acquire a lock.
//!
//! Not part of the public API. Imported as `@import("queue_internal.zig")`.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const memory = @import("static_memory");
const sync = @import("static_sync");

/// Guard returned by `lockConstMutex`.
pub const ConstMutexGuard = struct {
    mutex: *sync.threading.Mutex,

    pub fn unlock(self: *ConstMutexGuard) void {
        self.mutex.unlock();
    }
};

/// Locks a mutex referenced through a const pointer.
///
/// This encodes the interior-mutability policy used by queue introspection methods:
/// callers may expose a logically read-only API (`*const Self`) while still taking a
/// synchronization lock. The helper centralizes the `@constCast` pattern so call sites
/// remain uniform and auditable.
pub fn lockConstMutex(mutex_const: *const sync.threading.Mutex) ConstMutexGuard {
    const mutex: *sync.threading.Mutex = @constCast(mutex_const);
    mutex.lock();
    return .{ .mutex = mutex };
}

/// Timeout budget helper for retry loops that need elapsed/remaining calculations.
pub const TimeoutBudget = core.time_budget.TimeoutBudget;

/// Returns the number of bytes required to store `item_count` items of `item_size` bytes each.
///
/// Asserts that the multiplication does not overflow `usize`. The caller is responsible for
/// ensuring `item_size > 0` before calling this function.
pub fn bytesForItems(item_count: usize, item_size: usize) usize {
    // Precondition: only call this with a non-zero item size; ZSTs must be rejected upstream.
    assert(item_size > 0);
    // Precondition: multiplication must not overflow usize.
    assert(item_count <= std.math.maxInt(usize) / item_size);
    const result = item_count * item_size;
    // Postcondition: a non-zero count produces a positive byte count.
    if (item_count > 0) assert(result > 0);
    return result;
}

/// Returns the sum of two byte counts.
///
/// Asserts that the addition does not overflow `usize`.
pub fn addBytesExact(a: usize, b: usize) usize {
    // Precondition: addition must not overflow usize.
    assert(a <= std.math.maxInt(usize) - b);
    const result = a + b;
    // Postcondition: result is at least as large as either operand.
    assert(result >= a);
    return result;
}

/// Attempts to reserve `bytes` from an optional budget.
///
/// Returns immediately (no-op) when `budget` is null. Maps budget errors to
/// the queue error set so every caller can use a single uniform error path.
pub fn tryReserveBudget(budget: ?*memory.budget.Budget, bytes: usize) error{ NoSpaceLeft, InvalidConfig, Overflow }!void {
    const b = budget orelse return;
    // Precondition: a zero-byte reservation indicates a logic error in the caller.
    assert(bytes > 0);
    b.tryReserve(bytes) catch |err| switch (err) {
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.InvalidConfig => return error.InvalidConfig,
        error.Overflow => return error.Overflow,
    };
}

/// Returns whether `capacity` is safe to use with signed sequence-distance math.
///
/// Lock-free ring protocols frequently compute `(a -% b)` and reinterpret the
/// result as `i64` to distinguish "behind", "equal", and "ahead". This remains
/// valid only when the queue capacity is strictly less than half the sequence
/// number space. For `u64` sequences that bound is `i64::max`.
pub fn capacityFitsSignedSequenceDistance(capacity: usize) bool {
    if (comptime @bitSizeOf(usize) >= @bitSizeOf(i64)) {
        return capacity <= @as(usize, std.math.maxInt(i64));
    }
    return true;
}

/// Returns signed sequence distance from `reference_seq` to `candidate_seq`.
///
/// A return value of:
/// - `0` means equal
/// - `< 0` means candidate is behind reference
/// - `> 0` means candidate is ahead of reference
///
/// Callers must ensure their protocol keeps live distance below half-range.
pub fn seqDistanceSigned(candidate_seq: u64, reference_seq: u64) i64 {
    return @as(i64, @bitCast(candidate_seq -% reference_seq));
}

test "timeout budget returns Timeout for zero timeout" {
    try testing.expectError(error.Timeout, TimeoutBudget.init(0));
}

test "timeout budget returns bounded remaining for positive timeout" {
    const timeout_ns: u64 = std.time.ns_per_ms;
    var timeout_budget = try TimeoutBudget.init(timeout_ns);
    const remaining_ns = try timeout_budget.remainingOrTimeout();
    try testing.expect(remaining_ns <= timeout_ns);
}
