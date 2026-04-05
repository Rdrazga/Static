//! Typed deterministic mailbox wrapper over `static_queues.ring_buffer`.
//!
//! Payloads move through the mailbox by value. Prefer small ids, handles, or
//! pointer-like wrappers for large objects so simulation plumbing does not hide
//! large copies.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const queues = @import("static_queues");

/// Public mailbox operating errors.
pub const MailboxError = error{
    InvalidConfig,
    OutOfMemory,
    NoSpaceLeft,
    WouldBlock,
    Overflow,
};

/// Config for typed mailboxes.
pub const MailboxConfig = struct {
    capacity: usize,
};

/// Bounded FIFO mailbox for deterministic simulation plumbing.
pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        const Queue = queues.ring_buffer.RingBuffer(T);

        queue: Queue,

        /// Allocate one bounded mailbox with caller-selected capacity.
        pub fn init(
            allocator: std.mem.Allocator,
            config: MailboxConfig,
        ) MailboxError!Self {
            const queue = Queue.init(allocator, .{
                .capacity = config.capacity,
            }) catch |err| return mapInitError(err);
            return .{ .queue = queue };
        }

        /// Release all mailbox storage and invalidate the instance.
        pub fn deinit(self: *Self) void {
            self.queue.deinit();
            self.* = undefined;
        }

        /// Enqueue one value by copy at the mailbox tail.
        pub fn send(self: *Self, value: T) MailboxError!void {
            self.queue.tryPush(value) catch |err| switch (err) {
                error.WouldBlock => return error.NoSpaceLeft,
            };
            assert(self.queue.len() > 0);
        }

        /// Dequeue and return the next mailbox value by copy.
        pub fn recv(self: *Self) MailboxError!T {
            return self.queue.tryPop() catch |err| switch (err) {
                error.WouldBlock => error.WouldBlock,
            };
        }

        /// Read the current mailbox head by copy without removing it.
        pub fn peek(self: *const Self) MailboxError!T {
            const contiguous = self.queue.peekContiguous(1);
            if (contiguous.len == 0) return error.WouldBlock;
            return contiguous[0];
        }

        /// Report the number of queued values.
        pub fn len(self: *const Self) usize {
            return self.queue.len();
        }

        /// Report the remaining bounded send capacity.
        pub fn freeSlots(self: *const Self) usize {
            return self.queue.capacity() - self.queue.len();
        }
    };
}

fn mapInitError(err: queues.ring_buffer.Error) MailboxError {
    return switch (err) {
        error.InvalidConfig => error.InvalidConfig,
        error.OutOfMemory => error.OutOfMemory,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.WouldBlock => error.WouldBlock,
        error.Overflow => error.Overflow,
    };
}

test "mailbox preserves fifo ordering" {
    var mailbox = try Mailbox(u32).init(testing.allocator, .{ .capacity = 3 });
    defer mailbox.deinit();

    try mailbox.send(1);
    try mailbox.send(2);
    try testing.expectEqual(@as(u32, 1), try mailbox.recv());
    try testing.expectEqual(@as(u32, 2), try mailbox.recv());
}

test "mailbox wraparound and full empty behavior" {
    var mailbox = try Mailbox(u8).init(testing.allocator, .{ .capacity = 2 });
    defer mailbox.deinit();

    try mailbox.send(9);
    try mailbox.send(10);
    try testing.expectError(error.NoSpaceLeft, mailbox.send(11));
    try testing.expectEqual(@as(u8, 9), try mailbox.recv());
    try mailbox.send(12);
    try testing.expectEqual(@as(u8, 10), try mailbox.recv());
    try testing.expectEqual(@as(u8, 12), try mailbox.recv());
    try testing.expectError(error.WouldBlock, mailbox.recv());
}

test "mailbox rejects invalid capacity and peek preserves the head item" {
    try testing.expectError(error.InvalidConfig, Mailbox(u8).init(testing.allocator, .{
        .capacity = 0,
    }));

    var mailbox = try Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer mailbox.deinit();

    try testing.expectError(error.WouldBlock, mailbox.peek());
    try mailbox.send(41);
    try mailbox.send(99);
    try testing.expectEqual(@as(u32, 41), try mailbox.peek());
    try testing.expectEqual(@as(usize, 2), mailbox.len());
    try testing.expectEqual(@as(u32, 41), try mailbox.recv());
}

test "mailbox reports remaining bounded send capacity" {
    var mailbox = try Mailbox(u32).init(testing.allocator, .{ .capacity = 3 });
    defer mailbox.deinit();

    try testing.expectEqual(@as(usize, 3), mailbox.freeSlots());
    try mailbox.send(1);
    try testing.expectEqual(@as(usize, 2), mailbox.freeSlots());
    _ = try mailbox.recv();
    try testing.expectEqual(@as(usize, 3), mailbox.freeSlots());
}
