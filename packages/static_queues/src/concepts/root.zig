pub const try_queue = @import("try_queue.zig");
pub const channel = @import("channel.zig");
pub const registered_fanout_ring = @import("registered_fanout_ring.zig");
pub const work_stealing_deque = @import("work_stealing_deque.zig");

const spsc_mod = @import("../queues/spsc.zig");
const mpsc_mod = @import("../queues/mpsc.zig");
const lock_free_mpsc_mod = @import("../queues/lock_free_mpsc.zig");
const spmc_mod = @import("../queues/spmc.zig");
const mpmc_mod = @import("../queues/mpmc.zig");
const locked_mod = @import("../queues/locked_queue.zig");
const channel_mod = @import("../queues/channel.zig");
const spsc_channel_mod = @import("../queues/spsc_channel.zig");
const broadcast_mod = @import("../queues/broadcast.zig");
const disruptor_mod = @import("../queues/disruptor.zig");
const deque_mod = @import("../queues/work_stealing_deque.zig");
const chase_lev_mod = @import("../queues/chase_lev_deque.zig");

test {
    _ = try_queue;
    _ = channel;
    _ = registered_fanout_ring;
    _ = work_stealing_deque;

    try_queue.requireTryQueue(spsc_mod.SpscQueue(u8), u8);
    try_queue.requireTryQueue(mpsc_mod.MpscQueue(u8), u8);
    try_queue.requireTryQueue(lock_free_mpsc_mod.LockFreeMpscQueue(u8), u8);
    try_queue.requireTryQueue(spmc_mod.SpmcQueue(u8), u8);
    try_queue.requireTryQueue(mpmc_mod.MpmcQueue(u8), u8);
    try_queue.requireTryQueue(locked_mod.LockedQueue(u8), u8);

    channel.requireChannel(channel_mod.Channel(u8), u8);
    channel.requireChannel(spsc_channel_mod.SpscChannel(u8), u8);

    registered_fanout_ring.requireRegisteredFanoutRing(broadcast_mod.Broadcast(u8), u8);
    registered_fanout_ring.requireRegisteredFanoutRing(disruptor_mod.Disruptor(u8), u8);

    work_stealing_deque.requireWorkStealingDeque(deque_mod.WorkStealingDeque(u8), u8);
    work_stealing_deque.requireWorkStealingDeque(chase_lev_mod.ChaseLevDeque(u8), u8);
}
