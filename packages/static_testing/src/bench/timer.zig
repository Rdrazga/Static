//! Monotonic timer abstraction for in-process benchmarks.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");

/// Operating errors surfaced by benchmark timers.
pub const TimerError = error{
    Unsupported,
};

/// Timer source used by `MonotonicTimer`.
pub const TimerSource = enum(u8) {
    monotonic = 1,
};

/// Minimal monotonic timer for in-process benchmark loops.
pub const MonotonicTimer = struct {
    source: TimerSource = .monotonic,
    start_instant: ?std.time.Instant = null,

    /// Construct an inactive monotonic timer.
    pub fn init() MonotonicTimer {
        return .{};
    }

    /// Report whether the timer currently has an active start instant.
    pub fn isActive(self: *const MonotonicTimer) bool {
        return self.start_instant != null;
    }

    /// Start timing one measured interval.
    pub fn start(self: *MonotonicTimer) TimerError!void {
        assert(!self.isActive());
        self.start_instant = std.time.Instant.now() catch return error.Unsupported;
        assert(self.isActive());
    }

    /// Stop timing and return elapsed nanoseconds.
    pub fn stop(self: *MonotonicTimer) TimerError!u64 {
        assert(self.isActive());

        const start_instant = self.start_instant.?;
        const stop_instant = std.time.Instant.now() catch return error.Unsupported;
        const elapsed_ns = stop_instant.since(start_instant);
        self.start_instant = null;

        assert(!self.isActive());
        return elapsed_ns;
    }
};

comptime {
    core.errors.assertVocabularySubset(TimerError);
}

test "monotonic timer start stop cycle succeeds" {
    var timer = MonotonicTimer.init();
    try timer.start();
    const elapsed_ns = try timer.stop();

    try testing.expectEqual(TimerSource.monotonic, timer.source);
    try testing.expect(elapsed_ns <= std.math.maxInt(u64));
}

test "monotonic timer can restart after stop" {
    var timer = MonotonicTimer.init();
    try timer.start();
    _ = try timer.stop();
    try timer.start();
    _ = try timer.stop();

    try testing.expect(!timer.isActive());
}
