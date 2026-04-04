//! MpscQueue: multi-producer, single-consumer bounded queue.
//!
//! Capacity: fixed at init time via the underlying RingBuffer.
//! Thread safety: all operations are serialized by one mutex; safe for multiple concurrent producers and one consumer.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full or empty.
//! Also exported as `LockedMpscQueue` for naming clarity alongside `LockFreeMpscQueue`.
const std = @import("std");
const ring = @import("ring_buffer.zig");
const sync = @import("static_sync");
const qi = @import("queue_internal.zig");
const caps = @import("caps.zig");
const contracts = @import("../contracts.zig");

/// A multi-producer, single-consumer queue backed by a bounded ring buffer.
///
/// Concurrency model: a single mutex guards both producers (trySend) and the
/// consumer (tryRecv). This serializes the consumer together with all producers,
/// which is simpler and safer than a lock-free MPSC design but foregoes the
/// scalability advantage that "single consumer" normally provides (the consumer
/// could otherwise run lock-free against a producer-only lock). The trade-off is
/// intentional in this implementation:
///
///   - Correctness is easier to audit: the ring buffer itself is single-threaded;
///     all concurrent access goes through one mutex, eliminating subtle ordering
///     issues between a separate producer lock and a lock-free consumer path.
///   - The ring buffer is bounded and contention is expected to be low for the
///     target workloads (handoff, job dispatch). Under high producer contention a
///     lock-free MPSC (e.g. Dmitry Vyukov-style linked-node) would be preferable,
///     but that requires a node allocator or intrusive links, which adds surface
///     area beyond the current bounded ring-buffer design.
///   - A lock-free upgrade path can be introduced later without changing this
///     public API surface (`trySend`/`tryRecv`).
pub fn MpscQueue(comptime T: type) type {
    // Guard against zero-size types: the ring buffer requires addressable
    // storage; ZSTs make capacity calculations meaningless.
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
        std.debug.assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Error = ring.Error;
        pub const Config = ring.RingBuffer(T).Config;
        pub const concurrency: contracts.Concurrency = .mpsc;
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
            std.debug.assert(self.rb.len() == 0);
            std.debug.assert(self.rb.capacity() > 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: buffer must still be valid.
            std.debug.assert(self.rb.capacity() > 0);
            self.rb.deinit();
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            // Invariant: capacity is fixed for a live queue.
            std.debug.assert(self.rb.capacity() > 0);
            return self.rb.capacity();
        }

        pub fn len(self: *const Self) usize {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            const queue_len = self.rb.len();
            std.debug.assert(queue_len <= self.rb.capacity());
            return queue_len;
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
            std.debug.assert(self.rb.capacity() > 0);

            const old_len = self.rb.len();
            const sent_count = self.rb.tryPushBatch(values[0..items_limit]);
            std.debug.assert(sent_count <= values.len);
            std.debug.assert(sent_count <= items_limit);
            std.debug.assert(self.rb.len() == old_len + sent_count);
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
            std.debug.assert(self.rb.capacity() > 0);

            const old_len = self.rb.len();
            const recv_count = self.rb.tryPopBatch(out[0..items_limit]);
            std.debug.assert(recv_count <= out.len);
            std.debug.assert(recv_count <= items_limit);
            std.debug.assert(self.rb.len() + recv_count == old_len);
            return recv_count;
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Precondition: capacity must be positive.
            std.debug.assert(self.rb.capacity() > 0);
            try self.rb.tryPush(value);
            // Postcondition: queue is non-empty after a successful push.
            std.debug.assert(self.rb.len() > 0);
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Precondition: capacity must be positive.
            std.debug.assert(self.rb.capacity() > 0);
            const old_len = self.rb.len();
            const value = try self.rb.tryPop();
            // Postcondition: len decreased by exactly one.
            std.debug.assert(self.rb.len() == old_len - 1);
            return value;
        }
    };
}

pub const LockedMpscQueue = MpscQueue;

test "mpsc queue basic semantics" {
    var q = try MpscQueue(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer q.deinit();
    try q.trySend(1);
    try q.trySend(2);
    try std.testing.expectEqual(@as(u8, 1), try q.tryRecv());
}

test "mpsc queue introspection methods reflect queue state" {
    var q = try MpscQueue(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 2), q.capacity());
    try std.testing.expectEqual(@as(usize, 0), q.len());
    try std.testing.expect(q.isEmpty());
    try std.testing.expect(!q.isFull());

    try q.trySend(1);
    try std.testing.expectEqual(@as(usize, 1), q.len());
    try std.testing.expect(!q.isEmpty());
    try std.testing.expect(!q.isFull());
    try q.trySend(2);
    try std.testing.expect(q.isFull());

    _ = try q.tryRecv();
    try std.testing.expect(!q.isFull());
}

test "mpsc queue batch send and recv process contiguous prefix" {
    var q = try MpscQueue(u8).init(std.testing.allocator, .{ .capacity = 3 });
    defer q.deinit();

    const sent = q.trySendBatch(&.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 3), sent);
    try std.testing.expect(q.isFull());

    var recv_small: [2]u8 = undefined;
    const recv_first = q.tryRecvBatch(&recv_small);
    try std.testing.expectEqual(@as(usize, 2), recv_first);
    try std.testing.expectEqual(@as(u8, 1), recv_small[0]);
    try std.testing.expectEqual(@as(u8, 2), recv_small[1]);

    const sent_second = q.trySendBatch(&.{ 5, 6 });
    try std.testing.expectEqual(@as(usize, 2), sent_second);

    var recv_large: [4]u8 = undefined;
    const recv_second = q.tryRecvBatch(&recv_large);
    try std.testing.expectEqual(@as(usize, 3), recv_second);
    try std.testing.expectEqual(@as(u8, 3), recv_large[0]);
    try std.testing.expectEqual(@as(u8, 5), recv_large[1]);
    try std.testing.expectEqual(@as(u8, 6), recv_large[2]);
}

test "mpsc queue batch options bound work and preserve empty no-op" {
    var q = try MpscQueue(u8).init(std.testing.allocator, .{ .capacity = 3 });
    defer q.deinit();

    try q.trySend(1);
    try q.trySend(2);

    const sent_zero = q.trySendBatchWith(&.{ 7, 8 }, .{ .items_max = 0 });
    try std.testing.expectEqual(@as(usize, 0), sent_zero);
    try std.testing.expectEqual(@as(usize, 2), q.len());

    const sent_one = q.trySendBatchWith(&.{ 7, 8 }, .{ .items_max = 1 });
    try std.testing.expectEqual(@as(usize, 1), sent_one);
    try std.testing.expect(q.isFull());

    var recv: [4]u8 = undefined;
    const recv_zero = q.tryRecvBatchWith(recv[0..0], .{ .items_max = 1 });
    try std.testing.expectEqual(@as(usize, 0), recv_zero);
    try std.testing.expect(q.isFull());

    const recv_two = q.tryRecvBatchWith(&recv, .{ .items_max = 2 });
    try std.testing.expectEqual(@as(usize, 2), recv_two);
    try std.testing.expectEqual(@as(u8, 1), recv[0]);
    try std.testing.expectEqual(@as(u8, 2), recv[1]);

    const recv_rest = q.tryRecvBatchWith(&recv, .{ .items_max = 9 });
    try std.testing.expectEqual(@as(usize, 1), recv_rest);
    try std.testing.expectEqual(@as(u8, 7), recv[0]);
    try std.testing.expect(q.isEmpty());
}

test "mpsc queue len remains bounded during concurrent mutation" {
    if (caps.shouldSkipThreadedTests()) return error.SkipZigTest;

    const Q = MpscQueue(u16);
    var q = try Q.init(std.testing.allocator, .{ .capacity = 16 });
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
        try std.testing.expect(queue_len <= q.capacity());
        std.Thread.yield() catch {};
    }
    thread.join();

    try std.testing.expect(q.len() <= q.capacity());
}
