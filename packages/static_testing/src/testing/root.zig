//! Testing exports for deterministic seeds, identity, traces, replay, corpus,
//! reduction, fuzzing, process drivers, and simulation helpers.

/// Stable deterministic seed parsing, formatting, and derivation.
pub const seed = @import("seed.zig");
/// Stable run identity and hashing helpers.
pub const identity = @import("identity.zig");
/// Bounded trace storage and trace export helpers.
pub const trace = @import("trace.zig");
/// Versioned replay-artifact encoding and decoding.
pub const replay_artifact = @import("replay_artifact.zig");
/// Checker vocabulary shared by replay and fuzz execution.
pub const checker = @import("checker.zig");
/// Deterministic directory failure bundles over replay artifacts and typed `ZON` sidecars.
pub const failure_bundle = @import("failure_bundle.zig");
/// High-level replay execution and trace matching.
pub const replay_runner = @import("replay_runner.zig");
/// Deterministic corpus naming and persistence helpers.
pub const corpus = @import("corpus.zig");
/// Deterministic fixed-point reduction helpers.
pub const reducer = @import("reducer.zig");
/// Deterministic fuzz orchestration over bounded seeds and persistence.
pub const fuzz_runner = @import("fuzz_runner.zig");
/// Deterministic sequential state-machine harness with recorded-action replay.
pub const model = @import("model.zig");
/// Deterministic repair/liveness execution helpers with typed pending reasons.
pub const liveness = @import("liveness.zig");
/// Bounded reassembly of out-of-order effects into one expected sequence.
pub const ordered_effect = @import("ordered_effect.zig");
/// Bounded temporal/property assertions over deterministic traces.
pub const temporal = @import("temporal.zig");
/// Deterministic system/e2e composition harness over shared fixtures and bundles.
pub const system = @import("system.zig");
/// Deterministic swarm orchestration over bounded seeds and weighted variants.
pub const swarm_runner = @import("swarm_runner.zig");
/// Binary request and response header encoding for process drivers.
pub const driver_protocol = @import("driver_protocol.zig");
/// Child-process lifecycle and request/response orchestration.
pub const process_driver = @import("process_driver.zig");
/// Deterministic simulation building blocks.
pub const sim = @import("sim/root.zig");

test {
    _ = seed;
    _ = identity;
    _ = trace;
    _ = replay_artifact;
    _ = checker;
    _ = failure_bundle;
    _ = replay_runner;
    _ = corpus;
    _ = reducer;
    _ = fuzz_runner;
    _ = model;
    _ = liveness;
    _ = ordered_effect;
    _ = temporal;
    _ = system;
    _ = swarm_runner;
    _ = driver_protocol;
    _ = process_driver;
    _ = sim;
}
