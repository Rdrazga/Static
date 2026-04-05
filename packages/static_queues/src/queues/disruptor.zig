//! Disruptor: lock-free single-producer, multi-consumer ring buffer.
//!
//! Capacity: fixed at init time; must be a power of two (enables bitmask wrap-around).
//! Thread safety: single producer (trySend); multiple registered consumers (tryRecv); no mutex on the hot path.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full or empty.
//! Send cost: `trySend` scans active consumers to compute backpressure, so it is O(consumers_max).
//!
//! Choose this when:
//! - You can guarantee exactly one producer and need lower hot-path contention.
//! - You need fanout with per-consumer progress tracking and lock-free delivery.
//! - You accept stricter producer contract enforcement in exchange for higher throughput.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const ring = @import("ring_buffer.zig");
const memory = @import("static_memory");
const sync = @import("static_sync");
const qi = @import("queue_internal.zig");
const contracts = @import("../contracts.zig");

pub const Error = ring.Error;

pub fn Disruptor(comptime T: type) type {
    // Guard against zero-size types: the ring buffer requires addressable storage
    // to hold published items, and capacity must map to real bytes.
    comptime {
        assert(@sizeOf(T) > 0);
        assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();
        const AtomicSeq = std.atomic.Value(u64);
        const AtomicFlag = std.atomic.Value(usize);

        pub const Element = T;
        pub const ConsumerId = usize;
        pub const concurrency: contracts.Concurrency = .spmc_registered_fanout;
        pub const is_lock_free = true;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const TrySendError = error{ WouldBlock, Overflow };
        pub const TryRecvError = error{WouldBlock};
        pub const Config = struct {
            capacity: usize,
            consumers_max: usize = 8,
            budget: ?*memory.budget.Budget = null,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        registration_mutex: std.Thread.Mutex = .{},
        buf: []T,
        consumer_seq: []AtomicSeq,
        consumer_active: []AtomicFlag,
        write_seq: u64 = 0,
        // Placed on its own cache line: the producer writes this on every trySend
        // while all consumers read it on every tryRecv. Without padding, writes
        // by the producer would invalidate each consumer's cache line.
        published_seq: AtomicSeq align(std.atomic.cache_line) = AtomicSeq.init(0),
        sending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            if (cfg.capacity < 2) return error.InvalidConfig;
            if (!std.math.isPowerOfTwo(cfg.capacity)) return error.InvalidConfig;
            if (cfg.consumers_max == 0) return error.InvalidConfig;

            const buf_bytes = std.math.mul(usize, cfg.capacity, @sizeOf(T)) catch return error.Overflow;
            const seq_bytes = std.math.mul(usize, cfg.consumers_max, @sizeOf(AtomicSeq)) catch return error.Overflow;
            const active_bytes = std.math.mul(usize, cfg.consumers_max, @sizeOf(AtomicFlag)) catch return error.Overflow;
            const consumer_bytes = std.math.add(usize, seq_bytes, active_bytes) catch return error.Overflow;
            const total_bytes = std.math.add(usize, buf_bytes, consumer_bytes) catch return error.Overflow;

            try qi.tryReserveBudget(cfg.budget, total_bytes);

            errdefer if (cfg.budget) |budget| budget.release(total_bytes);

            const buf = allocator.alloc(T, cfg.capacity) catch return error.OutOfMemory;
            errdefer allocator.free(buf);

            const consumer_seq = allocator.alloc(AtomicSeq, cfg.consumers_max) catch return error.OutOfMemory;
            errdefer allocator.free(consumer_seq);
            for (consumer_seq) |*seq| {
                seq.* = AtomicSeq.init(0);
            }

            const consumer_active = allocator.alloc(AtomicFlag, cfg.consumers_max) catch return error.OutOfMemory;
            errdefer allocator.free(consumer_active);
            for (consumer_active) |*active| {
                active.* = AtomicFlag.init(0);
            }

            const self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
                .buf = buf,
                .consumer_seq = consumer_seq,
                .consumer_active = consumer_active,
            };
            // Postcondition: buffer is power-of-two sized as required by seqToIndex.
            assert(std.math.isPowerOfTwo(self.buf.len));
            // Postcondition: write_seq and published_seq start at zero; no items published yet.
            assert(self.write_seq == 0);
            assert(self.published_seq.load(.monotonic) == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: all allocations must still be valid.
            assert(self.buf.len > 0);
            assert(self.consumer_seq.len > 0);
            const buf_bytes = qi.bytesForItems(self.buf.len, @sizeOf(T));
            const seq_bytes = qi.bytesForItems(self.consumer_seq.len, @sizeOf(AtomicSeq));
            const active_bytes = qi.bytesForItems(self.consumer_active.len, @sizeOf(AtomicFlag));
            const consumer_bytes = qi.addBytesExact(seq_bytes, active_bytes);
            const total_bytes = qi.addBytesExact(buf_bytes, consumer_bytes);

            if (self.budget) |budget| {
                budget.release(total_bytes);
            }
            self.allocator.free(self.consumer_active);
            self.allocator.free(self.consumer_seq);
            self.allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn addConsumer(self: *Self) error{NoSpaceLeft}!ConsumerId {
            self.registration_mutex.lock();
            defer self.registration_mutex.unlock();

            // Precondition: the consumer slot array must be valid.
            assert(self.consumer_active.len > 0);
            const start_seq = self.published_seq.load(.acquire);
            var consumer_id: usize = 0;
            while (consumer_id < self.consumer_active.len) : (consumer_id += 1) {
                const active = self.consumer_active[consumer_id].load(.acquire);
                if (active == 0) {
                    self.consumer_seq[consumer_id].store(start_seq, .release);
                    self.consumer_active[consumer_id].store(1, .release);
                    // Postcondition: the returned id is a valid slot index.
                    assert(consumer_id < self.consumer_active.len);
                    return consumer_id;
                }
            }
            return error.NoSpaceLeft;
        }

        pub fn removeConsumer(self: *Self, consumer_id: ConsumerId) void {
            self.registration_mutex.lock();
            defer self.registration_mutex.unlock();

            self.assertActiveConsumer(consumer_id);
            // Precondition: consumer_id is in the valid slot range (assertActiveConsumer above).
            assert(consumer_id < self.consumer_active.len);
            const seq = self.published_seq.load(.acquire);
            self.consumer_seq[consumer_id].store(seq, .release);
            self.consumer_active[consumer_id].store(0, .release);
            // Postcondition: the slot is now inactive.
            assert(self.consumer_active[consumer_id].load(.monotonic) == 0);
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            const was_sending = self.sending.swap(true, .acquire);
            if (was_sending) {
                @panic("disruptor concurrent trySend detected; single-producer contract violated");
            }
            defer self.sending.store(false, .release);
            // Precondition: write_seq has room to advance without wrapping u64.
            assert(self.write_seq < std.math.maxInt(u64));
            const next_write_seq = std.math.add(u64, self.write_seq, 1) catch return error.Overflow;
            const min_read_seq = self.minReadSeq() orelse next_write_seq;
            assert(next_write_seq >= min_read_seq);
            const in_flight = next_write_seq - min_read_seq;
            if (in_flight > self.buf.len) return error.WouldBlock;

            const index = self.seqToIndex(next_write_seq);
            self.buf[index] = value;
            self.published_seq.store(next_write_seq, .release);
            self.write_seq = next_write_seq;
            // Postcondition: published_seq advanced to the sequence we just wrote.
            assert(self.published_seq.load(.monotonic) == next_write_seq);
        }

        pub fn tryRecv(self: *Self, consumer_id: ConsumerId) TryRecvError!T {
            self.assertActiveConsumer(consumer_id);

            const read_seq = self.consumer_seq[consumer_id].load(.monotonic);
            assert(read_seq < std.math.maxInt(u64));
            const want_seq = read_seq + 1;
            const published = self.published_seq.load(.acquire);
            if (published < want_seq) return error.WouldBlock;

            const index = self.seqToIndex(want_seq);
            const value = self.buf[index];
            self.consumer_seq[consumer_id].store(want_seq, .release);
            // Postcondition: the consumer's sequence advanced to exactly want_seq.
            assert(self.consumer_seq[consumer_id].load(.monotonic) == want_seq);
            return value;
        }

        pub fn pending(self: *Self, consumer_id: ConsumerId) usize {
            self.assertActiveConsumer(consumer_id);
            const read_seq = self.consumer_seq[consumer_id].load(.acquire);
            const published = self.published_seq.load(.acquire);
            assert(published >= read_seq);
            const pending_seq = published - read_seq;
            assert(pending_seq <= self.buf.len);
            return @intCast(pending_seq);
        }

        pub fn activeConsumerCount(self: *const Self) usize {
            var guard = qi.lockConstMutex(&self.registration_mutex);
            defer guard.unlock();

            var active_count: usize = 0;
            var consumer_id: usize = 0;
            while (consumer_id < self.consumer_active.len) : (consumer_id += 1) {
                if (self.consumer_active[consumer_id].load(.acquire) == 1) {
                    active_count += 1;
                }
            }
            assert(active_count <= self.consumer_active.len);
            return active_count;
        }

        pub fn capacity(self: *const Self) usize {
            // Invariant: capacity is always a power-of-two (enforced in init).
            assert(self.buf.len > 0);
            assert(std.math.isPowerOfTwo(self.buf.len));
            assert(@intFromPtr(self.buf.ptr) != 0);
            return self.buf.len;
        }

        fn minReadSeq(self: *Self) ?u64 {
            var has_active = false;
            var min_seq: u64 = 0;

            var consumer_id: usize = 0;
            while (consumer_id < self.consumer_active.len) : (consumer_id += 1) {
                const active = self.consumer_active[consumer_id].load(.acquire);
                if (active == 0) continue;

                const seq = self.consumer_seq[consumer_id].load(.acquire);
                if (!has_active) {
                    has_active = true;
                    min_seq = seq;
                } else if (seq < min_seq) {
                    min_seq = seq;
                }
            }
            if (!has_active) return null;
            return min_seq;
        }

        fn seqToIndex(self: Self, seq: u64) usize {
            assert(self.buf.len > 0);
            const capacity_u64: u64 = @intCast(self.buf.len);
            const index_u64 = seq % capacity_u64;
            return @intCast(index_u64);
        }

        fn assertActiveConsumer(self: *Self, consumer_id: ConsumerId) void {
            assert(consumer_id < self.consumer_active.len);
            const active = self.consumer_active[consumer_id].load(.acquire);
            assert(active == 1);
        }
    };
}

test "disruptor fanout preserves per-consumer ordering" {
    var d = try Disruptor(u8).init(testing.allocator, .{
        .capacity = 8,
        .consumers_max = 2,
    });
    defer d.deinit();

    const c0 = try d.addConsumer();
    const c1 = try d.addConsumer();

    try d.trySend(1);
    try d.trySend(2);
    try d.trySend(3);

    try testing.expectEqual(@as(u8, 1), try d.tryRecv(c0));
    try testing.expectEqual(@as(u8, 2), try d.tryRecv(c0));
    try testing.expectEqual(@as(u8, 3), try d.tryRecv(c0));

    try testing.expectEqual(@as(u8, 1), try d.tryRecv(c1));
    try testing.expectEqual(@as(u8, 2), try d.tryRecv(c1));
    try testing.expectEqual(@as(u8, 3), try d.tryRecv(c1));
}

test "disruptor backpressures on the slowest active consumer" {
    var d = try Disruptor(u8).init(testing.allocator, .{
        .capacity = 2,
        .consumers_max = 2,
    });
    defer d.deinit();

    const slow = try d.addConsumer();
    const fast = try d.addConsumer();

    try d.trySend(10);
    try d.trySend(11);
    try testing.expectError(error.WouldBlock, d.trySend(12));

    try testing.expectEqual(@as(u8, 10), try d.tryRecv(fast));
    try testing.expectError(error.WouldBlock, d.trySend(12));

    try testing.expectEqual(@as(u8, 10), try d.tryRecv(slow));
    try d.trySend(12);
}

test "disruptor removeConsumer releases producer backpressure" {
    var d = try Disruptor(u8).init(testing.allocator, .{
        .capacity = 2,
        .consumers_max = 2,
    });
    defer d.deinit();

    const slow = try d.addConsumer();
    const fast = try d.addConsumer();

    try d.trySend(20);
    try d.trySend(21);
    try testing.expectError(error.WouldBlock, d.trySend(22));

    d.removeConsumer(slow);
    try testing.expectEqual(@as(u8, 20), try d.tryRecv(fast));
    try d.trySend(22);
}

test "disruptor pending tracks unread values per consumer" {
    var d = try Disruptor(u8).init(testing.allocator, .{
        .capacity = 8,
        .consumers_max = 1,
    });
    defer d.deinit();

    const consumer = try d.addConsumer();
    try testing.expectEqual(@as(usize, 0), d.pending(consumer));

    try d.trySend(1);
    try d.trySend(2);
    try testing.expectEqual(@as(usize, 2), d.pending(consumer));

    _ = try d.tryRecv(consumer);
    try testing.expectEqual(@as(usize, 1), d.pending(consumer));
}

test "disruptor allows publishing with no consumers (late joiners start at the tip)" {
    var d = try Disruptor(u8).init(testing.allocator, .{
        .capacity = 8,
        .consumers_max = 1,
    });
    defer d.deinit();

    try d.trySend(1);
    try d.trySend(2);

    const c = try d.addConsumer();
    try testing.expectError(error.WouldBlock, d.tryRecv(c));

    try d.trySend(3);
    try testing.expectEqual(@as(u8, 3), try d.tryRecv(c));
}

test "disruptor validates configuration bounds" {
    try testing.expectError(error.InvalidConfig, Disruptor(u8).init(testing.allocator, .{
        .capacity = 0,
        .consumers_max = 1,
    }));
    try testing.expectError(error.InvalidConfig, Disruptor(u8).init(testing.allocator, .{
        .capacity = 3,
        .consumers_max = 1,
    }));
    try testing.expectError(error.InvalidConfig, Disruptor(u8).init(testing.allocator, .{
        .capacity = 4,
        .consumers_max = 0,
    }));
}

test "disruptor addConsumer enforces max and reuses removed slots" {
    var d = try Disruptor(u8).init(testing.allocator, .{
        .capacity = 4,
        .consumers_max = 1,
    });
    defer d.deinit();

    const only = try d.addConsumer();
    try testing.expectEqual(@as(usize, 0), only);
    try testing.expectError(error.NoSpaceLeft, d.addConsumer());

    d.removeConsumer(only);
    const reused = try d.addConsumer();
    try testing.expectEqual(@as(usize, 0), reused);
}

test "disruptor activeConsumerCount reflects add and remove" {
    var d = try Disruptor(u8).init(testing.allocator, .{
        .capacity = 8,
        .consumers_max = 3,
    });
    defer d.deinit();

    try testing.expectEqual(@as(usize, 0), d.activeConsumerCount());
    const first = try d.addConsumer();
    const second = try d.addConsumer();
    _ = second;
    try testing.expectEqual(@as(usize, 2), d.activeConsumerCount());
    d.removeConsumer(first);
    try testing.expectEqual(@as(usize, 1), d.activeConsumerCount());
}
