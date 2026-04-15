//! SpscChannel: blocking/non-blocking bounded SPSC channel with close semantics.
//!
//! Capacity: fixed at init time via the underlying `SpscQueue`.
//! Thread safety: intended for one producer and one consumer.
//! Blocking behavior:
//! - `trySend` / `tryRecv` are always non-blocking.
//! - `send` / `recv` / timed variants exist only when `supports_blocking_wait` is true.
//! Close behavior:
//! - `close` rejects future sends immediately.
//! - Receives drain buffered items first, then return `error.Closed`.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const spsc = @import("../spsc.zig");
const ring = @import("../ring_buffer.zig");
const sync = @import("static_sync");
const caps = @import("../caps.zig");
const qi = @import("../queue_internal.zig");
const contracts = @import("../../contracts.zig");

pub fn SpscChannel(comptime T: type) type {
    comptime {
        assert(@sizeOf(T) > 0);
        assert(@alignOf(T) > 0);
    }

    const supports_blocking_wait_enabled = caps.blocking_wait_enabled;
    const BatchWakeModeType = enum {
        progress,
        single,
        broadcast,
    };
    const ChannelBatchOptionsType = struct {
        items_max: usize = std.math.maxInt(usize),
        wake_mode: BatchWakeModeType = .progress,
    };

    return if (supports_blocking_wait_enabled) struct {
        const Self = @This();
        const WaitSide = enum {
            send,
            recv,
        };
        const cancel_poll_ns: u64 = std.time.ns_per_ms;

        pub const Element = T;
        pub const Error = ring.Error;
        pub const Config = spsc.SpscQueue(T).Config;
        pub const concurrency: contracts.Concurrency = .spsc;
        pub const is_lock_free = false;
        pub const supports_close = true;
        pub const supports_blocking_wait = true;
        pub const supports_timed_wait = true;
        pub const len_semantics: contracts.LenSemantics = .exact;
        pub const TrySendError = error{ WouldBlock, Closed };
        pub const TryRecvError = error{ WouldBlock, Closed };
        pub const TrySendBatchError = error{Closed};
        pub const TryRecvBatchError = error{Closed};
        pub const BatchWakeMode = BatchWakeModeType;
        pub const ChannelBatchOptions = ChannelBatchOptionsType;
        pub const SendError = error{ Closed, Cancelled };
        pub const RecvError = error{ Closed, Cancelled };
        pub const SendTimeoutError = error{ Closed, Cancelled, Timeout, Unsupported };
        pub const RecvTimeoutError = error{ Closed, Cancelled, Timeout, Unsupported };

        mutex: sync.threading.Mutex = .{},
        can_send: sync.condvar.Condvar = .{},
        can_recv: sync.condvar.Condvar = .{},
        closed: bool = false,
        send_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        recv_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        queue: spsc.SpscQueue(T),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            const self: Self = .{
                .queue = try spsc.SpscQueue(T).init(allocator, cfg),
            };
            assert(!self.closed);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.queue.capacity();
        }

        pub fn len(self: *const Self) usize {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            return self.queue.len();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == self.capacity();
        }

        pub fn trySendBatch(self: *Self, values: []const T) TrySendBatchError!usize {
            return self.trySendBatchWith(values, .{
                .items_max = values.len,
                .wake_mode = .progress,
            });
        }

        pub fn trySendBatchWith(
            self: *Self,
            values: []const T,
            options: ChannelBatchOptions,
        ) TrySendBatchError!usize {
            const items_limit = @min(values.len, options.items_max);
            if (items_limit == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            assert(self.queue.capacity() > 0);
            if (self.closed) return error.Closed;

            const old_len = self.queue.len();
            var sent_count: usize = 0;
            while (sent_count < items_limit) : (sent_count += 1) {
                self.queue.trySend(values[sent_count]) catch |err| switch (err) {
                    error.WouldBlock => break,
                };
            }
            assert(sent_count <= items_limit);
            assert(self.queue.len() == old_len + sent_count);
            if (sent_count > 0) {
                self.wakeReceiversForBatchLocked(sent_count, options.wake_mode);
            }
            return sent_count;
        }

        pub fn tryRecvBatch(self: *Self, out: []T) TryRecvBatchError!usize {
            return self.tryRecvBatchWith(out, .{
                .items_max = out.len,
                .wake_mode = .progress,
            });
        }

        pub fn tryRecvBatchWith(
            self: *Self,
            out: []T,
            options: ChannelBatchOptions,
        ) TryRecvBatchError!usize {
            const items_limit = @min(out.len, options.items_max);
            if (items_limit == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            assert(self.queue.capacity() > 0);
            const old_len = self.queue.len();
            var recv_count: usize = 0;
            while (recv_count < items_limit) : (recv_count += 1) {
                out[recv_count] = self.queue.tryRecv() catch |err| switch (err) {
                    error.WouldBlock => break,
                };
            }
            assert(recv_count <= items_limit);
            assert(self.queue.len() + recv_count == old_len);
            if (recv_count > 0) {
                self.wakeSendersForBatchLocked(recv_count, options.wake_mode);
                return recv_count;
            }

            if (self.closed) return error.Closed;
            return 0;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return;
            self.closed = true;
            self.can_send.broadcast();
            self.can_recv.broadcast();
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.Closed;
            self.queue.trySend(value) catch return error.WouldBlock;
            self.can_recv.signal();
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const value = self.queue.tryRecv() catch {
                if (self.closed) return error.Closed;
                return error.WouldBlock;
            };
            self.can_send.signal();
            return value;
        }

        pub fn send(self: *Self, value: T, cancel: ?sync.cancel.CancelToken) SendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (self.closed) return error.Closed;
                if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;

                self.queue.trySend(value) catch |err| switch (err) {
                    error.WouldBlock => {
                        _ = self.send_waiters.fetchAdd(1, .acq_rel);
                        defer _ = self.send_waiters.fetchSub(1, .acq_rel);
                        self.waitForProgressLocked(.send, cancel, null) catch |wait_err| switch (wait_err) {
                            error.Cancelled => return error.Cancelled,
                            error.Timeout => unreachable,
                        };
                        continue;
                    },
                };

                self.can_recv.signal();
                return;
            }
        }

        pub fn recv(self: *Self, cancel: ?sync.cancel.CancelToken) RecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                const value = self.queue.tryRecv() catch {
                    if (self.closed) return error.Closed;
                    if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
                    _ = self.recv_waiters.fetchAdd(1, .acq_rel);
                    defer _ = self.recv_waiters.fetchSub(1, .acq_rel);
                    self.waitForProgressLocked(.recv, cancel, null) catch |wait_err| switch (wait_err) {
                        error.Cancelled => return error.Cancelled,
                        error.Timeout => unreachable,
                    };
                    continue;
                };

                self.can_send.signal();
                return value;
            }
        }

        pub fn sendTimeout(self: *Self, value: T, cancel: ?sync.cancel.CancelToken, timeout_ns: u64) SendTimeoutError!void {
            var timeout_budget = qi.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            };
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (self.closed) return error.Closed;
                if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;

                self.queue.trySend(value) catch |err| switch (err) {
                    error.WouldBlock => {
                        const remaining_ns = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                            error.Timeout => return error.Timeout,
                            error.Unsupported => return error.Unsupported,
                        };
                        _ = self.send_waiters.fetchAdd(1, .acq_rel);
                        defer _ = self.send_waiters.fetchSub(1, .acq_rel);
                        self.waitForProgressLocked(.send, cancel, remaining_ns) catch |wait_err| switch (wait_err) {
                            error.Cancelled => return error.Cancelled,
                            error.Timeout => return error.Timeout,
                        };
                        continue;
                    },
                };

                self.can_recv.signal();
                return;
            }
        }

        pub fn recvTimeout(self: *Self, cancel: ?sync.cancel.CancelToken, timeout_ns: u64) RecvTimeoutError!T {
            var timeout_budget = qi.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            };
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                const value = self.queue.tryRecv() catch {
                    if (self.closed) return error.Closed;
                    if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
                    const remaining_ns = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                        error.Timeout => return error.Timeout,
                        error.Unsupported => return error.Unsupported,
                    };
                    _ = self.recv_waiters.fetchAdd(1, .acq_rel);
                    defer _ = self.recv_waiters.fetchSub(1, .acq_rel);
                    self.waitForProgressLocked(.recv, cancel, remaining_ns) catch |wait_err| switch (wait_err) {
                        error.Cancelled => return error.Cancelled,
                        error.Timeout => return error.Timeout,
                    };
                    continue;
                };

                self.can_send.signal();
                return value;
            }
        }

        fn clampBatchWakeCount(progress_count: usize) u32 {
            if (progress_count >= std.math.maxInt(u32)) return std.math.maxInt(u32);
            return @as(u32, @intCast(progress_count));
        }

        fn wakeSenderCountLocked(self: *Self, wake_count_max: u32) void {
            if (wake_count_max == 0) return;
            var signals_remaining = wake_count_max;
            while (signals_remaining > 0) : (signals_remaining -= 1) {
                self.can_send.signal();
            }
        }

        fn wakeReceiverCountLocked(self: *Self, wake_count_max: u32) void {
            if (wake_count_max == 0) return;
            var signals_remaining = wake_count_max;
            while (signals_remaining > 0) : (signals_remaining -= 1) {
                self.can_recv.signal();
            }
        }

        fn wakeSendersForBatchLocked(
            self: *Self,
            progress_count: usize,
            wake_mode: BatchWakeMode,
        ) void {
            assert(progress_count > 0);
            switch (wake_mode) {
                .progress => self.wakeSenderCountLocked(clampBatchWakeCount(progress_count)),
                .single => self.wakeSenderCountLocked(1),
                .broadcast => self.can_send.broadcast(),
            }
        }

        fn wakeReceiversForBatchLocked(
            self: *Self,
            progress_count: usize,
            wake_mode: BatchWakeMode,
        ) void {
            assert(progress_count > 0);
            switch (wake_mode) {
                .progress => self.wakeReceiverCountLocked(clampBatchWakeCount(progress_count)),
                .single => self.wakeReceiverCountLocked(1),
                .broadcast => self.can_recv.broadcast(),
            }
        }

        fn waitForProgressLocked(
            self: *Self,
            comptime side: WaitSide,
            cancel: ?sync.cancel.CancelToken,
            timeout_ns: ?u64,
        ) error{ Cancelled, Timeout }!void {
            if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;

            if (timeout_ns) |timeout| {
                var wait_ns = timeout;
                if (cancel != null and wait_ns > cancel_poll_ns) {
                    wait_ns = cancel_poll_ns;
                }
                switch (side) {
                    .send => self.can_send.timedWait(&self.mutex, wait_ns) catch |err| switch (err) {
                        error.Timeout => {
                            if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
                            if (wait_ns == timeout) return error.Timeout;
                            return;
                        },
                    },
                    .recv => self.can_recv.timedWait(&self.mutex, wait_ns) catch |err| switch (err) {
                        error.Timeout => {
                            if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
                            if (wait_ns == timeout) return error.Timeout;
                            return;
                        },
                    },
                }
                return;
            }

            if (cancel == null) {
                switch (side) {
                    .send => self.can_send.wait(&self.mutex),
                    .recv => self.can_recv.wait(&self.mutex),
                }
                return;
            }

            switch (side) {
                .send => self.can_send.timedWait(&self.mutex, cancel_poll_ns) catch |err| switch (err) {
                    error.Timeout => {},
                },
                .recv => self.can_recv.timedWait(&self.mutex, cancel_poll_ns) catch |err| switch (err) {
                    error.Timeout => {},
                },
            }

            if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
        }
    } else struct {
        const Self = @This();

        pub const Element = T;
        pub const Error = ring.Error;
        pub const Config = spsc.SpscQueue(T).Config;
        pub const concurrency: contracts.Concurrency = .spsc;
        pub const is_lock_free = false;
        pub const supports_close = true;
        pub const supports_blocking_wait = false;
        pub const supports_timed_wait = false;
        pub const len_semantics: contracts.LenSemantics = .exact;
        pub const TrySendError = error{ WouldBlock, Closed };
        pub const TryRecvError = error{ WouldBlock, Closed };
        pub const TrySendBatchError = error{Closed};
        pub const TryRecvBatchError = error{Closed};
        pub const BatchWakeMode = BatchWakeModeType;
        pub const ChannelBatchOptions = ChannelBatchOptionsType;

        mutex: sync.threading.Mutex = .{},
        closed: bool = false,
        queue: spsc.SpscQueue(T),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            const self: Self = .{
                .queue = try spsc.SpscQueue(T).init(allocator, cfg),
            };
            assert(!self.closed);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.queue.capacity();
        }

        pub fn len(self: *const Self) usize {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            return self.queue.len();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == self.capacity();
        }

        pub fn trySendBatch(self: *Self, values: []const T) TrySendBatchError!usize {
            return self.trySendBatchWith(values, .{
                .items_max = values.len,
                .wake_mode = .progress,
            });
        }

        pub fn trySendBatchWith(
            self: *Self,
            values: []const T,
            options: ChannelBatchOptions,
        ) TrySendBatchError!usize {
            const items_limit = @min(values.len, options.items_max);
            if (items_limit == 0) return 0;

            assert(options.wake_mode == .progress);
            self.mutex.lock();
            defer self.mutex.unlock();

            assert(self.queue.capacity() > 0);
            if (self.closed) return error.Closed;

            const old_len = self.queue.len();
            var sent_count: usize = 0;
            while (sent_count < items_limit) : (sent_count += 1) {
                self.queue.trySend(values[sent_count]) catch |err| switch (err) {
                    error.WouldBlock => break,
                };
            }
            assert(sent_count <= items_limit);
            assert(self.queue.len() == old_len + sent_count);
            return sent_count;
        }

        pub fn tryRecvBatch(self: *Self, out: []T) TryRecvBatchError!usize {
            return self.tryRecvBatchWith(out, .{
                .items_max = out.len,
                .wake_mode = .progress,
            });
        }

        pub fn tryRecvBatchWith(
            self: *Self,
            out: []T,
            options: ChannelBatchOptions,
        ) TryRecvBatchError!usize {
            const items_limit = @min(out.len, options.items_max);
            if (items_limit == 0) return 0;

            assert(options.wake_mode == .progress);
            self.mutex.lock();
            defer self.mutex.unlock();

            assert(self.queue.capacity() > 0);
            const old_len = self.queue.len();
            var recv_count: usize = 0;
            while (recv_count < items_limit) : (recv_count += 1) {
                out[recv_count] = self.queue.tryRecv() catch |err| switch (err) {
                    error.WouldBlock => break,
                };
            }
            assert(recv_count <= items_limit);
            assert(self.queue.len() + recv_count == old_len);
            if (recv_count > 0) return recv_count;

            if (self.closed) return error.Closed;
            return 0;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.Closed;
            self.queue.trySend(value) catch return error.WouldBlock;
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const value = self.queue.tryRecv() catch {
                if (self.closed) return error.Closed;
                return error.WouldBlock;
            };
            return value;
        }
    };
}

test "spsc channel blocking API shape is capability-gated" {
    const C = SpscChannel(u8);
    try testing.expectEqual(C.supports_blocking_wait, @hasDecl(C, "send"));
    try testing.expectEqual(C.supports_blocking_wait, @hasDecl(C, "recv"));
    try testing.expectEqual(C.supports_timed_wait, @hasDecl(C, "sendTimeout"));
    try testing.expectEqual(C.supports_timed_wait, @hasDecl(C, "recvTimeout"));
}

test "spsc channel close semantics for try APIs" {
    var c = try SpscChannel(u8).init(testing.allocator, .{ .capacity = 2 });
    defer c.deinit();

    try c.trySend(1);
    c.close();
    try testing.expectError(error.Closed, c.trySend(2));
    try testing.expectEqual(@as(u8, 1), try c.tryRecv());
    try testing.expectError(error.Closed, c.tryRecv());
}

test "spsc channel introspection methods reflect queue state" {
    var c = try SpscChannel(u8).init(testing.allocator, .{ .capacity = 2 });
    defer c.deinit();

    try testing.expectEqual(@as(usize, 2), c.capacity());
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expect(c.isEmpty());
    try testing.expect(!c.isFull());

    try c.trySend(1);
    try testing.expectEqual(@as(usize, 1), c.len());
    try testing.expect(!c.isEmpty());
    try testing.expect(!c.isFull());

    try c.trySend(2);
    try testing.expect(c.isFull());

    _ = try c.tryRecv();
    try testing.expect(!c.isFull());
}

test "spsc channel batch send and recv preserve prefix semantics" {
    var c = try SpscChannel(u8).init(testing.allocator, .{ .capacity = 2 });
    defer c.deinit();

    const sent = try c.trySendBatch(&.{ 1, 2, 3 });
    try testing.expectEqual(@as(usize, 2), sent);
    try testing.expect(c.isFull());

    var recv_small: [1]u8 = undefined;
    const recv_first = try c.tryRecvBatch(&recv_small);
    try testing.expectEqual(@as(usize, 1), recv_first);
    try testing.expectEqual(@as(u8, 1), recv_small[0]);

    var recv_large: [3]u8 = undefined;
    const recv_second = try c.tryRecvBatch(&recv_large);
    try testing.expectEqual(@as(usize, 1), recv_second);
    try testing.expectEqual(@as(u8, 2), recv_large[0]);
    try testing.expectEqual(@as(usize, 0), try c.tryRecvBatch(&recv_large));
}

test "spsc channel batch options bound work and define close behavior" {
    const C = SpscChannel(u8);
    const wake_mode_batch: C.BatchWakeMode = if (C.supports_blocking_wait) .single else .progress;
    const wake_mode_close: C.BatchWakeMode = if (C.supports_blocking_wait) .broadcast else .progress;

    var c = try C.init(testing.allocator, .{ .capacity = 3 });
    defer c.deinit();

    const sent_zero = try c.trySendBatchWith(&.{ 1, 2 }, .{
        .items_max = 0,
        .wake_mode = wake_mode_batch,
    });
    try testing.expectEqual(@as(usize, 0), sent_zero);
    try testing.expect(c.isEmpty());

    const sent_two = try c.trySendBatchWith(&.{ 1, 2, 3 }, .{
        .items_max = 2,
        .wake_mode = wake_mode_batch,
    });
    try testing.expectEqual(@as(usize, 2), sent_two);
    try testing.expectEqual(@as(usize, 2), c.len());

    var recv: [4]u8 = undefined;
    const recv_one = try c.tryRecvBatchWith(&recv, .{
        .items_max = 1,
        .wake_mode = wake_mode_batch,
    });
    try testing.expectEqual(@as(usize, 1), recv_one);
    try testing.expectEqual(@as(u8, 1), recv[0]);

    c.close();

    const empty_send_after_close = try c.trySendBatchWith(&.{}, .{
        .items_max = 1,
        .wake_mode = wake_mode_close,
    });
    try testing.expectEqual(@as(usize, 0), empty_send_after_close);

    const empty_recv_after_close = try c.tryRecvBatchWith(recv[0..0], .{
        .items_max = 1,
        .wake_mode = wake_mode_close,
    });
    try testing.expectEqual(@as(usize, 0), empty_recv_after_close);

    try testing.expectError(error.Closed, c.trySendBatchWith(&.{9}, .{
        .items_max = 1,
        .wake_mode = wake_mode_batch,
    }));

    const recv_after_close = try c.tryRecvBatchWith(&recv, .{
        .items_max = 3,
        .wake_mode = wake_mode_batch,
    });
    try testing.expectEqual(@as(usize, 1), recv_after_close);
    try testing.expectEqual(@as(u8, 2), recv[0]);

    try testing.expectError(error.Closed, c.tryRecvBatchWith(&recv, .{
        .items_max = 3,
        .wake_mode = wake_mode_batch,
    }));
}

test "spsc channel batch wake modes unblock waiting receiver" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "recv")) return error.SkipZigTest;

    const Waiter = struct {
        ch: *C,
        result: ?anyerror = null,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            _ = self.ch.recv(null) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    inline for ([_]C.BatchWakeMode{ .progress, .single, .broadcast }) |wake_mode| {
        var channel = try C.init(testing.allocator, .{ .capacity = 1 });
        defer channel.deinit();

        var waiter = Waiter{ .ch = &channel };
        var thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
        try testing.expect(waitForFlagTrue(&waiter.started, 10_000));

        const sent = try channel.trySendBatchWith(&.{99}, .{
            .items_max = 1,
            .wake_mode = wake_mode,
        });
        try testing.expectEqual(@as(usize, 1), sent);

        const completed = waitForFlagTrue(&waiter.done, 10_000);
        if (!completed) channel.close();
        thread.join();
        try testing.expect(completed);
        try testing.expectEqual(@as(?anyerror, null), waiter.result);
    }
}

test "spsc channel blocked recv drains buffered item before close reports closed" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "recv")) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();

    const Waiter = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,
        value: ?u8 = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.value = self.ch.recv(null) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    const Closer = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.close();
            self.done.store(true, .release);
        }
    };

    var waiter = Waiter{ .ch = &channel };
    var thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});

    try testing.expect(waitForFlagTrue(&waiter.started, 10_000));
    try waitForBlockedReceiver(&channel, 100 * std.time.ns_per_ms);

    // Stage the buffered item while the mutex is held, then let a blocked call
    // to the public `close()` wake the receiver after both states are present.
    channel.mutex.lock();
    try channel.queue.trySend(7);
    var closer = Closer{ .ch = &channel };
    var close_thread = try std.Thread.spawn(.{}, Closer.run, .{&closer});
    try testing.expect(waitForFlagTrue(&closer.started, 10_000));
    channel.mutex.unlock();

    try testing.expect(waitForFlagTrue(&waiter.done, 10_000));
    thread.join();
    close_thread.join();
    try testing.expect(closer.done.load(.acquire));
    try testing.expectEqual(@as(?anyerror, null), waiter.result);
    try testing.expectEqual(@as(?u8, 7), waiter.value);
    try testing.expectError(error.Closed, channel.tryRecv());
}

test "spsc channel blocked send wakes on close and preserves buffered item" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "send")) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();
    try channel.trySend(9);

    const Sender = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.send(7, null) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    const Closer = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.close();
            self.done.store(true, .release);
        }
    };

    var sender = Sender{ .ch = &channel };
    var sender_thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});

    try testing.expect(waitForFlagTrue(&sender.started, 10_000));
    try waitForBlockedSender(&channel, 100 * std.time.ns_per_ms);

    var closer = Closer{ .ch = &channel };
    var close_thread = try std.Thread.spawn(.{}, Closer.run, .{&closer});

    try testing.expect(waitForFlagTrue(&closer.started, 10_000));
    try testing.expect(waitForFlagTrue(&sender.done, 10_000));
    sender_thread.join();
    close_thread.join();

    try testing.expect(closer.done.load(.acquire));
    try testing.expectEqual(@as(?anyerror, error.Closed), sender.result);
    try testing.expectEqual(@as(u8, 9), try channel.tryRecv());
    try testing.expectError(error.Closed, channel.tryRecv());
}

test "spsc channel timed send wakes on close before timeout and preserves buffered item" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "sendTimeout")) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();
    try channel.trySend(9);

    const Sender = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.sendTimeout(7, null, 5 * std.time.ns_per_s) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    const Closer = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.close();
            self.done.store(true, .release);
        }
    };

    var sender = Sender{ .ch = &channel };
    var sender_thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});

    try testing.expect(waitForFlagTrue(&sender.started, 10_000));
    try waitForBlockedSender(&channel, 100 * std.time.ns_per_ms);

    var closer = Closer{ .ch = &channel };
    var close_thread = try std.Thread.spawn(.{}, Closer.run, .{&closer});

    try testing.expect(waitForFlagTrue(&closer.started, 10_000));
    try testing.expect(waitForFlagTrue(&sender.done, 10_000));
    sender_thread.join();
    close_thread.join();

    try testing.expect(closer.done.load(.acquire));
    try testing.expectEqual(@as(?anyerror, error.Closed), sender.result);
    try testing.expectEqual(@as(u8, 9), try channel.tryRecv());
    try testing.expectError(error.Closed, channel.tryRecv());
}

test "spsc channel timed recv wakes on close before timeout when empty" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "recvTimeout")) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();

    const Receiver = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            _ = self.ch.recvTimeout(null, 5 * std.time.ns_per_s) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    const Closer = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.close();
            self.done.store(true, .release);
        }
    };

    var receiver = Receiver{ .ch = &channel };
    var recv_thread = try std.Thread.spawn(.{}, Receiver.run, .{&receiver});

    try testing.expect(waitForFlagTrue(&receiver.started, 10_000));
    try waitForBlockedReceiver(&channel, 100 * std.time.ns_per_ms);

    var closer = Closer{ .ch = &channel };
    var close_thread = try std.Thread.spawn(.{}, Closer.run, .{&closer});

    try testing.expect(waitForFlagTrue(&closer.started, 10_000));
    try testing.expect(waitForFlagTrue(&receiver.done, 10_000));
    recv_thread.join();
    close_thread.join();

    try testing.expect(closer.done.load(.acquire));
    try testing.expectEqual(@as(?anyerror, error.Closed), receiver.result);
    try testing.expectError(error.Closed, channel.tryRecv());
}

test "spsc channel timed recv drains buffered item before later close reports closed" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "recvTimeout")) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();

    const Receiver = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,
        value: ?u8 = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.value = self.ch.recvTimeout(null, 5 * std.time.ns_per_s) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    const Closer = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.close();
            self.done.store(true, .release);
        }
    };

    var receiver = Receiver{ .ch = &channel };
    var recv_thread = try std.Thread.spawn(.{}, Receiver.run, .{&receiver});

    try testing.expect(waitForFlagTrue(&receiver.started, 10_000));
    try waitForBlockedReceiver(&channel, 100 * std.time.ns_per_ms);

    channel.mutex.lock();
    try channel.queue.trySend(7);
    var closer = Closer{ .ch = &channel };
    var close_thread = try std.Thread.spawn(.{}, Closer.run, .{&closer});
    try testing.expect(waitForFlagTrue(&closer.started, 10_000));
    channel.mutex.unlock();

    try testing.expect(waitForFlagTrue(&receiver.done, 10_000));
    recv_thread.join();
    close_thread.join();

    try testing.expect(closer.done.load(.acquire));
    try testing.expectEqual(@as(?anyerror, null), receiver.result);
    try testing.expectEqual(@as(?u8, 7), receiver.value);
    try testing.expectError(error.Closed, channel.tryRecv());
}

test "spsc channel timed recv succeeds after sender publish before later close" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "recvTimeout")) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();

    const Receiver = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,
        value: ?u8 = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.value = self.ch.recvTimeout(null, 5 * std.time.ns_per_s) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    const Sender = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.send(7, null) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    var receiver = Receiver{ .ch = &channel };
    var recv_thread = try std.Thread.spawn(.{}, Receiver.run, .{&receiver});

    try testing.expect(waitForFlagTrue(&receiver.started, 10_000));
    try waitForBlockedReceiver(&channel, 100 * std.time.ns_per_ms);

    var sender = Sender{ .ch = &channel };
    var sender_thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});

    try testing.expect(waitForFlagTrue(&sender.started, 10_000));
    try testing.expect(waitForFlagTrue(&sender.done, 10_000));
    try testing.expect(waitForFlagTrue(&receiver.done, 10_000));
    sender_thread.join();
    recv_thread.join();

    try testing.expectEqual(@as(?anyerror, null), sender.result);
    try testing.expectEqual(@as(?anyerror, null), receiver.result);
    try testing.expectEqual(@as(?u8, 7), receiver.value);

    channel.close();
    try testing.expectError(error.Closed, channel.tryRecv());
}

test "spsc channel timed send succeeds after receiver drain before later close" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "sendTimeout")) return error.SkipZigTest;

    var channel = try C.init(testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();
    try channel.trySend(9);

    const Sender = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.sendTimeout(7, null, 5 * std.time.ns_per_s) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    const Receiver = struct {
        ch: *C,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,
        value: ?u8 = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.value = self.ch.recv(null) catch |err| {
                self.result = err;
                self.done.store(true, .release);
                return;
            };
            self.result = null;
            self.done.store(true, .release);
        }
    };

    var sender = Sender{ .ch = &channel };
    var sender_thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});

    try testing.expect(waitForFlagTrue(&sender.started, 10_000));
    try waitForBlockedSender(&channel, 100 * std.time.ns_per_ms);

    var receiver = Receiver{ .ch = &channel };
    var recv_thread = try std.Thread.spawn(.{}, Receiver.run, .{&receiver});

    try testing.expect(waitForFlagTrue(&receiver.started, 10_000));
    try testing.expect(waitForFlagTrue(&receiver.done, 10_000));
    try testing.expect(waitForFlagTrue(&sender.done, 10_000));
    recv_thread.join();
    sender_thread.join();

    try testing.expectEqual(@as(?anyerror, null), receiver.result);
    try testing.expectEqual(@as(?u8, 9), receiver.value);
    try testing.expectEqual(@as(?anyerror, null), sender.result);

    channel.close();
    try testing.expectEqual(@as(u8, 7), try channel.tryRecv());
    try testing.expectError(error.Closed, channel.tryRecv());
}

test "spsc channel timed waits observe cancellation after wait starts" {
    const C = SpscChannel(u8);
    if (!@hasDecl(C, "sendTimeout")) return error.SkipZigTest;
    if (!@hasDecl(C, "recvTimeout")) return error.SkipZigTest;

    var c = try C.init(testing.allocator, .{ .capacity = 1 });
    defer c.deinit();

    try c.trySend(11);

    const SendWaiter = struct {
        ch: *C,
        token: sync.cancel.CancelToken,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.ch.sendTimeout(12, self.token, 5 * std.time.ns_per_s) catch |err| {
                self.result = err;
                return;
            };
            self.result = null;
        }
    };

    var send_cancel = sync.cancel.CancelSource{};
    var send_waiter = SendWaiter{
        .ch = &c,
        .token = send_cancel.token(),
    };
    var send_thread = try std.Thread.spawn(.{}, SendWaiter.run, .{&send_waiter});

    try testing.expect(waitForFlagTrue(&send_waiter.started, 10_000));
    send_cancel.cancel();
    send_thread.join();
    try testing.expectEqual(@as(?anyerror, error.Cancelled), send_waiter.result);

    try testing.expectEqual(@as(u8, 11), try c.tryRecv());

    const RecvWaiter = struct {
        ch: *C,
        token: sync.cancel.CancelToken,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            _ = self.ch.recvTimeout(self.token, 5 * std.time.ns_per_s) catch |err| {
                self.result = err;
                return;
            };
            self.result = null;
        }
    };

    var recv_cancel = sync.cancel.CancelSource{};
    var recv_waiter = RecvWaiter{
        .ch = &c,
        .token = recv_cancel.token(),
    };
    var recv_thread = try std.Thread.spawn(.{}, RecvWaiter.run, .{&recv_waiter});

    try testing.expect(waitForFlagTrue(&recv_waiter.started, 10_000));
    recv_cancel.cancel();
    recv_thread.join();
    try testing.expectEqual(@as(?anyerror, error.Cancelled), recv_waiter.result);
}

fn waitForFlagTrue(flag: *const std.atomic.Value(bool), iterations_max: u32) bool {
    var iterations: u32 = 0;
    while (iterations < iterations_max) : (iterations += 1) {
        if (flag.load(.acquire)) return true;
        std.Thread.yield() catch {};
    }
    return false;
}

fn waitForBlockedReceiver(channel: anytype, timeout_ns: u64) !void {
    const start = core.time_compat.Instant.now() catch return error.SkipZigTest;
    while (true) {
        channel.mutex.lock();
        const is_blocked = channel.recv_waiters.load(.acquire) > 0 and channel.queue.len() == 0 and !channel.closed;
        channel.mutex.unlock();
        if (is_blocked) return;

        const elapsed = (core.time_compat.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

fn waitForBlockedSender(channel: anytype, timeout_ns: u64) !void {
    const start = core.time_compat.Instant.now() catch return error.SkipZigTest;
    while (true) {
        channel.mutex.lock();
        const is_blocked = channel.send_waiters.load(.acquire) > 0 and channel.queue.len() == channel.queue.capacity() and !channel.closed;
        channel.mutex.unlock();
        if (is_blocked) return;

        const elapsed = (core.time_compat.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
