//! LockFreeMpscQueue: multi-producer, single-consumer lock-free bounded queue.
//!
//! Capacity: fixed at init time; must be a power of two >= 2.
//! Thread safety: multiple concurrent producers and a single consumer.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full or empty, or when
//! contention prevents progress within the configured retry bound.
//! Batch operations: intentionally omitted for lock-free queues; loop manually for explicit retry/fairness control.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const ring = @import("../ring_buffer.zig");
const memory = @import("static_memory");
const sync = @import("static_sync");
const qi = @import("../queue_internal.zig");
const contracts = @import("../../contracts.zig");

pub fn LockFreeMpscQueue(comptime T: type) type {
    comptime {
        assert(@sizeOf(T) > 0);
        assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();
        const AtomicSeq = std.atomic.Value(u64);

        pub const Element = T;
        pub const Error = ring.Error;
        pub const concurrency: contracts.Concurrency = .mpsc;
        pub const is_lock_free = true;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .approximate;
        pub const TrySendError = error{WouldBlock};
        pub const TryRecvError = error{WouldBlock};
        pub const Config = struct {
            capacity: usize,
            cas_retries_max: u32 = 1024,
            backoff_exponent_max: u8 = 0,
            budget: ?*memory.budget.Budget = null,
        };

        const Cell = struct {
            sequence: AtomicSeq,
            data: T,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        buffer: []Cell,
        buffer_mask: u64,
        cas_retries_max: u32,
        backoff_exponent_max: u8,

        head: AtomicSeq align(std.atomic.cache_line) = AtomicSeq.init(0),
        tail: AtomicSeq align(std.atomic.cache_line) = AtomicSeq.init(0),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            if (cfg.capacity < 2 or !std.math.isPowerOfTwo(cfg.capacity)) {
                return error.InvalidConfig;
            }
            if (!qi.capacityFitsSignedSequenceDistance(cfg.capacity)) {
                return error.InvalidConfig;
            }
            if (cfg.cas_retries_max == 0) {
                return error.InvalidConfig;
            }
            if (cfg.backoff_exponent_max > 16) {
                return error.InvalidConfig;
            }

            const bytes = qi.bytesForItems(cfg.capacity, @sizeOf(Cell));
            try qi.tryReserveBudget(cfg.budget, bytes);
            errdefer if (cfg.budget) |budget| budget.release(bytes);

            const buffer = allocator.alloc(Cell, cfg.capacity) catch return error.OutOfMemory;
            errdefer allocator.free(buffer);

            for (buffer, 0..) |*cell, i| {
                cell.sequence.store(@intCast(i), .monotonic);
            }

            const self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
                .buffer = buffer,
                .buffer_mask = @intCast(cfg.capacity - 1),
                .cas_retries_max = cfg.cas_retries_max,
                .backoff_exponent_max = cfg.backoff_exponent_max,
            };
            assert(self.buffer.len == cfg.capacity);
            assert(self.head.load(.monotonic) == 0);
            assert(self.tail.load(.monotonic) == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            assert(self.buffer.len > 0);
            if (self.budget) |budget| {
                budget.release(qi.bytesForItems(self.buffer.len, @sizeOf(Cell)));
            }
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            assert(self.buffer.len > 0);
            assert(std.math.isPowerOfTwo(self.buffer.len));
            return self.buffer.len;
        }

        pub fn len(self: *const Self) usize {
            const head_seq = self.head.load(.acquire);
            const tail_seq = self.tail.load(.acquire);
            const distance_signed = qi.seqDistanceSigned(tail_seq, head_seq);
            if (distance_signed <= 0) return 0;

            const distance: u64 = @intCast(distance_signed);
            const capacity_u64: u64 = @intCast(self.buffer.len);
            if (distance > capacity_u64) return self.buffer.len;
            return @intCast(distance);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == self.capacity();
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            var pos: u64 = self.tail.load(.monotonic);
            var backoff = sync.backoff.Backoff{ .exponent = 0, .max_exponent = self.backoff_exponent_max };
            var retries: u32 = 0;
            while (retries < self.cas_retries_max) : (retries += 1) {
                const cell = &self.buffer[@intCast(pos & self.buffer_mask)];
                const seq = cell.sequence.load(.acquire);
                const dif = qi.seqDistanceSigned(seq, pos);

                if (dif == 0) {
                    const pos_plus_1 = pos +% 1;
                    if (self.tail.cmpxchgWeak(pos, pos_plus_1, .monotonic, .monotonic) == null) {
                        break;
                    }
                    pos = self.tail.load(.monotonic);
                    backoff.step();
                } else if (dif < 0) {
                    return error.WouldBlock;
                } else {
                    pos = self.tail.load(.monotonic);
                    backoff.step();
                }
            }
            if (retries == self.cas_retries_max) return error.WouldBlock;

            const cell = &self.buffer[@intCast(pos & self.buffer_mask)];
            cell.data = value;
            cell.sequence.store(pos +% 1, .release);
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            var pos: u64 = self.head.load(.monotonic);
            var backoff = sync.backoff.Backoff{ .exponent = 0, .max_exponent = self.backoff_exponent_max };
            var retries: u32 = 0;
            while (retries < self.cas_retries_max) : (retries += 1) {
                const cell = &self.buffer[@intCast(pos & self.buffer_mask)];
                const seq = cell.sequence.load(.acquire);
                const pos_plus_1 = pos +% 1;
                const dif = qi.seqDistanceSigned(seq, pos_plus_1);

                if (dif == 0) {
                    const value = cell.data;
                    self.head.store(pos_plus_1, .monotonic);
                    const capacity_u64: u64 = @intCast(self.buffer.len);
                    cell.sequence.store(pos +% capacity_u64, .release);
                    return value;
                }
                if (dif < 0) {
                    return error.WouldBlock;
                }

                pos = self.head.load(.monotonic);
                backoff.step();
            }

            return error.WouldBlock;
        }
    };
}

test "lock-free mpsc queue wraparound and WouldBlock semantics" {
    var q = try LockFreeMpscQueue(u8).init(testing.allocator, .{ .capacity = 2 });
    defer q.deinit();

    try q.trySend(1);
    try q.trySend(2);
    try testing.expectError(error.WouldBlock, q.trySend(3));
    try testing.expectEqual(@as(u8, 1), try q.tryRecv());
    try q.trySend(3);
    try testing.expectEqual(@as(u8, 2), try q.tryRecv());
    try testing.expectEqual(@as(u8, 3), try q.tryRecv());
    try testing.expectError(error.WouldBlock, q.tryRecv());
}

test "lock-free mpsc queue rejects invalid retry config" {
    try testing.expectError(error.InvalidConfig, LockFreeMpscQueue(u8).init(testing.allocator, .{
        .capacity = 4,
        .cas_retries_max = 0,
    }));
}

test "lock-free mpsc queue introspection methods reflect queue state" {
    var q = try LockFreeMpscQueue(u8).init(testing.allocator, .{ .capacity = 2 });
    defer q.deinit();

    try testing.expectEqual(@as(usize, 2), q.capacity());
    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expect(q.isEmpty());
    try testing.expect(!q.isFull());

    try q.trySend(1);
    try testing.expect(!q.isEmpty());
    try testing.expect(!q.isFull());

    try q.trySend(2);
    try testing.expect(q.isFull());

    _ = try q.tryRecv();
    try testing.expect(!q.isFull());
}
