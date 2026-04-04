//! Demonstrates integration hooks: emitting named counters via a comptime callback
//! without importing static_profile in the emitting subsystem.
//!
//! The emitter (simulating a subsystem like static_memory) only calls hooks.emitCounter
//! with a comptime callback. The application wires up the callback at the top level.
const std = @import("std");
const profile = @import("static_profile");

// Simulated print sink — receives counter name + value, prints them.
// Does not import static_profile; the callback is comptime-typed.
const PrintSink = struct {
    fn emit(_: *@This(), name: []const u8, value: i64) void {
        std.debug.print("counter: {s} = {d}\n", .{ name, value });
    }
};

pub fn main() void {
    var sink = PrintSink{};

    // Single counter: emits "sys.mem_used = 1024".
    profile.hooks.emitCounter("sys", "mem_used", 1024, &sink, PrintSink.emit);

    // Counter group: emits "perf.triangles", "perf.draw_calls", "perf.frame_time".
    const vals = [_]i64{ 42_000, 128, 16 };
    profile.hooks.emitCounters("perf", &.{ "triangles", "draw_calls", "frame_time" }, &vals, &sink, PrintSink.emit);
}
