const std = @import("std");
const testing = @import("static_testing");

const sim_clock = testing.testing.sim.clock;

test "clock drift profiles make lease timeouts diverge deterministically" {
    var clock = sim_clock.SimClock.init(.init(100));
    const fast = try sim_clock.RealtimeView.init(.{
        .reference_time = .init(100),
        .offset_ticks = 2,
        .drift_ppm = 200_000,
    });
    const slow = try sim_clock.RealtimeView.init(.{
        .reference_time = .init(100),
        .offset_ticks = -2,
        .drift_ppm = -100_000,
    });

    const timeout = sim_clock.LogicalDuration.init(10);
    const fast_deadline = try fast.deadlineAfter(clock.now(), timeout);
    const slow_deadline = try slow.deadlineAfter(clock.now(), timeout);

    try std.testing.expectEqual(@as(u64, 112), fast_deadline.tick);
    try std.testing.expectEqual(@as(u64, 108), slow_deadline.tick);

    _ = try clock.advance(.init(9));

    try std.testing.expectEqual(@as(u64, 112), (try fast.realtimeNow(clock)).tick);
    try std.testing.expectEqual(@as(u64, 106), (try slow.realtimeNow(clock)).tick);
    try std.testing.expect(try fast.hasReached(clock, fast_deadline));
    try std.testing.expect(!(try slow.hasReached(clock, slow_deadline)));
    try std.testing.expectEqual(@as(u64, 10), (try fast.elapsedBetween(.init(100), clock.now())).ticks);
    try std.testing.expectEqual(@as(u64, 8), (try slow.elapsedBetween(.init(100), clock.now())).ticks);

    _ = try clock.advance(.init(3));

    try std.testing.expectEqual(@as(u64, 108), (try slow.realtimeNow(clock)).tick);
    try std.testing.expect(try slow.hasReached(clock, slow_deadline));
}
