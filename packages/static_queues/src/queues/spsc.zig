//! SpscQueue: single-producer, single-consumer lock-free queue.
//!
//! Capacity: fixed at init time; any positive count. Non-power-of-two capacity is
//! intentionally supported for flexibility (unlike Disruptor/Broadcast which require
//! power-of-two for bitmasking). The trade-off is a comparison-branch wrap-around
//! instead of a bitmask, which is negligible for the SPSC use case.
//! Thread safety: exactly one producer thread and one consumer thread; no mutex required.
//! Reservation API: send reservations are producer-owned; recv reservations are consumer-owned.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full or empty.
//! Batch operations: intentionally omitted for lock-free queues; loop manually for explicit progress control.
const std = @import("std");
const ring = @import("ring_buffer.zig");
const memory = @import("static_memory");
const qi = @import("queue_internal.zig");
const contracts = @import("../contracts.zig");

pub fn SpscQueue(comptime T: type) type {
    // Guard against zero-size types: the slot-based ring protocol relies on
    // addressable storage to distinguish empty from full slots.
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
        std.debug.assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Error = ring.Error;
        pub const Config = ring.RingBuffer(T).Config;
        pub const concurrency: contracts.Concurrency = .spsc;
        pub const is_lock_free = true;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .exact;
        pub const TrySendError = error{WouldBlock};
        pub const TryRecvError = error{WouldBlock};
        pub const ReserveSendError = error{WouldBlock};
        pub const ReserveRecvError = error{WouldBlock};

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        buf: []T,
        // Placed on separate cache lines: the consumer writes head while the
        // producer writes tail. Without padding, each write by one thread
        // invalidates the other thread's cache line on every operation.
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),
        // Reservation flags are thread-owned (producer/consumer) and intentionally non-atomic.
        send_reserved: bool = false,
        recv_reserved: bool = false,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            if (cfg.capacity == 0) return error.InvalidConfig;
            // The SPSC protocol uses one extra slot so that head == tail unambiguously
            // means empty (not full). storage_capacity == cfg.capacity + 1.
            const storage_capacity = std.math.add(usize, cfg.capacity, 1) catch
                return error.Overflow;
            const bytes = std.math.mul(usize, storage_capacity, @sizeOf(T)) catch
                return error.Overflow;
            try qi.tryReserveBudget(cfg.budget, bytes);

            errdefer if (cfg.budget) |budget| budget.release(bytes);

            const buf = allocator.alloc(T, storage_capacity) catch return error.OutOfMemory;
            errdefer allocator.free(buf);

            const self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
                .buf = buf,
            };
            // Postcondition: internal storage is one slot larger than the logical capacity.
            std.debug.assert(self.buf.len == cfg.capacity + 1);
            // Postcondition: head and tail start at zero, meaning the queue is empty.
            std.debug.assert(self.head.load(.monotonic) == 0);
            std.debug.assert(self.tail.load(.monotonic) == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: the buffer must still be valid (not already freed).
            std.debug.assert(self.buf.len > 0);
            // Precondition: head and tail must be within bounds.
            std.debug.assert(self.head.load(.monotonic) < self.buf.len);
            std.debug.assert(self.tail.load(.monotonic) < self.buf.len);
            std.debug.assert(!self.send_reserved);
            std.debug.assert(!self.recv_reserved);
            if (self.budget) |budget| {
                budget.release(qi.bytesForItems(self.buf.len, @sizeOf(T)));
            }
            self.allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            // Invariant: storage always includes one sentinel slot.
            std.debug.assert(self.buf.len > 1);
            return self.buf.len - 1;
        }

        pub fn len(self: *const Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            std.debug.assert(head < self.buf.len);
            std.debug.assert(tail < self.buf.len);

            const queue_len = if (tail >= head) tail - head else (self.buf.len - head) + tail;
            std.debug.assert(queue_len <= self.capacity());
            return queue_len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == self.capacity();
        }

        pub fn reserveSend(self: *Self) ReserveSendError!*T {
            std.debug.assert(!self.send_reserved);
            const tail = self.tail.load(.monotonic);
            std.debug.assert(tail < self.buf.len);
            const next_tail = nextIndex(tail, self.buf.len);
            const head = self.head.load(.acquire);
            if (next_tail == head) return error.WouldBlock;

            self.send_reserved = true;
            return &self.buf[tail];
        }

        pub fn commitSend(self: *Self) void {
            std.debug.assert(self.send_reserved);
            const tail = self.tail.load(.monotonic);
            std.debug.assert(tail < self.buf.len);
            const next_tail = nextIndex(tail, self.buf.len);
            const head = self.head.load(.acquire);
            std.debug.assert(next_tail != head);
            self.tail.store(next_tail, .release);
            self.send_reserved = false;
            std.debug.assert(self.tail.load(.monotonic) < self.buf.len);
        }

        pub fn abortSendReservation(self: *Self) void {
            std.debug.assert(self.send_reserved);
            self.send_reserved = false;
            std.debug.assert(!self.send_reserved);
        }

        pub fn reserveRecv(self: *Self) ReserveRecvError!*const T {
            std.debug.assert(!self.recv_reserved);
            const head = self.head.load(.monotonic);
            std.debug.assert(head < self.buf.len);
            const tail = self.tail.load(.acquire);
            if (head == tail) return error.WouldBlock;

            self.recv_reserved = true;
            return &self.buf[head];
        }

        pub fn commitRecv(self: *Self) void {
            std.debug.assert(self.recv_reserved);
            const head = self.head.load(.monotonic);
            std.debug.assert(head < self.buf.len);
            const tail = self.tail.load(.acquire);
            std.debug.assert(head != tail);
            const next_head = nextIndex(head, self.buf.len);
            self.head.store(next_head, .release);
            self.recv_reserved = false;
            std.debug.assert(self.head.load(.monotonic) < self.buf.len);
        }

        pub fn abortRecvReservation(self: *Self) void {
            std.debug.assert(self.recv_reserved);
            self.recv_reserved = false;
            std.debug.assert(!self.recv_reserved);
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            std.debug.assert(!self.send_reserved);
            const tail = self.tail.load(.monotonic);
            // Precondition: tail must always be a valid slot index.
            std.debug.assert(tail < self.buf.len);
            const next_tail = nextIndex(tail, self.buf.len);
            const head = self.head.load(.acquire);
            if (next_tail == head) return error.WouldBlock;

            self.buf[tail] = value;
            self.tail.store(next_tail, .release);
            // Postcondition: the stored tail moved forward and remains in bounds.
            std.debug.assert(self.tail.load(.monotonic) < self.buf.len);
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            std.debug.assert(!self.recv_reserved);
            const head = self.head.load(.monotonic);
            // Precondition: head must always be a valid slot index.
            std.debug.assert(head < self.buf.len);
            const tail = self.tail.load(.acquire);
            if (head == tail) return error.WouldBlock;

            const value = self.buf[head];
            self.head.store(nextIndex(head, self.buf.len), .release);
            // Postcondition: the stored head moved forward and remains in bounds.
            std.debug.assert(self.head.load(.monotonic) < self.buf.len);
            return value;
        }

        fn nextIndex(index: usize, capacity_slots: usize) usize {
            // Precondition: index must be a valid slot position.
            std.debug.assert(index < capacity_slots);
            // Precondition: capacity must be non-zero.
            std.debug.assert(capacity_slots > 0);
            const next = index + 1;
            return if (next == capacity_slots) 0 else next;
        }
    };
}

test "spsc queue wraparound and WouldBlock semantics" {
    var q = try SpscQueue(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer q.deinit();

    try q.trySend(1);
    try q.trySend(2);
    try std.testing.expectError(error.WouldBlock, q.trySend(3));
    try std.testing.expectEqual(@as(u8, 1), try q.tryRecv());
    try q.trySend(3);
    try std.testing.expectEqual(@as(u8, 2), try q.tryRecv());
    try std.testing.expectEqual(@as(u8, 3), try q.tryRecv());
    try std.testing.expectError(error.WouldBlock, q.tryRecv());
}

test "spsc queue introspection methods reflect queue state" {
    var q = try SpscQueue(u8).init(std.testing.allocator, .{ .capacity = 3 });
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 3), q.capacity());
    try std.testing.expectEqual(@as(usize, 0), q.len());
    try std.testing.expect(q.isEmpty());
    try std.testing.expect(!q.isFull());

    try q.trySend(9);
    try std.testing.expectEqual(@as(usize, 1), q.len());
    try std.testing.expect(!q.isEmpty());
    try std.testing.expect(!q.isFull());
    try q.trySend(10);
    try q.trySend(11);
    try std.testing.expect(q.isFull());

    _ = try q.tryRecv();
    try std.testing.expectEqual(@as(usize, 2), q.len());
    try std.testing.expect(!q.isEmpty());
    try std.testing.expect(!q.isFull());
}

test "spsc queue reserve and commit send path provides zero-copy write" {
    var q = try SpscQueue(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer q.deinit();

    const slot = try q.reserveSend();
    slot.* = 42;
    q.commitSend();

    try std.testing.expectEqual(@as(u8, 42), try q.tryRecv());
}

test "spsc queue reserve and commit recv path provides zero-copy read" {
    var q = try SpscQueue(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer q.deinit();

    try q.trySend(77);
    const slot = try q.reserveRecv();
    try std.testing.expectEqual(@as(u8, 77), slot.*);
    q.commitRecv();
    try std.testing.expect(q.isEmpty());
}

test "spsc queue reservation abort restores regular send and recv paths" {
    var q = try SpscQueue(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer q.deinit();

    const send_slot = try q.reserveSend();
    send_slot.* = 9;
    q.abortSendReservation();
    try q.trySend(10);

    const recv_slot = try q.reserveRecv();
    try std.testing.expectEqual(@as(u8, 10), recv_slot.*);
    q.abortRecvReservation();
    try std.testing.expectEqual(@as(u8, 10), try q.tryRecv());
}
