//! InboxOutbox: double-buffered publish barrier for single-writer, single-reader workflows.
//!
//! Capacity: two independent fixed-capacity ring buffers (inbox and outbox).
//! Thread safety: not thread-safe; the writer owns the outbox, the reader owns the inbox,
//!   and `publish` is called by the writer to atomically swap pending items in.
//! Blocking behavior: non-blocking; `trySend`/`tryRecv` return `error.WouldBlock`; `publish` uses overwrite semantics.
const std = @import("std");
const memory = @import("static_memory");
const ring = @import("ring_buffer.zig");
const contracts = @import("../contracts.zig");

pub fn InboxOutbox(comptime T: type) type {
    // Guard against zero-size types: both internal ring buffers require
    // addressable storage; ZSTs would make capacity calculations meaningless.
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
        std.debug.assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();
        const Ring = ring.RingBuffer(T);

        pub const Element = T;
        pub const Error = ring.Error;
        pub const concurrency: contracts.Concurrency = .single_threaded;
        pub const is_lock_free = true;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const TrySendError = error{WouldBlock};
        pub const TryRecvError = error{WouldBlock};
        pub const Config = struct {
            inbox_capacity: usize = 256,
            outbox_capacity: usize = 256,
            budget: ?*memory.budget.Budget = null,
        };

        inbox: Ring,
        outbox: Ring,
        publish_epoch: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            var inbox = try Ring.init(allocator, .{
                .capacity = cfg.inbox_capacity,
                .budget = cfg.budget,
            });
            errdefer inbox.deinit();

            const outbox = try Ring.init(allocator, .{
                .capacity = cfg.outbox_capacity,
                .budget = cfg.budget,
            });

            const self: Self = .{
                .inbox = inbox,
                .outbox = outbox,
            };
            // Postcondition: both buffers are valid and the epoch starts at zero.
            std.debug.assert(self.inbox.capacity() > 0);
            std.debug.assert(self.outbox.capacity() > 0);
            std.debug.assert(self.publish_epoch == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: both ring buffers must still be valid.
            std.debug.assert(self.inbox.capacity() > 0);
            std.debug.assert(self.outbox.capacity() > 0);
            self.inbox.deinit();
            self.outbox.deinit();
            self.* = undefined;
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            // Precondition: outbox must have capacity.
            std.debug.assert(self.outbox.capacity() > 0);
            try self.outbox.tryPush(value);
            // Postcondition: outbox is non-empty after a successful send.
            std.debug.assert(self.outbox.len() > 0);
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            // Precondition: inbox must have capacity.
            std.debug.assert(self.inbox.capacity() > 0);
            const old_len = self.inbox.len();
            const value = try self.inbox.tryPop();
            // Postcondition: inbox shrank by one.
            std.debug.assert(self.inbox.len() == old_len - 1);
            return value;
        }

        /// Moves all currently queued outbox items into the inbox and returns the
        /// number of moved items.
        ///
        /// If the inbox is full, this method applies explicit overwrite semantics
        /// (`pushOverwrite`) so publish can make deterministic forward progress.
        pub fn publish(self: *Self) usize {
            // Bound the drain to outbox capacity: at most this many items can be
            // queued, so the loop is guaranteed to terminate without draining more
            // items than exist. tryPop returns error.WouldBlock when empty.
            const max_drain: usize = self.outbox.capacity();
            std.debug.assert(max_drain > 0);
            var published: usize = 0;
            while (published < max_drain) {
                const value = self.outbox.tryPop() catch break;
                _ = self.inbox.pushOverwrite(value);
                published += 1;
            }
            std.debug.assert(published <= max_drain);
            if (published != 0) {
                std.debug.assert(self.publish_epoch < std.math.maxInt(u64));
                self.publish_epoch += 1;
            }
            return published;
        }

        pub fn inboxLen(self: Self) usize {
            // Invariant: len cannot exceed capacity.
            std.debug.assert(self.inbox.len() <= self.inbox.capacity());
            return self.inbox.len();
        }

        pub fn outboxLen(self: Self) usize {
            // Invariant: len cannot exceed capacity.
            std.debug.assert(self.outbox.len() <= self.outbox.capacity());
            return self.outbox.len();
        }

        pub fn epoch(self: Self) u64 {
            // Invariant: epoch only grows; it cannot wrap past maxInt(u64) in practice
            // because publish guards against it.
            std.debug.assert(self.publish_epoch < std.math.maxInt(u64));
            return self.publish_epoch;
        }
    };
}

test "inbox_outbox enforces publish barrier visibility" {
    var io = try InboxOutbox(u8).init(std.testing.allocator, .{
        .inbox_capacity = 4,
        .outbox_capacity = 4,
    });
    defer io.deinit();

    try io.trySend(1);
    try io.trySend(2);
    try std.testing.expectError(error.WouldBlock, io.tryRecv());

    const moved = io.publish();
    try std.testing.expectEqual(@as(usize, 2), moved);
    try std.testing.expectEqual(@as(u8, 1), try io.tryRecv());
    try std.testing.expectEqual(@as(u8, 2), try io.tryRecv());
}

test "inbox_outbox publish uses overwrite semantics when inbox is full" {
    var io = try InboxOutbox(u8).init(std.testing.allocator, .{
        .inbox_capacity = 1,
        .outbox_capacity = 2,
    });
    defer io.deinit();

    try io.trySend(7);
    try io.trySend(9);
    _ = io.publish();

    // Inbox size is 1, so only the newest published value remains.
    try std.testing.expectEqual(@as(u8, 9), try io.tryRecv());
    try std.testing.expectError(error.WouldBlock, io.tryRecv());
}
