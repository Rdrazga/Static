//! LockedQueue: mutex-protected bounded ring buffer.
//!
//! Capacity: fixed at init time via the underlying RingBuffer.
//! Thread safety: all operations are serialized by one mutex.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full or empty.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const ring = @import("ring_buffer.zig");
const sync = @import("static_sync");
const qi = @import("queue_internal.zig");
const caps = @import("caps.zig");
const contracts = @import("../contracts.zig");

pub const Error = ring.Error;

pub fn LockedQueue(comptime T: type) type {
    // Guard against zero-size types: the underlying ring buffer requires
    // addressable storage; ZST would make capacity and length calculations
    // meaningless.
    comptime {
        assert(@sizeOf(T) > 0);
        assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Config = ring.RingBuffer(T).Config;
        pub const concurrency: contracts.Concurrency = .mpmc;
        pub const is_lock_free = false;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .exact;
        pub const TrySendError = error{WouldBlock};
        pub const TryRecvError = error{WouldBlock};
        pub const BatchLimitOptions = struct {
            items_max: usize = std.math.maxInt(usize),
        };

        mutex: std.Thread.Mutex = .{},
        rb: ring.RingBuffer(T),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            const self: Self = .{ .rb = try ring.RingBuffer(T).init(allocator, cfg) };
            // Postcondition: queue starts empty with a valid buffer.
            assert(self.rb.len() == 0);
            assert(self.rb.capacity() > 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: buffer must still be valid (not already freed).
            assert(self.rb.capacity() > 0);
            self.rb.deinit();
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            // Invariant: capacity is always positive for a live queue.
            assert(self.rb.buf.len > 0);
            assert(@intFromPtr(self.rb.buf.ptr) != 0);
            return self.rb.buf.len;
        }

        pub fn len(self: *const Self) usize {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            const l = self.rb.len();
            // Invariant: len cannot exceed capacity.
            assert(l <= self.rb.capacity());
            return l;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == self.capacity();
        }

        pub fn trySendBatch(self: *Self, values: []const T) usize {
            return self.trySendBatchWith(values, .{
                .items_max = values.len,
            });
        }

        pub fn trySendBatchWith(self: *Self, values: []const T, options: BatchLimitOptions) usize {
            const items_limit = @min(values.len, options.items_max);
            if (items_limit == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();
            assert(self.rb.capacity() > 0);

            const old_len = self.rb.len();
            const sent_count = self.rb.tryPushBatch(values[0..items_limit]);
            assert(sent_count <= values.len);
            assert(sent_count <= items_limit);
            assert(self.rb.len() == old_len + sent_count);
            return sent_count;
        }

        pub fn tryRecvBatch(self: *Self, out: []T) usize {
            return self.tryRecvBatchWith(out, .{
                .items_max = out.len,
            });
        }

        pub fn tryRecvBatchWith(self: *Self, out: []T, options: BatchLimitOptions) usize {
            const items_limit = @min(out.len, options.items_max);
            if (items_limit == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();
            assert(self.rb.capacity() > 0);

            const old_len = self.rb.len();
            const recv_count = self.rb.tryPopBatch(out[0..items_limit]);
            assert(recv_count <= out.len);
            assert(recv_count <= items_limit);
            assert(self.rb.len() + recv_count == old_len);
            return recv_count;
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Precondition: capacity must be positive.
            assert(self.rb.capacity() > 0);
            try self.rb.tryPush(value);
            // Postcondition: queue is non-empty after a successful push.
            assert(self.rb.len() > 0);
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Precondition: capacity must be positive.
            assert(self.rb.capacity() > 0);
            const old_len = self.rb.len();
            const value = try self.rb.tryPop();
            // Postcondition: len decreased by exactly one.
            assert(self.rb.len() == old_len - 1);
            return value;
        }
    };
}

test "locked queue provides bounded trySend/tryRecv semantics" {
    var q = try LockedQueue(u8).init(testing.allocator, .{ .capacity = 2 });
    defer q.deinit();

    try testing.expect(q.isEmpty());
    try testing.expect(!q.isFull());
    try q.trySend(1);
    try testing.expect(!q.isFull());
    try q.trySend(2);
    try testing.expect(q.isFull());
    try testing.expectEqual(@as(usize, 2), q.capacity());
    try testing.expectEqual(@as(usize, 2), q.len());
    try testing.expect(!q.isEmpty());
    try testing.expectError(error.WouldBlock, q.trySend(3));
    try testing.expectEqual(@as(u8, 1), try q.tryRecv());
    try testing.expect(!q.isFull());
    try testing.expectEqual(@as(u8, 2), try q.tryRecv());
    try testing.expect(q.isEmpty());
    try testing.expectError(error.WouldBlock, q.tryRecv());
}

test "locked queue batch send and recv process contiguous prefix" {
    var q = try LockedQueue(u8).init(testing.allocator, .{ .capacity = 3 });
    defer q.deinit();

    const sent = q.trySendBatch(&.{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(usize, 3), sent);
    try testing.expect(q.isFull());

    var recv_small: [2]u8 = undefined;
    const recv_first = q.tryRecvBatch(&recv_small);
    try testing.expectEqual(@as(usize, 2), recv_first);
    try testing.expectEqual(@as(u8, 1), recv_small[0]);
    try testing.expectEqual(@as(u8, 2), recv_small[1]);

    const sent_second = q.trySendBatch(&.{ 5, 6 });
    try testing.expectEqual(@as(usize, 2), sent_second);

    var recv_large: [4]u8 = undefined;
    const recv_second = q.tryRecvBatch(&recv_large);
    try testing.expectEqual(@as(usize, 3), recv_second);
    try testing.expectEqual(@as(u8, 3), recv_large[0]);
    try testing.expectEqual(@as(u8, 5), recv_large[1]);
    try testing.expectEqual(@as(u8, 6), recv_large[2]);
}

test "locked queue batch options bound work and preserve empty no-op" {
    var q = try LockedQueue(u8).init(testing.allocator, .{ .capacity = 3 });
    defer q.deinit();

    try q.trySend(1);
    try q.trySend(2);

    const sent_zero = q.trySendBatchWith(&.{ 7, 8 }, .{ .items_max = 0 });
    try testing.expectEqual(@as(usize, 0), sent_zero);
    try testing.expectEqual(@as(usize, 2), q.len());

    const sent_one = q.trySendBatchWith(&.{ 7, 8 }, .{ .items_max = 1 });
    try testing.expectEqual(@as(usize, 1), sent_one);
    try testing.expect(q.isFull());

    var recv: [4]u8 = undefined;
    const recv_zero = q.tryRecvBatchWith(recv[0..0], .{ .items_max = 1 });
    try testing.expectEqual(@as(usize, 0), recv_zero);
    try testing.expect(q.isFull());

    const recv_two = q.tryRecvBatchWith(&recv, .{ .items_max = 2 });
    try testing.expectEqual(@as(usize, 2), recv_two);
    try testing.expectEqual(@as(u8, 1), recv[0]);
    try testing.expectEqual(@as(u8, 2), recv[1]);

    const recv_rest = q.tryRecvBatchWith(&recv, .{ .items_max = 9 });
    try testing.expectEqual(@as(usize, 1), recv_rest);
    try testing.expectEqual(@as(u8, 7), recv[0]);
    try testing.expect(q.isEmpty());
}

test "locked queue len remains bounded during concurrent mutation" {
    if (caps.shouldSkipThreadedTests()) return error.SkipZigTest;

    const Q = LockedQueue(u16);
    var q = try Q.init(testing.allocator, .{ .capacity = 16 });
    defer q.deinit();

    const Worker = struct {
        queue: *Q,
        iterations_max: u32,

        fn run(self: *@This()) void {
            var iterations: u32 = 0;
            while (iterations < self.iterations_max) : (iterations += 1) {
                self.queue.trySend(@as(u16, @intCast(iterations))) catch |err| switch (err) {
                    error.WouldBlock => {},
                };
                _ = self.queue.tryRecv() catch |err| switch (err) {
                    error.WouldBlock => {},
                };
                std.Thread.yield() catch {};
            }
        }
    };

    var worker = Worker{
        .queue = &q,
        .iterations_max = 20_000,
    };
    var thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    var checks: u32 = 0;
    while (checks < 20_000) : (checks += 1) {
        const queue_len = q.len();
        try testing.expect(queue_len <= q.capacity());
        std.Thread.yield() catch {};
    }
    thread.join();

    try testing.expect(q.len() <= q.capacity());
}
