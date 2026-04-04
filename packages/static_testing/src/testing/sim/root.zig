//! Simulation exports for deterministic logical time, timers, scheduling, and fault orchestration.

/// Deterministic logical clock and duration primitives.
pub const clock = @import("clock.zig");
/// Delayed ready-item queue built over the timer wheel.
pub const timer_queue = @import("timer_queue.zig");
/// Bounded typed mailbox for simulation plumbing.
pub const mailbox = @import("mailbox.zig");
/// Bounded deterministic message-delivery simulator over logical time.
pub const network_link = @import("network_link.zig");
/// Bounded deterministic storage completion simulator over logical time.
pub const storage_lane = @import("storage_lane.zig");
/// Bounded deterministic storage durability simulator over logical time.
pub const storage_durability = @import("storage_durability.zig");
/// Bounded deterministic retry/backpressure helper over logical time.
pub const retry_queue = @import("retry_queue.zig");
/// Deterministic fault-script storage and due-fault lookup.
pub const fault_script = @import("fault_script.zig");
/// Shared event-loop fixture over fixed-capacity caller-owned storage.
pub const fixture = @import("fixture.zig");
/// Stable checkpoint digest helpers.
pub const checkpoint = @import("checkpoint.zig");
/// Deterministic ready-set scheduling and replay support.
pub const scheduler = @import("scheduler.zig");
/// Bounded portfolio exploration over scheduler modes and seeds.
pub const explore = @import("explore.zig");
/// Event-loop coordination over clocks, timers, scheduling, and fault scripts.
pub const event_loop = @import("event_loop.zig");

test {
    _ = clock;
    _ = timer_queue;
    _ = mailbox;
    _ = network_link;
    _ = storage_lane;
    _ = storage_durability;
    _ = retry_queue;
    _ = fault_script;
    _ = fixture;
    _ = checkpoint;
    _ = scheduler;
    _ = explore;
    _ = event_loop;
}
