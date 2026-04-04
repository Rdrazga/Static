//! Broadcast: mutex-protected multi-producer, multi-consumer fanout ring buffer.
//!
//! Capacity: fixed at init time; must be a power of two (enables consistent bitmask
//! wrap-around matching Disruptor's indexing contract).
//! Thread safety: all operations are serialized by an internal mutex; safe for any number of producers and consumers.
//! If you can guarantee exactly one producer and want a lock-free hot path, prefer `Disruptor`.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full (all consumers must advance first) or empty.
//!
//! Choose this when:
//! - You need fanout semantics with simple, mutex-auditable control flow.
//! - Producer throughput is moderate and predictable behavior matters more than peak throughput.
//! - You want straightforward registration/backpressure semantics without lock-free sequence races.
const std = @import("std");
const ring = @import("ring_buffer.zig");
const memory = @import("static_memory");
const sync = @import("static_sync");
const qi = @import("queue_internal.zig");
const contracts = @import("../contracts.zig");

pub const Error = ring.Error;

pub fn Broadcast(comptime T: type) type {
    // Guard against zero-size types: the ring buffer requires addressable
    // storage and ZSTs would make byte-size calculations meaningless.
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
        std.debug.assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const ConsumerId = usize;
        pub const concurrency: contracts.Concurrency = .mpmc_registered_fanout;
        pub const is_lock_free = false;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const TrySendError = error{WouldBlock};
        pub const TryRecvError = error{WouldBlock};
        pub const Config = struct {
            capacity: usize,
            consumers_max: usize = 8,
            budget: ?*memory.budget.Budget = null,
        };

        const Consumer = struct {
            active: bool = false,
            read_seq: u64 = 0,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        mutex: std.Thread.Mutex = .{},
        buf: []T,
        consumers: []Consumer,
        write_seq: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            if (cfg.capacity == 0 or cfg.consumers_max == 0) return error.InvalidConfig;
            // Power-of-two capacity is required so that the bitmask index
            // (write_seq % buf.len) is consistent across the sequence space,
            // matching the contract established by Disruptor.
            if (!std.math.isPowerOfTwo(cfg.capacity)) return error.InvalidConfig;
            std.debug.assert(std.math.isPowerOfTwo(cfg.capacity));

            const buf_bytes = std.math.mul(usize, cfg.capacity, @sizeOf(T)) catch return error.Overflow;
            const consumers_bytes = std.math.mul(usize, cfg.consumers_max, @sizeOf(Consumer)) catch return error.Overflow;
            const total_bytes = std.math.add(usize, buf_bytes, consumers_bytes) catch return error.Overflow;
            try qi.tryReserveBudget(cfg.budget, total_bytes);

            errdefer if (cfg.budget) |budget| budget.release(total_bytes);

            const buf = allocator.alloc(T, cfg.capacity) catch return error.OutOfMemory;
            errdefer allocator.free(buf);

            const consumers = allocator.alloc(Consumer, cfg.consumers_max) catch return error.OutOfMemory;
            errdefer allocator.free(consumers);
            @memset(consumers, .{});

            const self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
                .buf = buf,
                .consumers = consumers,
            };
            // Postcondition: buffer is properly sized and write_seq starts at zero.
            std.debug.assert(self.buf.len == cfg.capacity);
            std.debug.assert(self.write_seq == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: buffer and consumer table must still be valid.
            std.debug.assert(self.buf.len > 0);
            std.debug.assert(self.consumers.len > 0);
            const buf_bytes = qi.bytesForItems(self.buf.len, @sizeOf(T));
            const consumers_bytes = qi.bytesForItems(self.consumers.len, @sizeOf(Consumer));
            const total_bytes = qi.addBytesExact(buf_bytes, consumers_bytes);
            if (self.budget) |budget| budget.release(total_bytes);
            self.allocator.free(self.buf);
            self.allocator.free(self.consumers);
            self.* = undefined;
        }

        pub fn addConsumer(self: *Self) error{NoSpaceLeft}!ConsumerId {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Precondition: the consumer table must be valid.
            std.debug.assert(self.consumers.len > 0);
            var index: usize = 0;
            while (index < self.consumers.len) : (index += 1) {
                if (!self.consumers[index].active) {
                    self.consumers[index].active = true;
                    self.consumers[index].read_seq = self.write_seq;
                    // Postcondition: the returned id is in bounds and the slot is now active.
                    std.debug.assert(index < self.consumers.len);
                    std.debug.assert(self.consumers[index].active);
                    return index;
                }
            }
            return error.NoSpaceLeft;
        }

        pub fn removeConsumer(self: *Self, consumer_id: ConsumerId) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(consumer_id < self.consumers.len);
            std.debug.assert(self.consumers[consumer_id].active);
            self.consumers[consumer_id] = .{};
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Precondition: buffer must be valid with non-zero capacity.
            std.debug.assert(self.buf.len > 0);
            // Precondition: write_seq must not be at the u64 ceiling (guard overflow).
            std.debug.assert(self.write_seq < std.math.maxInt(u64));
            if (self.isFullForActiveConsumers()) return error.WouldBlock;

            const pre_seq = self.write_seq;
            const index: usize = @intCast(self.write_seq % self.buf.len);
            self.buf[index] = value;
            self.write_seq += 1;
            // Postcondition: write_seq advanced by exactly one after the write.
            std.debug.assert(self.write_seq == pre_seq + 1);
        }

        pub fn tryRecv(self: *Self, consumer_id: ConsumerId) TryRecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.assertActiveConsumer(consumer_id);

            const consumer = &self.consumers[consumer_id];
            // Precondition: read_seq cannot be ahead of write_seq (consumer must not
            // be reading data not yet published).
            std.debug.assert(consumer.read_seq <= self.write_seq);
            if (consumer.read_seq == self.write_seq) return error.WouldBlock;

            const index: usize = @intCast(consumer.read_seq % self.buf.len);
            const value = self.buf[index];
            std.debug.assert(consumer.read_seq < std.math.maxInt(u64));
            const pre_read_seq = consumer.read_seq;
            consumer.read_seq += 1;
            // Postcondition: consumer read sequence advanced by exactly one.
            std.debug.assert(consumer.read_seq == pre_read_seq + 1);
            return value;
        }

        pub fn pending(self: *Self, consumer_id: ConsumerId) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.assertActiveConsumer(consumer_id);
            const consumer = self.consumers[consumer_id];
            // Invariant: consumer read_seq cannot exceed write_seq.
            std.debug.assert(consumer.read_seq <= self.write_seq);
            const delta = self.write_seq - consumer.read_seq;
            // Invariant: pending items cannot exceed the ring buffer capacity.
            std.debug.assert(delta <= self.buf.len);
            return @intCast(delta);
        }

        pub fn capacity(self: *const Self) usize {
            // Invariant: a valid broadcast always has a non-zero buffer.
            std.debug.assert(self.buf.len > 0);
            std.debug.assert(@intFromPtr(self.buf.ptr) != 0);
            return self.buf.len;
        }

        fn isFullForActiveConsumers(self: *Self) bool {
            // Precondition: the consumer table must be valid.
            std.debug.assert(self.consumers.len > 0);
            var has_active = false;
            var min_read_seq: u64 = self.write_seq;
            for (self.consumers) |consumer| {
                if (!consumer.active) continue;
                if (!has_active) {
                    has_active = true;
                    min_read_seq = consumer.read_seq;
                } else if (consumer.read_seq < min_read_seq) {
                    min_read_seq = consumer.read_seq;
                }
            }
            if (!has_active) return false;
            const used = self.write_seq - min_read_seq;
            std.debug.assert(used <= self.buf.len);
            return used == self.buf.len;
        }

        fn assertActiveConsumer(self: *Self, consumer_id: ConsumerId) void {
            std.debug.assert(consumer_id < self.consumers.len);
            std.debug.assert(self.consumers[consumer_id].active);
        }
    };
}

test "broadcast fans out one producer stream to multiple consumers" {
    var b = try Broadcast(u8).init(std.testing.allocator, .{
        .capacity = 4,
        .consumers_max = 2,
    });
    defer b.deinit();

    const c0 = try b.addConsumer();
    const c1 = try b.addConsumer();

    try b.trySend(10);
    try b.trySend(20);

    try std.testing.expectEqual(@as(u8, 10), try b.tryRecv(c0));
    try std.testing.expectEqual(@as(u8, 10), try b.tryRecv(c1));
    try std.testing.expectEqual(@as(u8, 20), try b.tryRecv(c0));
    try std.testing.expectEqual(@as(u8, 20), try b.tryRecv(c1));
    try std.testing.expectError(error.WouldBlock, b.tryRecv(c0));
}

test "broadcast applies backpressure to the slowest consumer" {
    var b = try Broadcast(u8).init(std.testing.allocator, .{
        .capacity = 2,
        .consumers_max = 2,
    });
    defer b.deinit();

    const c0 = try b.addConsumer();
    const c1 = try b.addConsumer();

    try b.trySend(1);
    try b.trySend(2);
    try std.testing.expectError(error.WouldBlock, b.trySend(3));

    b.removeConsumer(c0);
    try std.testing.expectEqual(@as(u8, 1), try b.tryRecv(c1));
    try b.trySend(3);
}

test "broadcast rejects non-power-of-two capacity" {
    // Goal: verify that init enforces the power-of-two capacity contract.
    // Method: supply an odd capacity and assert error.InvalidConfig is returned.
    try std.testing.expectError(
        error.InvalidConfig,
        Broadcast(u64).init(std.testing.allocator, .{ .capacity = 7 }),
    );
}

test "broadcast rejects capacity of zero" {
    // Goal: verify that init rejects a zero capacity (pre-existing check).
    // Method: supply zero and assert error.InvalidConfig is returned.
    try std.testing.expectError(
        error.InvalidConfig,
        Broadcast(u64).init(std.testing.allocator, .{ .capacity = 0 }),
    );
}
