//! Bounded queues, channels, adapters, and queue-testing helpers for message handoff.

pub const core = @import("static_core");
pub const memory = @import("static_memory");
pub const sync = @import("static_sync");
pub const contracts = @import("contracts.zig");
pub const concepts = @import("concepts/root.zig");
pub const adapters = @import("adapters/root.zig");
pub const testing = @import("testing/root.zig");
pub const queue_families = @import("queues/families.zig");
pub const caps = @import("queues/caps.zig");

pub const ring_buffer = @import("queues/ring_buffer.zig");
pub const spsc = @import("queues/spsc.zig");
pub const mpsc = @import("queues/mpsc.zig");
pub const lock_free_mpsc = @import("queues/lock_free_mpsc.zig");
pub const spmc = @import("queues/spmc.zig");
pub const mpmc = @import("queues/mpmc.zig");
pub const qos_mpmc = @import("queues/qos_mpmc.zig");
pub const locked_queue = @import("queues/locked_queue.zig");
pub const channel = @import("queues/channel.zig");
pub const spsc_channel = @import("queues/spsc_channel.zig");
pub const wait_set = @import("queues/wait_set.zig");
pub const intrusive = @import("queues/intrusive.zig");
pub const broadcast = @import("queues/broadcast.zig");
pub const inbox_outbox = @import("queues/inbox_outbox.zig");
pub const disruptor = @import("queues/disruptor.zig");
pub const work_stealing_deque = @import("queues/work_stealing_deque.zig");
pub const chase_lev_deque = @import("queues/chase_lev_deque.zig");
pub const priority_queue = @import("queues/priority_queue.zig");

test {
    _ = core;
    _ = memory;
    _ = sync;
    _ = contracts;
    _ = concepts;
    _ = adapters;
    _ = testing;
    _ = queue_families;
    _ = caps;
    _ = ring_buffer;
    _ = spsc;
    _ = mpsc;
    _ = lock_free_mpsc;
    _ = spmc;
    _ = mpmc;
    _ = qos_mpmc;
    _ = locked_queue;
    _ = channel;
    _ = spsc_channel;
    _ = wait_set;
    _ = intrusive;
    _ = broadcast;
    _ = inbox_outbox;
    _ = disruptor;
    _ = work_stealing_deque;
    _ = chase_lev_deque;
    _ = priority_queue;
}
