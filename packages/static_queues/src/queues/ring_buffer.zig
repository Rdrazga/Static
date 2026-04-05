//! RingBuffer: single-threaded bounded circular buffer.
//!
//! Capacity: fixed at init time; any positive count.
//! Thread safety: not thread-safe; wrap with a mutex for multi-threaded use.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full or empty.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const memory = @import("static_memory");
const qi = @import("queue_internal.zig");
const contracts = @import("../contracts.zig");

pub const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    InvalidConfig,
    WouldBlock,
    Overflow,
};

pub fn RingBuffer(comptime T: type) type {
    // Guard against zero-size types: a ZST buffer has no addressable storage,
    // making capacity calculations and indexing meaningless.
    comptime {
        assert(@sizeOf(T) > 0);
        assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const concurrency: contracts.Concurrency = .single_threaded;
        pub const is_lock_free = true;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .exact;
        pub const PushError = error{WouldBlock};
        pub const PopError = error{WouldBlock};
        pub const Config = struct {
            capacity: usize,
            budget: ?*memory.budget.Budget = null,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        buf: []T,
        head: usize = 0,
        len_value: usize = 0,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            if (cfg.capacity == 0) return error.InvalidConfig;
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
            // Postcondition: buffer is correctly sized and the queue starts empty.
            assert(self.buf.len == cfg.capacity);
            assert(self.len_value == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: the buffer pointer must still be valid (not already freed).
            assert(self.buf.len > 0);
            // Precondition: len cannot exceed allocated capacity.
            assert(self.len_value <= self.buf.len);
            if (self.budget) |budget| {
                budget.release(qi.bytesForItems(self.buf.len, @sizeOf(T)));
            }
            self.allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn len(self: Self) usize {
            // Invariant: len_value is always bounded by the allocated buffer.
            assert(self.len_value <= self.buf.len);
            // Invariant: head is always a valid index (pair assertion from the other angle).
            assert(self.head < self.buf.len);
            return self.len_value;
        }

        pub fn capacity(self: Self) usize {
            // Invariant: a valid ring buffer always has a non-zero capacity.
            assert(self.buf.len > 0);
            // Invariant: len_value cannot exceed capacity (pair assertion).
            assert(self.len_value <= self.buf.len);
            return self.buf.len;
        }

        pub fn isEmpty(self: Self) bool {
            // Invariant: len_value is always bounded by capacity.
            assert(self.len_value <= self.buf.len);
            return self.len_value == 0;
        }

        pub fn isFull(self: Self) bool {
            // Invariant: len_value is always bounded by capacity.
            assert(self.len_value <= self.buf.len);
            return self.len_value == self.buf.len;
        }

        pub fn peekContiguous(self: Self, max: usize) []const T {
            // Precondition: head is always a valid index within the buffer.
            assert(self.head < self.buf.len);
            // Precondition: len_value does not exceed capacity.
            assert(self.len_value <= self.buf.len);
            if (self.len_value == 0) return self.buf[0..0];
            const contiguous = @min(self.len_value, self.buf.len - self.head);
            const count = @min(contiguous, max);
            // Postcondition: returned slice is always within the buffer bounds.
            assert(self.head + count <= self.buf.len);
            return self.buf[self.head .. self.head + count];
        }

        pub fn discard(self: *Self, n: usize) usize {
            // Precondition: head is always a valid index within the buffer.
            assert(self.head < self.buf.len);
            // Precondition: len_value does not exceed capacity.
            assert(self.len_value <= self.buf.len);
            const consumed = @min(n, self.len_value);
            if (consumed == 0) return 0;
            self.head = (self.head + consumed) % self.buf.len;
            self.len_value -= consumed;
            // Postcondition: head must remain a valid index after the advance.
            assert(self.head < self.buf.len);
            return consumed;
        }

        pub fn tryPushBatch(self: *Self, values: []const T) usize {
            assert(self.head < self.buf.len);
            assert(self.len_value <= self.buf.len);

            const space_available = self.buf.len - self.len_value;
            const sent_count = @min(values.len, space_available);
            if (sent_count == 0) return 0;

            const tail = (self.head + self.len_value) % self.buf.len;
            assert(tail < self.buf.len);

            const first_copy_count = @min(sent_count, self.buf.len - tail);
            assert(first_copy_count <= sent_count);
            std.mem.copyForwards(T, self.buf[tail .. tail + first_copy_count], values[0..first_copy_count]);

            const second_copy_count = sent_count - first_copy_count;
            if (second_copy_count > 0) {
                std.mem.copyForwards(T, self.buf[0..second_copy_count], values[first_copy_count .. first_copy_count + second_copy_count]);
            }

            self.len_value += sent_count;
            assert(sent_count <= values.len);
            assert(self.len_value <= self.buf.len);
            return sent_count;
        }

        pub fn tryPopBatch(self: *Self, out: []T) usize {
            assert(self.head < self.buf.len);
            assert(self.len_value <= self.buf.len);

            const recv_count = @min(out.len, self.len_value);
            if (recv_count == 0) return 0;

            const first_copy_count = @min(recv_count, self.buf.len - self.head);
            assert(first_copy_count <= recv_count);
            std.mem.copyForwards(T, out[0..first_copy_count], self.buf[self.head .. self.head + first_copy_count]);

            const second_copy_count = recv_count - first_copy_count;
            if (second_copy_count > 0) {
                std.mem.copyForwards(T, out[first_copy_count .. first_copy_count + second_copy_count], self.buf[0..second_copy_count]);
            }

            self.head = (self.head + recv_count) % self.buf.len;
            self.len_value -= recv_count;
            assert(recv_count <= out.len);
            assert(self.head < self.buf.len);
            assert(self.len_value <= self.buf.len);
            return recv_count;
        }

        pub fn tryPush(self: *Self, value: T) PushError!void {
            // Precondition: len_value must not exceed capacity (invariant holds before push).
            assert(self.len_value <= self.buf.len);
            // Precondition: head is a valid buffer index.
            assert(self.head < self.buf.len);
            if (self.len_value == self.buf.len) return error.WouldBlock;
            const tail = (self.head + self.len_value) % self.buf.len;
            self.buf[tail] = value;
            self.len_value += 1;
            // Postcondition: the queue is now non-empty.
            assert(self.len_value > 0);
        }

        pub fn tryPop(self: *Self) PopError!T {
            // Precondition: head is a valid index before advancing.
            assert(self.head < self.buf.len);
            // Precondition: len_value is bounded by capacity.
            assert(self.len_value <= self.buf.len);
            if (self.len_value == 0) return error.WouldBlock;
            const old_len = self.len_value;
            const out = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.len_value -= 1;
            // Postcondition: the queue shrank by exactly one element.
            assert(self.len_value == old_len - 1);
            // Postcondition: head remains a valid index after wrap.
            assert(self.head < self.buf.len);
            return out;
        }

        pub fn pushOverwrite(self: *Self, value: T) ?T {
            // Precondition: head is a valid index and len_value is bounded.
            assert(self.head < self.buf.len);
            assert(self.len_value <= self.buf.len);
            if (self.len_value == self.buf.len) {
                const overwritten = self.buf[self.head];
                self.buf[self.head] = value;
                self.head = (self.head + 1) % self.buf.len;
                // Postcondition: capacity is unchanged when overwriting (len stays at max).
                assert(self.len_value == self.buf.len);
                return overwritten;
            }
            const tail = (self.head + self.len_value) % self.buf.len;
            self.buf[tail] = value;
            self.len_value += 1;
            // Postcondition: queue is non-empty after insert.
            assert(self.len_value > 0);
            return null;
        }
    };
}

test "ring buffer wraparound and WouldBlock semantics" {
    var rb = try RingBuffer(u8).init(testing.allocator, .{ .capacity = 2 });
    defer rb.deinit();

    try rb.tryPush(1);
    try rb.tryPush(2);
    try testing.expectError(error.WouldBlock, rb.tryPush(3));
    try testing.expectEqual(@as(u8, 1), try rb.tryPop());
    try rb.tryPush(3);
    try testing.expectEqual(@as(u8, 2), try rb.tryPop());
    try testing.expectEqual(@as(u8, 3), try rb.tryPop());
    try testing.expectError(error.WouldBlock, rb.tryPop());
}

test "ring buffer peekContiguous respects wrap boundary" {
    var rb = try RingBuffer(u8).init(testing.allocator, .{ .capacity = 4 });
    defer rb.deinit();

    // Fill to capacity.
    try rb.tryPush(10);
    try rb.tryPush(20);
    try rb.tryPush(30);
    try rb.tryPush(40);

    // Advance head by 2 to create a wrap situation.
    const discarded = rb.discard(2);
    try testing.expectEqual(@as(usize, 2), discarded);
    try rb.tryPush(50);
    try rb.tryPush(60);

    // head is now at index 2; elements 30,40 are contiguous, then 50,60 wrap.
    const peek = rb.peekContiguous(4);
    // Must return only the contiguous segment before the buffer boundary.
    try testing.expect(peek.len >= 1);
    try testing.expectEqual(@as(u8, 30), peek[0]);
}

test "ring buffer pushOverwrite returns evicted value when full" {
    var rb = try RingBuffer(u8).init(testing.allocator, .{ .capacity = 2 });
    defer rb.deinit();

    try rb.tryPush(1);
    try rb.tryPush(2);
    const evicted = rb.pushOverwrite(3);
    try testing.expectEqual(@as(?u8, 1), evicted);
    try testing.expectEqual(@as(u8, 2), try rb.tryPop());
    try testing.expectEqual(@as(u8, 3), try rb.tryPop());
}

test "ring buffer InvalidConfig for zero capacity" {
    try testing.expectError(error.InvalidConfig, RingBuffer(u8).init(testing.allocator, .{ .capacity = 0 }));
}

test "ring buffer isEmpty tracks push and pop transitions" {
    var rb = try RingBuffer(u8).init(testing.allocator, .{ .capacity = 2 });
    defer rb.deinit();

    try testing.expect(rb.isEmpty());
    try testing.expect(!rb.isFull());
    try rb.tryPush(1);
    try testing.expect(!rb.isEmpty());
    try testing.expect(!rb.isFull());
    try rb.tryPush(2);
    try testing.expect(rb.isFull());
    _ = try rb.tryPop();
    try testing.expect(!rb.isEmpty());
    try testing.expect(!rb.isFull());
    _ = try rb.tryPop();
    try testing.expect(rb.isEmpty());
    try testing.expect(!rb.isFull());
}

test "ring buffer batch push and pop process contiguous prefix" {
    var rb = try RingBuffer(u8).init(testing.allocator, .{ .capacity = 3 });
    defer rb.deinit();

    const sent = rb.tryPushBatch(&.{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(usize, 3), sent);
    try testing.expect(rb.isFull());

    var recv_small: [2]u8 = undefined;
    const recv_first = rb.tryPopBatch(&recv_small);
    try testing.expectEqual(@as(usize, 2), recv_first);
    try testing.expectEqual(@as(u8, 1), recv_small[0]);
    try testing.expectEqual(@as(u8, 2), recv_small[1]);

    const sent_second = rb.tryPushBatch(&.{ 5, 6 });
    try testing.expectEqual(@as(usize, 2), sent_second);
    try testing.expect(rb.isFull());

    var recv_large: [4]u8 = undefined;
    const recv_second = rb.tryPopBatch(&recv_large);
    try testing.expectEqual(@as(usize, 3), recv_second);
    try testing.expectEqual(@as(u8, 3), recv_large[0]);
    try testing.expectEqual(@as(u8, 5), recv_large[1]);
    try testing.expectEqual(@as(u8, 6), recv_large[2]);
    try testing.expect(rb.isEmpty());
}
