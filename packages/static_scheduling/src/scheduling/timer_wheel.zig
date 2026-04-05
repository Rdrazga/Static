//! Bounded deterministic timer wheel.
//!
//! Timers are scheduled by tick delay. `tick` advances the wheel by one tick and
//! drains entries due at that tick in FIFO schedule order.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const collections = @import("static_collections");

pub const TimerId = collections.handle.Handle;
const invalid_slot = std.math.maxInt(u32);

pub const TimerError = error{
    InvalidConfig,
    OutOfMemory,
    NoSpaceLeft,
    NotFound,
    Overflow,
};

pub fn TimerWheel(comptime T: type) type {
    comptime {
        assert(@sizeOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Entry = T;
        pub const Config = struct {
            buckets: u32,
            entries_max: u32,
        };

        const SlotState = enum {
            free,
            scheduled,
        };

        const Slot = struct {
            state: SlotState = .free,
            bucket_index: u32 = 0,
            rounds_remaining: u64 = 0,
            next: u32 = invalid_slot,
            prev: u32 = invalid_slot,
            entry: T = undefined,
        };

        allocator: std.mem.Allocator,
        cfg: Config,
        now_tick: u64 = 0,

        slots: []Slot,
        bucket_head: []u32,
        bucket_tail: []u32,
        index_pool: collections.index_pool.IndexPool,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) TimerError!Self {
            if (cfg.buckets == 0) return error.InvalidConfig;
            if (cfg.entries_max == 0) return error.InvalidConfig;

            const slots = allocator.alloc(Slot, cfg.entries_max) catch return error.OutOfMemory;
            errdefer allocator.free(slots);
            @memset(slots, .{});

            const bucket_head = allocator.alloc(u32, cfg.buckets) catch return error.OutOfMemory;
            errdefer allocator.free(bucket_head);
            const bucket_tail = allocator.alloc(u32, cfg.buckets) catch return error.OutOfMemory;
            errdefer allocator.free(bucket_tail);
            @memset(bucket_head, invalid_slot);
            @memset(bucket_tail, invalid_slot);

            const index_pool = collections.index_pool.IndexPool.init(allocator, .{ .slots_max = cfg.entries_max, .budget = null }) catch |err| switch (err) {
                error.InvalidConfig => return error.InvalidConfig,
                error.OutOfMemory => return error.OutOfMemory,
                error.NoSpaceLeft => unreachable,
                error.NotFound => unreachable,
                error.Overflow => unreachable,
            };
            errdefer {
                var owned_pool = index_pool;
                owned_pool.deinit();
            }

            return .{
                .allocator = allocator,
                .cfg = cfg,
                .slots = slots,
                .bucket_head = bucket_head,
                .bucket_tail = bucket_tail,
                .index_pool = index_pool,
            };
        }

        pub fn deinit(self: *Self) void {
            self.index_pool.deinit();
            self.allocator.free(self.bucket_tail);
            self.allocator.free(self.bucket_head);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn nowTick(self: *const Self) u64 {
            return self.now_tick;
        }

        pub fn schedule(self: *Self, entry: T, delay_ticks: u64) TimerError!TimerId {
            const id = self.index_pool.allocate() catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig, error.OutOfMemory, error.NotFound, error.Overflow => unreachable,
            };
            const slot_index = id.index;
            errdefer self.releaseSlot(id);

            const due_offset = std.math.add(u64, delay_ticks, 1) catch return error.Overflow;
            const due_tick = std.math.add(u64, self.now_tick, due_offset) catch return error.Overflow;
            const wheel_period = self.cfg.buckets;
            const bucket_index: u32 = @intCast(@mod(due_tick, wheel_period));
            const rounds_remaining: u64 = @divFloor(due_offset - 1, wheel_period);

            var slot = &self.slots[slot_index];
            slot.state = .scheduled;
            slot.bucket_index = bucket_index;
            slot.rounds_remaining = rounds_remaining;
            slot.entry = entry;
            slot.next = invalid_slot;
            slot.prev = invalid_slot;
            self.appendToBucket(slot_index, bucket_index);

            return id;
        }

        pub fn cancel(self: *Self, id: TimerId) TimerError!T {
            const slot_index = self.validateId(id) catch return error.NotFound;
            var slot = &self.slots[slot_index];
            if (slot.state != .scheduled) return error.NotFound;

            self.removeFromBucket(slot_index, slot.bucket_index);
            const entry = slot.entry;
            self.releaseSlot(id);
            return entry;
        }

        pub fn tick(self: *Self, out: []T) TimerError!u32 {
            const next_tick = std.math.add(u64, self.now_tick, 1) catch return error.Overflow;
            const bucket_index: u32 = @intCast(@mod(next_tick, self.cfg.buckets));
            const due_count = self.countDue(bucket_index);
            if (due_count > out.len) return error.NoSpaceLeft;

            self.now_tick = next_tick;
            return self.drainBucket(bucket_index, out);
        }

        fn releaseSlot(self: *Self, id: TimerId) void {
            const slot_index = self.index_pool.validate(id) catch unreachable;
            var slot = &self.slots[slot_index];
            slot.state = .free;
            slot.bucket_index = 0;
            slot.rounds_remaining = 0;
            slot.next = invalid_slot;
            slot.prev = invalid_slot;
            self.index_pool.release(id) catch unreachable;
        }

        fn validateId(self: *Self, id: TimerId) error{NotFound}!u32 {
            const slot_index = self.index_pool.validate(id) catch return error.NotFound;
            if (slot_index >= self.slots.len) return error.NotFound;
            return slot_index;
        }

        fn appendToBucket(self: *Self, slot_index: u32, bucket_index: u32) void {
            assert(bucket_index < self.bucket_head.len);

            const tail_index = self.bucket_tail[bucket_index];
            if (tail_index == invalid_slot) {
                self.bucket_head[bucket_index] = slot_index;
                self.bucket_tail[bucket_index] = slot_index;
                return;
            }

            self.slots[tail_index].next = slot_index;
            self.slots[slot_index].prev = tail_index;
            self.bucket_tail[bucket_index] = slot_index;
        }

        fn removeFromBucket(self: *Self, slot_index: u32, bucket_index: u32) void {
            assert(bucket_index < self.bucket_head.len);
            const prev_index = self.slots[slot_index].prev;
            const next_index = self.slots[slot_index].next;

            if (prev_index == invalid_slot) {
                self.bucket_head[bucket_index] = next_index;
            } else {
                self.slots[prev_index].next = next_index;
            }

            if (next_index == invalid_slot) {
                self.bucket_tail[bucket_index] = prev_index;
            } else {
                self.slots[next_index].prev = prev_index;
            }

            self.slots[slot_index].next = invalid_slot;
            self.slots[slot_index].prev = invalid_slot;
        }

        fn countDue(self: *Self, bucket_index: u32) usize {
            var due_count: usize = 0;
            var cursor = self.bucket_head[bucket_index];
            while (cursor != invalid_slot) {
                const slot = self.slots[cursor];
                if (slot.rounds_remaining == 0 and slot.state == .scheduled) due_count += 1;
                cursor = slot.next;
            }
            return due_count;
        }

        fn drainBucket(self: *Self, bucket_index: u32, out: []T) u32 {
            var out_len: u32 = 0;
            var cursor = self.bucket_head[bucket_index];
            while (cursor != invalid_slot) {
                const next_cursor = self.slots[cursor].next;
                var slot = &self.slots[cursor];
                if (slot.state != .scheduled) {
                    cursor = next_cursor;
                    continue;
                }

                if (slot.rounds_remaining == 0) {
                    out[out_len] = slot.entry;
                    out_len += 1;
                    self.removeFromBucket(cursor, bucket_index);
                    const id = self.index_pool.handleForIndex(cursor) orelse unreachable;
                    self.releaseSlot(id);
                } else {
                    slot.rounds_remaining -= 1;
                }

                cursor = next_cursor;
            }
            return out_len;
        }
    };
}

test "timer wheel drains due timers in FIFO order" {
    var wheel = try TimerWheel(u32).init(testing.allocator, .{
        .buckets = 8,
        .entries_max = 8,
    });
    defer wheel.deinit();

    _ = try wheel.schedule(10, 0);
    _ = try wheel.schedule(20, 0);
    _ = try wheel.schedule(30, 0);

    var drained: [4]u32 = [_]u32{0} ** 4;
    const count = try wheel.tick(&drained);
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, drained[0..3]);
}

test "timer wheel supports long delays via rounds" {
    var wheel = try TimerWheel(u32).init(testing.allocator, .{
        .buckets = 4,
        .entries_max = 4,
    });
    defer wheel.deinit();

    _ = try wheel.schedule(55, 9);

    var drained: [1]u32 = [_]u32{0};
    var tick_index: u32 = 0;
    while (tick_index < 9) : (tick_index += 1) {
        const count = try wheel.tick(&drained);
        if (tick_index < 8) try testing.expectEqual(@as(u32, 0), count);
    }
    try testing.expectEqual(@as(u32, 1), try wheel.tick(&drained));
    try testing.expectEqual(@as(u32, 55), drained[0]);
}

test "timer wheel cancel returns scheduled entry and invalidates stale id" {
    var wheel = try TimerWheel(u32).init(testing.allocator, .{
        .buckets = 4,
        .entries_max = 2,
    });
    defer wheel.deinit();

    const id = try wheel.schedule(99, 0);
    try testing.expectEqual(@as(u32, 99), try wheel.cancel(id));
    try testing.expectError(error.NotFound, wheel.cancel(id));
}

test "timer wheel tick no space does not advance time" {
    var wheel = try TimerWheel(u32).init(testing.allocator, .{
        .buckets = 8,
        .entries_max = 8,
    });
    defer wheel.deinit();

    _ = try wheel.schedule(1, 0);
    _ = try wheel.schedule(2, 0);
    var tiny_out: [1]u32 = [_]u32{0};
    try testing.expectError(error.NoSpaceLeft, wheel.tick(&tiny_out));
    try testing.expectEqual(@as(u64, 0), wheel.nowTick());
}
