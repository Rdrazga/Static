//! Channel: blocking/non-blocking bounded MPMC channel with close semantics.
//!
//! Capacity: fixed at init time via the underlying ring buffer.
//! Thread safety: operations are serialized by an internal mutex.
//! Blocking behavior:
//! - `trySend` / `tryRecv` are always non-blocking.
//! - `send` / `recv` / `sendTimeout` / `recvTimeout` exist only when
//!   `supports_blocking_wait` is true.
//! - `ChannelBatchOptions.wake_mode` is effective only when blocking wait is enabled.
//! Close behavior:
//! - `close` rejects future sends immediately.
//! - Receives drain buffered items first, then return `error.Closed`.

const std = @import("std");
const ring = @import("ring_buffer.zig");
const sync = @import("static_sync");
const caps = @import("caps.zig");
const qi = @import("queue_internal.zig");
const contracts = @import("../contracts.zig");

pub fn Channel(comptime T: type) type {
    // Guard against zero-size types: the backing ring buffer is slot-based and
    // relies on addressable storage. For a signal-only channel, use `bool`.
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
        std.debug.assert(@alignOf(T) > 0);
    }

    const supports_blocking_wait_enabled = caps.blocking_wait_enabled;
    const supports_wait_queue_enabled = caps.wait_queue_enabled;

    const WaitSide = enum {
        send,
        recv,
    };
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

        pub const Element = T;
        pub const Error = ring.Error;
        pub const Config = ring.RingBuffer(T).Config;
        pub const concurrency: contracts.Concurrency = .mpmc;
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

        mutex: std.Thread.Mutex = .{},
        can_send: sync.condvar.Condvar = .{},
        can_recv: sync.condvar.Condvar = .{},
        closed: bool = false,
        wait_state: u32 = 0,
        rb: ring.RingBuffer(T),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            const self: Self = .{
                .rb = try ring.RingBuffer(T).init(allocator, cfg),
            };
            std.debug.assert(!self.closed);
            std.debug.assert(self.rb.capacity() > 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.rb.capacity() > 0);
            std.debug.assert(self.rb.len() <= self.rb.capacity());
            self.rb.deinit();
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
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

            std.debug.assert(self.rb.capacity() > 0);
            if (self.closed) return error.Closed;

            const old_len = self.rb.len();
            const sent_count = self.rb.tryPushBatch(values[0..items_limit]);
            std.debug.assert(sent_count <= items_limit);
            std.debug.assert(self.rb.len() == old_len + sent_count);
            if (sent_count > 0) {
                self.bumpWaitStateLocked();
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

            std.debug.assert(self.rb.capacity() > 0);
            const old_len = self.rb.len();
            const recv_count = self.rb.tryPopBatch(out[0..items_limit]);
            std.debug.assert(recv_count <= items_limit);
            std.debug.assert(self.rb.len() + recv_count == old_len);
            if (recv_count > 0) {
                self.bumpWaitStateLocked();
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
            self.bumpWaitStateLocked();
            self.wakeAllWaitersLocked();
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            std.debug.assert(self.rb.capacity() > 0);
            if (self.closed) return error.Closed;
            self.rb.tryPush(value) catch return error.WouldBlock;
            std.debug.assert(self.rb.len() > 0);
            self.bumpWaitStateLocked();
            self.wakeReceiverLocked();
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            std.debug.assert(self.rb.capacity() > 0);
            const old_len = self.rb.len();
            const value = self.rb.tryPop() catch {
                if (self.closed) return error.Closed;
                return error.WouldBlock;
            };
            std.debug.assert(self.rb.len() == old_len - 1);
            self.bumpWaitStateLocked();
            self.wakeSenderLocked();
            return value;
        }

        pub fn send(
            self: *Self,
            value: T,
            cancel: ?sync.cancel.CancelToken,
        ) SendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (self.closed) return error.Closed;
                if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;

                self.rb.tryPush(value) catch |err| switch (err) {
                    error.WouldBlock => {
                        const observed_state = self.readWaitStateLocked();
                        self.waitForProgressLocked(.send, observed_state, cancel, null) catch |wait_err| switch (wait_err) {
                            error.Cancelled => return error.Cancelled,
                            error.Timeout => unreachable,
                            error.Unsupported => unreachable,
                        };
                        continue;
                    },
                };

                self.bumpWaitStateLocked();
                self.wakeReceiverLocked();
                return;
            }
        }

        pub fn recv(
            self: *Self,
            cancel: ?sync.cancel.CancelToken,
        ) RecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                const old_len = self.rb.len();
                const value = self.rb.tryPop() catch {
                    if (self.closed) return error.Closed;
                    if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;

                    const observed_state = self.readWaitStateLocked();
                    self.waitForProgressLocked(.recv, observed_state, cancel, null) catch |wait_err| switch (wait_err) {
                        error.Cancelled => return error.Cancelled,
                        error.Timeout => unreachable,
                        error.Unsupported => unreachable,
                    };
                    continue;
                };

                std.debug.assert(self.rb.len() == old_len - 1);
                self.bumpWaitStateLocked();
                self.wakeSenderLocked();
                return value;
            }
        }

        pub fn sendTimeout(
            self: *Self,
            value: T,
            cancel: ?sync.cancel.CancelToken,
            timeout_ns: u64,
        ) SendTimeoutError!void {
            var timeout_budget = qi.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            };
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (self.closed) return error.Closed;
                if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;

                self.rb.tryPush(value) catch |err| switch (err) {
                    error.WouldBlock => {
                        const remaining_ns = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                            error.Timeout => return error.Timeout,
                            error.Unsupported => return error.Unsupported,
                        };
                        const observed_state = self.readWaitStateLocked();
                        self.waitForProgressLocked(.send, observed_state, cancel, remaining_ns) catch |wait_err| switch (wait_err) {
                            error.Cancelled => return error.Cancelled,
                            error.Timeout => return error.Timeout,
                            error.Unsupported => return error.Unsupported,
                        };
                        continue;
                    },
                };

                self.bumpWaitStateLocked();
                self.wakeReceiverLocked();
                return;
            }
        }

        pub fn recvTimeout(
            self: *Self,
            cancel: ?sync.cancel.CancelToken,
            timeout_ns: u64,
        ) RecvTimeoutError!T {
            var timeout_budget = qi.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            };
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                const old_len = self.rb.len();
                const value = self.rb.tryPop() catch {
                    if (self.closed) return error.Closed;
                    if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;

                    const remaining_ns = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                        error.Timeout => return error.Timeout,
                        error.Unsupported => return error.Unsupported,
                    };
                    const observed_state = self.readWaitStateLocked();
                    self.waitForProgressLocked(.recv, observed_state, cancel, remaining_ns) catch |wait_err| switch (wait_err) {
                        error.Cancelled => return error.Cancelled,
                        error.Timeout => return error.Timeout,
                        error.Unsupported => return error.Unsupported,
                    };
                    continue;
                };

                std.debug.assert(self.rb.len() == old_len - 1);
                self.bumpWaitStateLocked();
                self.wakeSenderLocked();
                return value;
            }
        }

        fn waitForProgressLocked(
            self: *Self,
            comptime side: WaitSide,
            observed_state: u32,
            cancel: ?sync.cancel.CancelToken,
            timeout_ns: ?u64,
        ) error{ Cancelled, Timeout, Unsupported }!void {
            if (supports_wait_queue_enabled) {
                self.mutex.unlock();
                defer self.mutex.lock();

                sync.wait_queue.waitValue(u32, &self.wait_state, observed_state, .{
                    .timeout_ns = timeout_ns,
                    .cancel = cancel,
                }) catch |wait_err| switch (wait_err) {
                    error.Cancelled => return error.Cancelled,
                    error.Timeout => return error.Timeout,
                    error.Unsupported => return error.Unsupported,
                };
                return;
            }

            if (timeout_ns) |timeout| {
                switch (side) {
                    .send => self.can_send.timedWait(&self.mutex, timeout) catch return error.Timeout,
                    .recv => self.can_recv.timedWait(&self.mutex, timeout) catch return error.Timeout,
                }
            } else {
                switch (side) {
                    .send => self.can_send.wait(&self.mutex),
                    .recv => self.can_recv.wait(&self.mutex),
                }
            }

            if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
        }

        fn readWaitStateLocked(self: *Self) u32 {
            return @atomicLoad(u32, &self.wait_state, .acquire);
        }

        fn bumpWaitStateLocked(self: *Self) void {
            _ = @atomicRmw(u32, &self.wait_state, .Add, 1, .acq_rel);
        }

        fn clampBatchWakeCount(progress_count: usize) u32 {
            if (progress_count >= std.math.maxInt(u32)) return std.math.maxInt(u32);
            return @as(u32, @intCast(progress_count));
        }

        fn wakeSenderCountLocked(self: *Self, wake_count_max: u32) void {
            if (wake_count_max == 0) return;
            if (supports_wait_queue_enabled) {
                self.can_send.signal();
                sync.wait_queue.wakeValue(u32, &self.wait_state, wake_count_max);
                return;
            }

            var signals_remaining = wake_count_max;
            while (signals_remaining > 0) : (signals_remaining -= 1) {
                self.can_send.signal();
            }
        }

        fn wakeReceiverCountLocked(self: *Self, wake_count_max: u32) void {
            if (wake_count_max == 0) return;
            if (supports_wait_queue_enabled) {
                self.can_recv.signal();
                sync.wait_queue.wakeValue(u32, &self.wait_state, wake_count_max);
                return;
            }

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
            std.debug.assert(progress_count > 0);
            switch (wake_mode) {
                .progress => self.wakeSenderCountLocked(clampBatchWakeCount(progress_count)),
                .single => self.wakeSenderCountLocked(1),
                .broadcast => self.wakeAllSendersLocked(),
            }
        }

        fn wakeReceiversForBatchLocked(
            self: *Self,
            progress_count: usize,
            wake_mode: BatchWakeMode,
        ) void {
            std.debug.assert(progress_count > 0);
            switch (wake_mode) {
                .progress => self.wakeReceiverCountLocked(clampBatchWakeCount(progress_count)),
                .single => self.wakeReceiverCountLocked(1),
                .broadcast => self.wakeAllReceiversLocked(),
            }
        }

        fn wakeSenderLocked(self: *Self) void {
            self.wakeSenderCountLocked(1);
        }

        fn wakeReceiverLocked(self: *Self) void {
            self.wakeReceiverCountLocked(1);
        }

        fn wakeAllSendersLocked(self: *Self) void {
            self.can_send.broadcast();
            if (supports_wait_queue_enabled) sync.wait_queue.wakeValue(u32, &self.wait_state, std.math.maxInt(u32));
        }

        fn wakeAllReceiversLocked(self: *Self) void {
            self.can_recv.broadcast();
            if (supports_wait_queue_enabled) sync.wait_queue.wakeValue(u32, &self.wait_state, std.math.maxInt(u32));
        }

        fn wakeAllWaitersLocked(self: *Self) void {
            self.can_send.broadcast();
            self.can_recv.broadcast();
            if (supports_wait_queue_enabled) sync.wait_queue.wakeValue(u32, &self.wait_state, std.math.maxInt(u32));
        }
    } else struct {
        const Self = @This();

        pub const Element = T;
        pub const Error = ring.Error;
        pub const Config = ring.RingBuffer(T).Config;
        pub const concurrency: contracts.Concurrency = .mpmc;
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

        mutex: std.Thread.Mutex = .{},
        closed: bool = false,
        rb: ring.RingBuffer(T),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            const self: Self = .{
                .rb = try ring.RingBuffer(T).init(allocator, cfg),
            };
            std.debug.assert(!self.closed);
            std.debug.assert(self.rb.capacity() > 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.rb.capacity() > 0);
            std.debug.assert(self.rb.len() <= self.rb.capacity());
            self.rb.deinit();
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
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

            switch (options.wake_mode) {
                .progress, .single, .broadcast => {},
            }
            self.mutex.lock();
            defer self.mutex.unlock();

            std.debug.assert(self.rb.capacity() > 0);
            if (self.closed) return error.Closed;

            const old_len = self.rb.len();
            const sent_count = self.rb.tryPushBatch(values[0..items_limit]);
            std.debug.assert(sent_count <= items_limit);
            std.debug.assert(self.rb.len() == old_len + sent_count);
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

            switch (options.wake_mode) {
                .progress, .single, .broadcast => {},
            }
            self.mutex.lock();
            defer self.mutex.unlock();

            std.debug.assert(self.rb.capacity() > 0);
            const old_len = self.rb.len();
            const recv_count = self.rb.tryPopBatch(out[0..items_limit]);
            std.debug.assert(recv_count <= items_limit);
            std.debug.assert(self.rb.len() + recv_count == old_len);
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

            std.debug.assert(self.rb.capacity() > 0);
            if (self.closed) return error.Closed;
            self.rb.tryPush(value) catch return error.WouldBlock;
            std.debug.assert(self.rb.len() > 0);
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            std.debug.assert(self.rb.capacity() > 0);
            const old_len = self.rb.len();
            const value = self.rb.tryPop() catch {
                if (self.closed) return error.Closed;
                return error.WouldBlock;
            };
            std.debug.assert(self.rb.len() == old_len - 1);
            return value;
        }
    };
}

test "channel blocking API shape is capability-gated" {
    const C = Channel(u8);
    try std.testing.expectEqual(C.supports_blocking_wait, @hasDecl(C, "send"));
    try std.testing.expectEqual(C.supports_blocking_wait, @hasDecl(C, "recv"));
    try std.testing.expectEqual(C.supports_timed_wait, @hasDecl(C, "sendTimeout"));
    try std.testing.expectEqual(C.supports_timed_wait, @hasDecl(C, "recvTimeout"));
}

test "channel close semantics for try APIs" {
    var c = try Channel(u8).init(std.testing.allocator, .{ .capacity = 1 });
    defer c.deinit();
    c.close();
    try std.testing.expectError(error.Closed, c.trySend(1));
    try std.testing.expectError(error.Closed, c.tryRecv());
}

test "channel introspection methods reflect queue state" {
    var c = try Channel(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer c.deinit();

    try std.testing.expectEqual(@as(usize, 2), c.capacity());
    try std.testing.expectEqual(@as(usize, 0), c.len());
    try std.testing.expect(c.isEmpty());
    try std.testing.expect(!c.isFull());

    try c.trySend(44);
    try std.testing.expectEqual(@as(usize, 1), c.len());
    try std.testing.expect(!c.isEmpty());
    try std.testing.expect(!c.isFull());
    try c.trySend(45);
    try std.testing.expect(c.isFull());

    _ = try c.tryRecv();
    try std.testing.expect(!c.isFull());
}

test "channel recv drains buffered items before Closed" {
    var c = try Channel(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer c.deinit();

    try c.trySend(1);
    c.close();

    try std.testing.expectEqual(@as(u8, 1), try c.tryRecv());
    try std.testing.expectError(error.Closed, c.tryRecv());
}

test "channel batch send and recv preserve prefix semantics" {
    var c = try Channel(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer c.deinit();

    const sent = try c.trySendBatch(&.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 2), sent);
    try std.testing.expect(c.isFull());

    var recv_small: [1]u8 = undefined;
    const recv_first = try c.tryRecvBatch(&recv_small);
    try std.testing.expectEqual(@as(usize, 1), recv_first);
    try std.testing.expectEqual(@as(u8, 1), recv_small[0]);

    var recv_large: [3]u8 = undefined;
    const recv_second = try c.tryRecvBatch(&recv_large);
    try std.testing.expectEqual(@as(usize, 1), recv_second);
    try std.testing.expectEqual(@as(u8, 2), recv_large[0]);
    try std.testing.expectEqual(@as(usize, 0), try c.tryRecvBatch(&recv_large));
}

test "channel batch options bound work and define close behavior" {
    const C = Channel(u8);
    const wake_mode_batch: C.BatchWakeMode = if (C.supports_blocking_wait) .single else .progress;
    const wake_mode_close: C.BatchWakeMode = if (C.supports_blocking_wait) .broadcast else .progress;

    var c = try C.init(std.testing.allocator, .{ .capacity = 3 });
    defer c.deinit();

    const sent_zero = try c.trySendBatchWith(&.{ 1, 2 }, .{
        .items_max = 0,
        .wake_mode = wake_mode_batch,
    });
    try std.testing.expectEqual(@as(usize, 0), sent_zero);
    try std.testing.expect(c.isEmpty());

    const sent_two = try c.trySendBatchWith(&.{ 1, 2, 3 }, .{
        .items_max = 2,
        .wake_mode = wake_mode_batch,
    });
    try std.testing.expectEqual(@as(usize, 2), sent_two);
    try std.testing.expectEqual(@as(usize, 2), c.len());

    var recv: [4]u8 = undefined;
    const recv_one = try c.tryRecvBatchWith(&recv, .{
        .items_max = 1,
        .wake_mode = wake_mode_batch,
    });
    try std.testing.expectEqual(@as(usize, 1), recv_one);
    try std.testing.expectEqual(@as(u8, 1), recv[0]);

    c.close();

    const empty_send_after_close = try c.trySendBatchWith(&.{}, .{
        .items_max = 1,
        .wake_mode = wake_mode_close,
    });
    try std.testing.expectEqual(@as(usize, 0), empty_send_after_close);

    const empty_recv_after_close = try c.tryRecvBatchWith(recv[0..0], .{
        .items_max = 1,
        .wake_mode = wake_mode_close,
    });
    try std.testing.expectEqual(@as(usize, 0), empty_recv_after_close);

    try std.testing.expectError(error.Closed, c.trySendBatchWith(&.{9}, .{
        .items_max = 1,
        .wake_mode = wake_mode_batch,
    }));

    const recv_after_close = try c.tryRecvBatchWith(&recv, .{
        .items_max = 3,
        .wake_mode = wake_mode_batch,
    });
    try std.testing.expectEqual(@as(usize, 1), recv_after_close);
    try std.testing.expectEqual(@as(u8, 2), recv[0]);

    try std.testing.expectError(error.Closed, c.tryRecvBatchWith(&recv, .{
        .items_max = 3,
        .wake_mode = wake_mode_batch,
    }));
}

test "channel len remains bounded during concurrent mutation" {
    if (caps.shouldSkipThreadedTests()) return error.SkipZigTest;

    const C = Channel(u16);
    var c = try C.init(std.testing.allocator, .{ .capacity = 16 });
    defer c.deinit();

    const Worker = struct {
        channel: *C,
        iterations_max: u32,

        fn run(self: *@This()) void {
            var iterations: u32 = 0;
            while (iterations < self.iterations_max) : (iterations += 1) {
                self.channel.trySend(@as(u16, @intCast(iterations))) catch |err| switch (err) {
                    error.WouldBlock => {},
                    error.Closed => return,
                };
                _ = self.channel.tryRecv() catch |err| switch (err) {
                    error.WouldBlock => {},
                    error.Closed => return,
                };
                std.Thread.yield() catch {};
            }
        }
    };

    var worker = Worker{
        .channel = &c,
        .iterations_max = 20_000,
    };
    var thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    var checks: u32 = 0;
    while (checks < 20_000) : (checks += 1) {
        const queue_len = c.len();
        try std.testing.expect(queue_len <= c.capacity());
        std.Thread.yield() catch {};
    }
    thread.join();

    try std.testing.expect(c.len() <= c.capacity());
}

test "channel timed send and recv honor immediate timeout" {
    const C = Channel(u8);
    if (!@hasDecl(C, "sendTimeout")) return error.SkipZigTest;
    if (!@hasDecl(C, "recvTimeout")) return error.SkipZigTest;

    var c = try C.init(std.testing.allocator, .{ .capacity = 1 });
    defer c.deinit();

    try c.trySend(1);
    try std.testing.expectError(error.Timeout, c.sendTimeout(2, null, 0));

    _ = try c.tryRecv();
    try std.testing.expectError(error.Timeout, c.recvTimeout(null, 0));
}

test "channel timed ops prefer cancellation over timeout" {
    const C = Channel(u8);
    if (!@hasDecl(C, "sendTimeout")) return error.SkipZigTest;
    if (!@hasDecl(C, "recvTimeout")) return error.SkipZigTest;

    var c = try C.init(std.testing.allocator, .{ .capacity = 1 });
    defer c.deinit();
    try c.trySend(1);

    var source = sync.cancel.CancelSource{};
    source.cancel();
    const token = source.token();
    try std.testing.expectError(error.Cancelled, c.sendTimeout(2, token, std.time.ns_per_ms));

    _ = try c.tryRecv();
    try std.testing.expectError(error.Cancelled, c.recvTimeout(token, std.time.ns_per_ms));
}

test "channel blocking recv wakes on close when supported" {
    const C = Channel(u8);
    if (!@hasDecl(C, "recv")) return error.SkipZigTest;

    var channel = try C.init(std.testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();

    const Waiter = struct {
        ch: *C,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            _ = self.ch.recv(null) catch |err| {
                self.result = err;
                return;
            };
            self.result = null;
        }
    };

    var waiter = Waiter{ .ch = &channel };
    var thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});

    channel.close();
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.Closed), waiter.result);
}

test "channel blocking send wakes on close when supported" {
    const C = Channel(u8);
    if (!@hasDecl(C, "send")) return error.SkipZigTest;

    var channel = try C.init(std.testing.allocator, .{ .capacity = 1 });
    defer channel.deinit();
    try channel.trySend(11);

    const Waiter = struct {
        ch: *C,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.ch.send(22, null) catch |err| {
                self.result = err;
                return;
            };
            self.result = null;
        }
    };

    var waiter = Waiter{ .ch = &channel };
    var thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});

    channel.close();
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.Closed), waiter.result);
}

test "channel batch progress wake mode unblocks multiple receivers" {
    const C = Channel(u8);
    if (!@hasDecl(C, "recv")) return error.SkipZigTest;

    var channel = try C.init(std.testing.allocator, .{ .capacity = 3 });
    defer channel.deinit();

    const Waiter = struct {
        ch: *C,
        started_count: *std.atomic.Value(u32),
        done_count: *std.atomic.Value(u32),
        failed_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            _ = self.started_count.fetchAdd(1, .acq_rel);
            _ = self.ch.recv(null) catch {
                _ = self.failed_count.fetchAdd(1, .acq_rel);
                return;
            };
            _ = self.done_count.fetchAdd(1, .acq_rel);
        }
    };

    var started_count = std.atomic.Value(u32).init(0);
    var done_count = std.atomic.Value(u32).init(0);
    var failed_count = std.atomic.Value(u32).init(0);
    var waiter0 = Waiter{ .ch = &channel, .started_count = &started_count, .done_count = &done_count, .failed_count = &failed_count };
    var waiter1 = Waiter{ .ch = &channel, .started_count = &started_count, .done_count = &done_count, .failed_count = &failed_count };
    var waiter2 = Waiter{ .ch = &channel, .started_count = &started_count, .done_count = &done_count, .failed_count = &failed_count };
    var thread0 = try std.Thread.spawn(.{}, Waiter.run, .{&waiter0});
    var thread1 = try std.Thread.spawn(.{}, Waiter.run, .{&waiter1});
    var thread2 = try std.Thread.spawn(.{}, Waiter.run, .{&waiter2});

    try std.testing.expect(waitForAtomicAtLeast(&started_count, 3, 20_000));

    const sent = try channel.trySendBatchWith(&.{ 11, 12, 13 }, .{
        .items_max = 3,
        .wake_mode = .progress,
    });
    try std.testing.expectEqual(@as(usize, 3), sent);

    const all_done = waitForAtomicAtLeast(&done_count, 3, 20_000);
    if (!all_done) channel.close();
    thread0.join();
    thread1.join();
    thread2.join();
    try std.testing.expect(all_done);
    try std.testing.expectEqual(@as(u32, 0), failed_count.load(.acquire));
}

test "channel batch single wake mode unblocks at least one receiver" {
    const C = Channel(u8);
    if (!@hasDecl(C, "recv")) return error.SkipZigTest;

    var channel = try C.init(std.testing.allocator, .{ .capacity = 2 });
    defer channel.deinit();

    const Waiter = struct {
        ch: *C,
        started_count: *std.atomic.Value(u32),
        done_count: *std.atomic.Value(u32),
        failed_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            _ = self.started_count.fetchAdd(1, .acq_rel);
            _ = self.ch.recv(null) catch {
                _ = self.failed_count.fetchAdd(1, .acq_rel);
                return;
            };
            _ = self.done_count.fetchAdd(1, .acq_rel);
        }
    };

    var started_count = std.atomic.Value(u32).init(0);
    var done_count = std.atomic.Value(u32).init(0);
    var failed_count = std.atomic.Value(u32).init(0);
    var waiter0 = Waiter{ .ch = &channel, .started_count = &started_count, .done_count = &done_count, .failed_count = &failed_count };
    var waiter1 = Waiter{ .ch = &channel, .started_count = &started_count, .done_count = &done_count, .failed_count = &failed_count };
    var thread0 = try std.Thread.spawn(.{}, Waiter.run, .{&waiter0});
    var thread1 = try std.Thread.spawn(.{}, Waiter.run, .{&waiter1});

    try std.testing.expect(waitForAtomicAtLeast(&started_count, 2, 20_000));

    const sent = try channel.trySendBatchWith(&.{ 21, 22 }, .{
        .items_max = 2,
        .wake_mode = .single,
    });
    try std.testing.expectEqual(@as(usize, 2), sent);

    const one_done = waitForAtomicAtLeast(&done_count, 1, 20_000);
    channel.close();
    thread0.join();
    thread1.join();
    try std.testing.expect(one_done);
    try std.testing.expect(done_count.load(.acquire) >= 1);
    try std.testing.expect(failed_count.load(.acquire) <= 1);
}

test "channel batch broadcast wake mode unblocks all receivers" {
    const C = Channel(u8);
    if (!@hasDecl(C, "recv")) return error.SkipZigTest;

    var channel = try C.init(std.testing.allocator, .{ .capacity = 2 });
    defer channel.deinit();

    const Waiter = struct {
        ch: *C,
        started_count: *std.atomic.Value(u32),
        done_count: *std.atomic.Value(u32),
        failed_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            _ = self.started_count.fetchAdd(1, .acq_rel);
            _ = self.ch.recv(null) catch {
                _ = self.failed_count.fetchAdd(1, .acq_rel);
                return;
            };
            _ = self.done_count.fetchAdd(1, .acq_rel);
        }
    };

    var started_count = std.atomic.Value(u32).init(0);
    var done_count = std.atomic.Value(u32).init(0);
    var failed_count = std.atomic.Value(u32).init(0);
    var waiter0 = Waiter{ .ch = &channel, .started_count = &started_count, .done_count = &done_count, .failed_count = &failed_count };
    var waiter1 = Waiter{ .ch = &channel, .started_count = &started_count, .done_count = &done_count, .failed_count = &failed_count };
    var thread0 = try std.Thread.spawn(.{}, Waiter.run, .{&waiter0});
    var thread1 = try std.Thread.spawn(.{}, Waiter.run, .{&waiter1});

    try std.testing.expect(waitForAtomicAtLeast(&started_count, 2, 20_000));

    const sent = try channel.trySendBatchWith(&.{ 31, 32 }, .{
        .items_max = 2,
        .wake_mode = .broadcast,
    });
    try std.testing.expectEqual(@as(usize, 2), sent);

    const all_done = waitForAtomicAtLeast(&done_count, 2, 20_000);
    if (!all_done) channel.close();
    thread0.join();
    thread1.join();
    try std.testing.expect(all_done);
    try std.testing.expectEqual(@as(u32, 0), failed_count.load(.acquire));
}

fn waitForAtomicAtLeast(counter: *const std.atomic.Value(u32), threshold: u32, iterations_max: u32) bool {
    var iterations: u32 = 0;
    while (iterations < iterations_max) : (iterations += 1) {
        if (counter.load(.acquire) >= threshold) return true;
        std.Thread.yield() catch {};
    }
    return false;
}
