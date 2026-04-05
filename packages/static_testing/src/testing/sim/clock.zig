//! Deterministic logical time primitives for simulation code.
//!
//! Logical time is explicit. No API in this file reads wall clock state.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");

/// Operating errors surfaced by logical clock mutation.
pub const SimClockError = error{
    InvalidInput,
    Overflow,
};

/// Fixed-width logical duration in simulation ticks.
pub const LogicalDuration = struct {
    ticks: u64,

    /// Construct one logical duration from an explicit tick count.
    pub fn init(ticks: u64) LogicalDuration {
        return .{ .ticks = ticks };
    }
};

/// Fixed-width logical timestamp in simulation ticks.
pub const LogicalTime = struct {
    tick: u64,

    /// Construct one logical timestamp from an explicit tick value.
    pub fn init(tick: u64) LogicalTime {
        return .{ .tick = tick };
    }

    /// Add one duration and reject timestamp overflow explicitly.
    pub fn add(self: LogicalTime, duration: LogicalDuration) SimClockError!LogicalTime {
        const tick = std.math.add(u64, self.tick, duration.ticks) catch return error.Overflow;
        return .{ .tick = tick };
    }
};

/// Maximum absolute drift rate accepted by realtime projections.
pub const drift_ppm_limit: i32 = 1_000_000;

/// Opt-in realtime projection configuration over monotonic simulation ticks.
pub const RealtimeViewConfig = struct {
    reference_time: LogicalTime = .init(0),
    offset_ticks: i64 = 0,
    drift_ppm: i32 = 0,
};

/// Caller-controlled logical clock.
pub const SimClock = struct {
    now_time: LogicalTime,

    /// Construct a clock with one caller-chosen logical start time.
    pub fn init(start_time: LogicalTime) SimClock {
        return .{ .now_time = start_time };
    }

    /// Read the current logical time without mutating clock state.
    pub fn now(self: SimClock) LogicalTime {
        return self.now_time;
    }

    /// Advance the clock forward by one positive or zero logical duration.
    pub fn advance(self: *SimClock, duration: LogicalDuration) SimClockError!LogicalTime {
        const next_time = try self.now_time.add(duration);
        assert(next_time.tick >= self.now_time.tick);
        self.now_time = next_time;
        return self.now_time;
    }

    /// Jump directly to one explicit logical time without allowing rollback.
    pub fn jumpTo(self: *SimClock, target_time: LogicalTime) SimClockError!LogicalTime {
        if (target_time.tick < self.now_time.tick) return error.InvalidInput;
        self.now_time = target_time;
        return self.now_time;
    }
};

/// Opt-in realtime projection that keeps monotonic and observed time separate.
pub const RealtimeView = struct {
    config: RealtimeViewConfig,

    /// Construct one bounded realtime view over caller-controlled drift and offset.
    pub fn init(config: RealtimeViewConfig) SimClockError!RealtimeView {
        if (config.drift_ppm < -drift_ppm_limit or config.drift_ppm > drift_ppm_limit) {
            return error.InvalidInput;
        }
        return .{ .config = config };
    }

    /// Read the underlying monotonic time without applying any realtime skew.
    pub fn monotonicNow(self: RealtimeView, sim_clock: SimClock) LogicalTime {
        _ = self;
        return sim_clock.now();
    }

    /// Project one monotonic timestamp into this view's observed realtime.
    pub fn realtimeAt(self: RealtimeView, monotonic_time: LogicalTime) SimClockError!LogicalTime {
        const relative_ticks = relativeTicks(monotonic_time, self.config.reference_time);
        const drift_ticks = try driftAdjustment(relative_ticks, self.config.drift_ppm);
        const monotonic_ticks = @as(i128, monotonic_time.tick);
        const with_offset = std.math.add(i128, monotonic_ticks, @as(i128, self.config.offset_ticks)) catch {
            return error.Overflow;
        };
        const projected_ticks = std.math.add(i128, with_offset, drift_ticks) catch return error.Overflow;
        if (projected_ticks < 0) return error.InvalidInput;
        if (projected_ticks > std.math.maxInt(u64)) return error.Overflow;
        return .init(@intCast(projected_ticks));
    }

    /// Project the current monotonic clock time into this view's observed realtime.
    pub fn realtimeNow(self: RealtimeView, sim_clock: SimClock) SimClockError!LogicalTime {
        return self.realtimeAt(sim_clock.now());
    }

    /// Convert one monotonic timeout start into a local realtime deadline.
    pub fn deadlineAfter(
        self: RealtimeView,
        monotonic_start: LogicalTime,
        timeout: LogicalDuration,
    ) SimClockError!LogicalTime {
        const realtime_start = try self.realtimeAt(monotonic_start);
        return realtime_start.add(timeout);
    }

    /// Report whether this view's observed realtime has reached one deadline.
    pub fn hasReached(self: RealtimeView, sim_clock: SimClock, deadline: LogicalTime) SimClockError!bool {
        const realtime_now = try self.realtimeNow(sim_clock);
        return realtime_now.tick >= deadline.tick;
    }

    /// Measure local observed elapsed time between two monotonic timestamps.
    pub fn elapsedBetween(
        self: RealtimeView,
        monotonic_start: LogicalTime,
        monotonic_end: LogicalTime,
    ) SimClockError!LogicalDuration {
        if (monotonic_end.tick < monotonic_start.tick) return error.InvalidInput;

        const realtime_start = try self.realtimeAt(monotonic_start);
        const realtime_end = try self.realtimeAt(monotonic_end);
        if (realtime_end.tick < realtime_start.tick) return error.InvalidInput;
        return .init(realtime_end.tick - realtime_start.tick);
    }
};

fn relativeTicks(monotonic_time: LogicalTime, reference_time: LogicalTime) i128 {
    return @as(i128, monotonic_time.tick) - @as(i128, reference_time.tick);
}

fn driftAdjustment(relative_ticks: i128, drift_ppm: i32) SimClockError!i128 {
    const product = std.math.mul(i128, relative_ticks, @as(i128, drift_ppm)) catch return error.Overflow;
    return @divFloor(product, drift_ppm_limit);
}

comptime {
    core.errors.assertVocabularySubset(SimClockError);
    assert(@sizeOf(LogicalTime) == @sizeOf(u64));
    assert(@sizeOf(LogicalDuration) == @sizeOf(u64));
}

test "logical clock advances monotonically" {
    var sim_clock = SimClock.init(LogicalTime.init(5));
    try testing.expectEqual(@as(u64, 5), sim_clock.now().tick);
    try testing.expectEqual(@as(u64, 7), (try sim_clock.advance(.init(2))).tick);
    try testing.expectEqual(@as(u64, 7), sim_clock.now().tick);
}

test "logical clock jump rejects backwards motion" {
    var sim_clock = SimClock.init(LogicalTime.init(10));
    try testing.expectError(error.InvalidInput, sim_clock.jumpTo(.init(9)));
    try testing.expectEqual(@as(u64, 10), (try sim_clock.jumpTo(.init(10))).tick);
}

test "logical clock detects overflow on advance" {
    var sim_clock = SimClock.init(LogicalTime.init(std.math.maxInt(u64)));
    try testing.expectError(error.Overflow, sim_clock.advance(.init(1)));
}

test "realtime view projects bounded offset and drift from a reference time" {
    const realtime = try RealtimeView.init(.{
        .reference_time = .init(10),
        .offset_ticks = 3,
        .drift_ppm = 200_000,
    });

    try testing.expectEqual(@as(u64, 15), realtime.monotonicNow(SimClock.init(.init(15))).tick);
    try testing.expectEqual(@as(u64, 19), (try realtime.realtimeAt(.init(15))).tick);
    try testing.expectEqual(@as(u64, 6), (try realtime.elapsedBetween(.init(10), .init(15))).ticks);
}

test "realtime view deadlines diverge under fast and slow observers" {
    var sim_clock = SimClock.init(.init(100));
    const fast = try RealtimeView.init(.{
        .reference_time = .init(100),
        .drift_ppm = 200_000,
    });
    const slow = try RealtimeView.init(.{
        .reference_time = .init(100),
        .drift_ppm = -100_000,
    });

    const fast_deadline = try fast.deadlineAfter(sim_clock.now(), .init(10));
    const slow_deadline = try slow.deadlineAfter(sim_clock.now(), .init(10));

    _ = try sim_clock.advance(.init(9));
    try testing.expect(try fast.hasReached(sim_clock, fast_deadline));
    try testing.expect(!(try slow.hasReached(sim_clock, slow_deadline)));
    try testing.expectEqual(@as(u64, 10), (try fast.elapsedBetween(.init(100), sim_clock.now())).ticks);
    try testing.expectEqual(@as(u64, 8), (try slow.elapsedBetween(.init(100), sim_clock.now())).ticks);

    _ = try sim_clock.advance(.init(3));
    try testing.expect(try slow.hasReached(sim_clock, slow_deadline));
}

test "realtime view rejects invalid drift or underflowing realtime" {
    try testing.expectError(error.InvalidInput, RealtimeView.init(.{
        .drift_ppm = drift_ppm_limit + 1,
    }));

    const underflow = try RealtimeView.init(.{
        .offset_ticks = -5,
    });
    try testing.expectError(error.InvalidInput, underflow.realtimeAt(.init(0)));
}
