//! Profiling, tracing, and instrumentation helpers for bounded static systems.
//!
//! Current package boundary:
//! - implemented profiling surfaces live here: trace capture, counters, zones,
//!   hooks, and capability checks;
//! - deferred `thread_trace` and `binary_trace` work stays out of the live root
//!   until a concrete consumer promotes it into a real feature;
//! - binary serialization/export formats do not live here until a real binary
//!   profiling pipeline exists.

pub const trace = @import("profile/trace.zig");
pub const caps = @import("profile/caps.zig");
pub const zone = @import("profile/zone.zig");
pub const counter = @import("profile/counter.zig");
pub const hooks = @import("profile/hooks.zig");

test {
    _ = trace;
    _ = caps;
    _ = zone;
    _ = counter;
    _ = hooks;
}
