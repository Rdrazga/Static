//! `static_testing` provides deterministic test and benchmark infrastructure.
//!
//! Phase 4 scope:
//! - deterministic seeds, run identity, bounded traces, and replay artifacts;
//! - replay execution, corpus persistence, seed reduction, fuzz orchestration,
//!   and repair/liveness execution helpers; and
//! - in-process and process benchmark configuration, execution, statistics,
//!   comparison, export helpers, process drivers, and simulation primitives.
//!
//! Package boundary:
//! - use `std.testing` for ordinary assertions and unit tests;
//! - reuse `static_rng`, `static_profile`, `static_bits`, and `static_serial`
//!   instead of re-implementing their primitives here; and
//! - keep production runtime scheduler and executor semantics out of the
//!   deterministic simulation surface.
//!
//! Invalid-input policy:
//! - return `error.InvalidInput` / `error.InvalidConfig` for malformed external
//!   data, runtime-sized buffers, and caller-controlled operating inputs; and
//! - use assertions for programmer invariants on trusted configuration assembled
//!   in code, especially hot-path callback contracts and bounded metadata.

const std = @import("std");
const core = @import("static_core");

/// Deterministic testing, replay, fuzzing, process-driver, and simulation APIs.
pub const testing = @import("testing/root.zig");
/// In-process and process benchmark configuration, execution, and export APIs.
pub const bench = @import("bench/root.zig");

test {
    _ = core;
    _ = testing;
    _ = bench;
}

test "public root exports are wired consistently" {
    const seed = try testing.seed.parseSeed("0x2a");
    const identity = testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "root_smoke",
        .seed = seed,
        .build_mode = .debug,
    });
    const realtime = try testing.sim.clock.RealtimeView.init(.{
        .offset_ticks = 5,
    });
    var sequencer = testing.ordered_effect.OrderedEffectSequencer(u8, 2).init();
    var next_expected_sequence_no: u64 = 0;
    try std.testing.expectEqual(@as(u64, 42), seed.value);
    try std.testing.expectEqualStrings("static_testing", identity.package_name);
    try std.testing.expectEqual(bench.config.BenchmarkMode.smoke, bench.config.BenchmarkMode.smoke);
    try std.testing.expectEqual(@as(u64, 0), testing.sim.clock.SimClock.init(.init(0)).now().tick);
    try std.testing.expectEqual(@as(u64, 5), (try realtime.realtimeAt(.init(0))).tick);
    try std.testing.expectEqual(testing.ordered_effect.InsertStatus.accepted, sequencer.insert(next_expected_sequence_no, 0, 7));
    try std.testing.expectEqual(@as(u8, 7), sequencer.popReady(&next_expected_sequence_no).?.effect);
    try std.testing.expectEqual(testing.liveness.ExecutionPhase.repair, testing.liveness.ExecutionPhase.repair);
}
