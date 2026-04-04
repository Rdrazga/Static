pub const try_queue_conformance = @import("try_queue_conformance.zig");
pub const channel_conformance = @import("channel_conformance.zig");
pub const registered_fanout_ring_conformance = @import("registered_fanout_ring_conformance.zig");
pub const work_stealing_deque_conformance = @import("work_stealing_deque_conformance.zig");
pub const len_conformance = @import("len_conformance.zig");
pub const lock_free_stress = @import("lock_free_stress.zig");

const std = @import("std");
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

test "try queue conformance covers baseline queue family" {
    try try_queue_conformance.runTryQueueConformance(spsc_mod.SpscQueue(u16), std.testing.allocator, 3);
    try try_queue_conformance.runTryQueueConformance(mpsc_mod.MpscQueue(u16), std.testing.allocator, 3);
    try try_queue_conformance.runTryQueueConformance(lock_free_mpsc_mod.LockFreeMpscQueue(u16), std.testing.allocator, 4);
    try try_queue_conformance.runTryQueueConformance(spmc_mod.SpmcQueue(u16), std.testing.allocator, 4);
    try try_queue_conformance.runTryQueueConformance(mpmc_mod.MpmcQueue(u16), std.testing.allocator, 4);
    try try_queue_conformance.runTryQueueConformance(locked_mod.LockedQueue(u16), std.testing.allocator, 3);
}

test "len conformance keeps len within bounds" {
    try len_conformance.runLenConformance(spsc_mod.SpscQueue(u16), std.testing.allocator, 3);
    try len_conformance.runLenConformance(mpsc_mod.MpscQueue(u16), std.testing.allocator, 3);
    try len_conformance.runLenConformance(lock_free_mpsc_mod.LockFreeMpscQueue(u16), std.testing.allocator, 4);
    try len_conformance.runLenConformance(spmc_mod.SpmcQueue(u16), std.testing.allocator, 4);
    try len_conformance.runLenConformance(mpmc_mod.MpmcQueue(u16), std.testing.allocator, 4);
    try len_conformance.runLenConformance(locked_mod.LockedQueue(u16), std.testing.allocator, 3);
}

test "channel conformance validates close and wait contracts" {
    try channel_conformance.runChannelConformance(channel_mod.Channel(u16), std.testing.allocator, 2);
    try channel_conformance.runChannelConformance(spsc_channel_mod.SpscChannel(u16), std.testing.allocator, 2);
}

test "registered fanout ring conformance validates consumer semantics" {
    try registered_fanout_ring_conformance.runRegisteredFanoutRingConformance(
        broadcast_mod.Broadcast(u16),
        std.testing.allocator,
        4,
        2,
    );
    try registered_fanout_ring_conformance.runRegisteredFanoutRingConformance(
        disruptor_mod.Disruptor(u16),
        std.testing.allocator,
        4,
        2,
    );
}

test "work stealing deque conformance validates owner and thief operations" {
    try work_stealing_deque_conformance.runWorkStealingDequeConformance(
        deque_mod.WorkStealingDeque(u16),
        std.testing.allocator,
        3,
    );
    try work_stealing_deque_conformance.runWorkStealingDequeConformance(
        chase_lev_mod.ChaseLevDeque(u16),
        std.testing.allocator,
        4,
    );
}

test "lock-free stress tests validate bounded progress and conservation" {
    try lock_free_stress.runLockFreeMpscStress(std.testing.allocator, .{});
    try lock_free_stress.runChaseLevStress(std.testing.allocator, .{});
}

test {
    _ = try_queue_conformance;
    _ = channel_conformance;
    _ = registered_fanout_ring_conformance;
    _ = work_stealing_deque_conformance;
    _ = len_conformance;
    _ = lock_free_stress;
}
