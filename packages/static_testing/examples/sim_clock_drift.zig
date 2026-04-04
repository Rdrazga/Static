const std = @import("std");
const testing = @import("static_testing");

const sim_clock = testing.testing.sim.clock;

pub fn main() !void {
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

    _ = try clock.advance(.init(9));
    std.debug.assert(try fast.hasReached(clock, fast_deadline));
    std.debug.assert(!(try slow.hasReached(clock, slow_deadline)));
    std.debug.assert((try fast.realtimeNow(clock)).tick == 112);
    std.debug.assert((try slow.realtimeNow(clock)).tick == 106);

    _ = try clock.advance(.init(3));
    std.debug.assert(try slow.hasReached(clock, slow_deadline));
    std.debug.assert((try slow.realtimeNow(clock)).tick == 108);

    std.debug.print(
        "clock drift kept monotonic time at {d} while fast and slow realtime views expired the same timeout at different observed ticks\n",
        .{clock.now().tick},
    );
}
