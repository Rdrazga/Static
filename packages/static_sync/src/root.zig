//! Synchronization, cancellation, and waiting primitives reused by higher-level runtime packages.
//!
//! Ownership rule:
//! - Use `std.Thread.Mutex` and other raw std thread primitives directly.
//! - Use `std.Thread.Condition` directly for app-local host wait/signal code.
//! - Use `static_sync.condvar` only when the package boundary needs capability
//!   gating or a stable unavailable shape across single-threaded / no-backend builds.
//! - Use `static_sync.grant` for bounded capability/authorization contracts that
//!   travel with runtime coordination code; it is not a replacement for thread
//!   synchronization primitives.
//! - Use `static_sync` for capability-gated waiting, cancellation, bounded coordination,
//!   and other policy-rich synchronization surfaces.

pub const backoff = @import("sync/backoff.zig");
pub const padded_atomic = @import("sync/padded_atomic.zig");
pub const seqlock = @import("sync/seqlock.zig");
pub const once = @import("sync/once.zig");
pub const cancel = @import("sync/cancel.zig");
pub const event = @import("sync/event.zig");
pub const semaphore = @import("sync/semaphore.zig");
pub const condvar = @import("sync/condvar.zig");
pub const wait_queue = @import("sync/wait_queue.zig");
pub const barrier = @import("sync/barrier.zig");
pub const grant = @import("sync/grant.zig");
pub const capability = grant;
pub const caps = @import("sync/caps.zig");

test {
    _ = backoff;
    _ = padded_atomic;
    _ = seqlock;
    _ = once;
    _ = cancel;
    _ = event;
    _ = semaphore;
    _ = condvar;
    _ = wait_queue;
    _ = barrier;
    _ = grant;
    _ = capability;
    _ = caps;
}
