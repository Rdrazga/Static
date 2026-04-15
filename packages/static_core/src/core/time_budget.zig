//! Shared timeout-budget helper for timed retry loops.
//!
//! Capacity: not applicable.
//! Thread safety: value type; callers control synchronization around shared instances.
//! Blocking behavior: non-blocking; methods query monotonic time only.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const errors = @import("errors.zig");
const time_compat = @import("time_compat.zig");

pub const TimeoutBudgetError = error{
    Timeout,
    Unsupported,
};

comptime {
    errors.assertVocabularySubset(TimeoutBudgetError);
}

pub const TimeoutBudget = struct {
    start_instant: time_compat.Instant,
    timeout_ns: u64,

    pub fn init(timeout_ns: u64) TimeoutBudgetError!TimeoutBudget {
        return initWithNowFn(timeout_ns, monotonicNow);
    }

    pub fn remainingOrTimeout(self: *const TimeoutBudget) TimeoutBudgetError!u64 {
        return self.remainingOrTimeoutWithNowFn(monotonicNow);
    }

    fn initWithNowFn(
        timeout_ns: u64,
        now_fn: *const fn () error{Unsupported}!time_compat.Instant,
    ) TimeoutBudgetError!TimeoutBudget {
        assert(timeout_ns <= std.math.maxInt(u64));
        if (timeout_ns == 0) return error.Timeout;

        const start_instant = try now_fn();
        return .{
            .start_instant = start_instant,
            .timeout_ns = timeout_ns,
        };
    }

    fn remainingOrTimeoutWithNowFn(
        self: *const TimeoutBudget,
        now_fn: *const fn () error{Unsupported}!time_compat.Instant,
    ) TimeoutBudgetError!u64 {
        assert(self.timeout_ns > 0);

        const now = try now_fn();
        const elapsed_ns = now.since(self.start_instant);
        return self.remainingOrTimeoutFromElapsed(elapsed_ns);
    }

    fn remainingOrTimeoutFromElapsed(
        self: *const TimeoutBudget,
        elapsed_ns: u64,
    ) TimeoutBudgetError!u64 {
        assert(self.timeout_ns > 0);
        if (elapsed_ns >= self.timeout_ns) return error.Timeout;

        const remaining_ns = self.timeout_ns - elapsed_ns;
        assert(remaining_ns > 0);
        assert(remaining_ns <= self.timeout_ns);
        return remaining_ns;
    }
};

fn monotonicNow() error{Unsupported}!time_compat.Instant {
    return time_compat.Instant.now() catch return error.Unsupported;
}

test "timeout budget rejects zero timeout at init" {
    try testing.expectError(error.Timeout, TimeoutBudget.init(0));
}

test "timeout budget returns bounded remaining for positive timeout" {
    const timeout_ns: u64 = std.time.ns_per_ms;
    var timeout_budget = try TimeoutBudget.init(timeout_ns);
    const remaining_ns = try timeout_budget.remainingOrTimeout();
    try testing.expect(remaining_ns <= timeout_ns);
    try testing.expect(remaining_ns > 0);
}

test "timeout budget surfaces unsupported clock from init" {
    const FailingClock = struct {
        fn now() error{Unsupported}!time_compat.Instant {
            return error.Unsupported;
        }
    };

    try testing.expectError(
        error.Unsupported,
        TimeoutBudget.initWithNowFn(std.time.ns_per_ms, FailingClock.now),
    );
}

test "timeout budget surfaces unsupported clock from remaining" {
    const FailingClock = struct {
        fn now() error{Unsupported}!time_compat.Instant {
            return error.Unsupported;
        }
    };

    var timeout_budget = try TimeoutBudget.init(std.time.ns_per_ms);
    try testing.expectError(
        error.Unsupported,
        timeout_budget.remainingOrTimeoutWithNowFn(FailingClock.now),
    );
}

test "timeout budget computes exact remaining from elapsed time" {
    const timeout_budget = TimeoutBudget{
        .start_instant = undefined,
        .timeout_ns = 10,
    };

    try testing.expectEqual(@as(u64, 9), try timeout_budget.remainingOrTimeoutFromElapsed(1));
    try testing.expectEqual(@as(u64, 1), try timeout_budget.remainingOrTimeoutFromElapsed(9));
}

test "timeout budget times out at the exact boundary" {
    const timeout_budget = TimeoutBudget{
        .start_instant = undefined,
        .timeout_ns = 10,
    };

    try testing.expectError(error.Timeout, timeout_budget.remainingOrTimeoutFromElapsed(10));
    try testing.expectError(error.Timeout, timeout_budget.remainingOrTimeoutFromElapsed(11));
}
