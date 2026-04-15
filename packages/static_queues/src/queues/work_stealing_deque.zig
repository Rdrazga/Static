//! WorkStealingDeque: mutex-protected double-ended queue for work stealing.
//!
//! Capacity: fixed at init time; minimum 2 items.
//! Thread safety: owner uses pushBottom/popBottom (LIFO); thieves use stealTop (FIFO); all guarded by one mutex.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full or empty.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const ring = @import("ring_buffer.zig");
const memory = @import("static_memory");
const sync = @import("static_sync");
const qi = @import("queue_internal.zig");
const contracts = @import("../contracts.zig");

pub const Error = ring.Error;

pub fn WorkStealingDeque(comptime T: type) type {
    // Guard against zero-size types: the deque uses a ring buffer with
    // addressable slots; ZSTs have no storage and would make length arithmetic
    // meaningless.
    comptime {
        assert(@sizeOf(T) > 0);
        assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const concurrency: contracts.Concurrency = .work_stealing;
        pub const is_lock_free = false;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .exact;
        pub const PushError = error{WouldBlock};
        pub const PopError = error{WouldBlock};
        pub const StealError = error{WouldBlock};
        pub const Config = struct {
            capacity: usize,
            budget: ?*memory.budget.Budget = null,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        mutex: sync.threading.Mutex = .{},
        buf: []T,
        head: usize = 0,
        len_value: usize = 0,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            if (cfg.capacity < 2) return error.InvalidConfig;
            const bytes = std.math.mul(usize, cfg.capacity, @sizeOf(T)) catch return error.Overflow;
            try qi.tryReserveBudget(cfg.budget, bytes);

            errdefer if (cfg.budget) |budget| budget.release(bytes);

            const buf = allocator.alloc(T, cfg.capacity) catch return error.OutOfMemory;
            errdefer allocator.free(buf);

            const self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
                .buf = buf,
            };
            // Postcondition: deque starts empty with a valid buffer.
            assert(self.len_value == 0);
            assert(self.buf.len == cfg.capacity);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: buffer must still be valid (not already freed).
            assert(self.buf.len > 0);
            // Precondition: len_value is bounded before teardown.
            assert(self.len_value <= self.buf.len);
            if (self.budget) |budget| {
                budget.release(qi.bytesForItems(self.buf.len, @sizeOf(T)));
            }
            self.allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            // Invariant: a valid deque always has a non-zero capacity.
            assert(self.buf.len > 0);
            assert(@intFromPtr(self.buf.ptr) != 0);
            return self.buf.len;
        }

        pub fn len(self: *const Self) usize {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            // Invariant: len_value is always bounded by the allocated buffer.
            assert(self.len_value <= self.buf.len);
            return self.len_value;
        }

        pub fn isFull(self: *const Self) bool {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            assert(self.len_value <= self.buf.len);
            return self.len_value == self.buf.len;
        }

        /// Pushes work onto the owner side (bottom).
        pub fn pushBottom(self: *Self, value: T) PushError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Precondition: len_value must not exceed capacity.
            assert(self.len_value <= self.buf.len);
            // Precondition: head is a valid ring index.
            assert(self.head < self.buf.len);
            if (self.len_value == self.buf.len) return error.WouldBlock;
            const tail = (self.head + self.len_value) % self.buf.len;
            self.buf[tail] = value;
            self.len_value += 1;
            // Postcondition: the deque is non-empty after a successful push.
            assert(self.len_value > 0);
        }

        /// Pops work from the owner side (bottom) using LIFO order.
        pub fn popBottom(self: *Self) PopError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Precondition: len_value must be bounded by capacity.
            assert(self.len_value <= self.buf.len);
            if (self.len_value == 0) return error.WouldBlock;
            const old_len = self.len_value;
            const tail = (self.head + self.len_value - 1) % self.buf.len;
            const value = self.buf[tail];
            self.len_value -= 1;
            // Postcondition: len decreased by exactly one.
            assert(self.len_value == old_len - 1);
            return value;
        }

        /// Steals work from the opposite side (top) using FIFO order.
        pub fn stealTop(self: *Self) StealError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Precondition: head is a valid ring index.
            assert(self.head < self.buf.len);
            // Precondition: len_value is bounded by capacity.
            assert(self.len_value <= self.buf.len);
            if (self.len_value == 0) return error.WouldBlock;
            const old_len = self.len_value;
            const value = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.len_value -= 1;
            // Postcondition: len decreased by exactly one.
            assert(self.len_value == old_len - 1);
            // Postcondition: head remains a valid ring index after advancing.
            assert(self.head < self.buf.len);
            return value;
        }
    };
}

test "work_stealing deque owner pop is LIFO and steal is FIFO" {
    var d = try WorkStealingDeque(u8).init(testing.allocator, .{ .capacity = 8 });
    defer d.deinit();

    try d.pushBottom(1);
    try d.pushBottom(2);
    try d.pushBottom(3);

    try testing.expectEqual(@as(u8, 3), try d.popBottom());
    try testing.expectEqual(@as(u8, 1), try d.stealTop());
    try testing.expectEqual(@as(u8, 2), try d.popBottom());
    try testing.expectError(error.WouldBlock, d.popBottom());
}

test "work_stealing deque returns WouldBlock when full" {
    var d = try WorkStealingDeque(u8).init(testing.allocator, .{ .capacity = 2 });
    defer d.deinit();

    try testing.expect(!d.isFull());
    try d.pushBottom(10);
    try testing.expect(!d.isFull());
    try d.pushBottom(11);
    try testing.expect(d.isFull());
    try testing.expectError(error.WouldBlock, d.pushBottom(12));
}
