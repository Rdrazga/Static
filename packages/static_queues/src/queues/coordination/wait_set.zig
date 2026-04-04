//! WaitSet: bounded multi-source receive selection over channel-like sources.
//!
//! Capacity: fixed at comptime via `source_count_max`.
//! Thread safety: registration/unregistration is single-threaded; receive selection may be
//! called from one thread at a time.
//! Blocking behavior:
//! - `tryRecvAny` is non-blocking.
//! - `recvAny` is bounded polling with cancellation.
//! - `recvAnyTimeout` is timeout-bounded polling with cancellation.
const std = @import("std");
const sync = @import("static_sync");
const qi = @import("../queue_internal.zig");

pub fn WaitSet(comptime T: type, comptime source_count_max: usize) type {
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
        std.debug.assert(@alignOf(T) > 0);
        std.debug.assert(source_count_max > 0);
    }

    return struct {
        const Self = @This();
        const TryRecvFn = *const fn (ctx: *anyopaque) error{ WouldBlock, Closed }!T;
        const Slot = struct {
            ctx: *anyopaque,
            try_recv_fn: TryRecvFn,
        };

        pub const SelectResult = struct {
            source_index: usize,
            value: T,
        };

        pub const Config = struct {
            poll_attempts_max: u32 = 1024,
        };

        slots: [source_count_max]?Slot = [_]?Slot{null} ** source_count_max,
        active_count: usize = 0,
        scan_start_index: usize = 0,
        poll_attempts_max: u32,

        pub fn init(cfg: Config) Self {
            std.debug.assert(cfg.poll_attempts_max > 0);
            return .{
                .poll_attempts_max = cfg.poll_attempts_max,
            };
        }

        pub fn registerRaw(self: *Self, ctx: *anyopaque, try_recv_fn: TryRecvFn) error{NoSpaceLeft}!usize {
            std.debug.assert(self.active_count <= source_count_max);
            var slot_index: usize = 0;
            while (slot_index < source_count_max) : (slot_index += 1) {
                if (self.slots[slot_index] != null) continue;
                self.slots[slot_index] = .{
                    .ctx = ctx,
                    .try_recv_fn = try_recv_fn,
                };
                self.active_count += 1;
                std.debug.assert(self.active_count > 0);
                return slot_index;
            }
            return error.NoSpaceLeft;
        }

        pub fn registerChannel(self: *Self, channel_ptr: anytype) error{NoSpaceLeft}!usize {
            const ptr_info = @typeInfo(@TypeOf(channel_ptr));
            if (ptr_info != .pointer) {
                @compileError("`registerChannel` requires a pointer argument.");
            }
            const C = ptr_info.pointer.child;
            if (!@hasDecl(C, "Element")) {
                @compileError("`registerChannel` requires channel-like type with `Element`.");
            }
            if (C.Element != T) {
                @compileError("`registerChannel` element type mismatch for `" ++ @typeName(C) ++ "`.");
            }
            if (!@hasDecl(C, "tryRecv")) {
                @compileError("`registerChannel` requires `tryRecv`.");
            }

            const Impl = struct {
                fn tryRecvFn(ctx: *anyopaque) error{ WouldBlock, Closed }!T {
                    const channel: *C = @ptrCast(@alignCast(ctx));
                    return channel.tryRecv() catch |err| switch (err) {
                        error.WouldBlock => return error.WouldBlock,
                        error.Closed => return error.Closed,
                    };
                }
            };
            return self.registerRaw(channel_ptr, Impl.tryRecvFn);
        }

        pub fn unregister(self: *Self, source_index: usize) error{InvalidIndex}!void {
            if (source_index >= source_count_max) return error.InvalidIndex;
            if (self.slots[source_index] == null) return error.InvalidIndex;
            self.slots[source_index] = null;
            std.debug.assert(self.active_count > 0);
            self.active_count -= 1;
            if (self.scan_start_index >= source_count_max) {
                self.scan_start_index = 0;
            }
        }

        pub fn tryRecvAny(self: *Self) error{ WouldBlock, Closed }!SelectResult {
            if (self.active_count == 0) return error.WouldBlock;

            var closed_count: usize = 0;
            var open_count: usize = 0;
            var scanned_active_count: usize = 0;
            var offset: usize = 0;
            while (offset < source_count_max) : (offset += 1) {
                const source_index = (self.scan_start_index + offset) % source_count_max;
                const slot = self.slots[source_index] orelse continue;
                scanned_active_count += 1;
                const value = slot.try_recv_fn(slot.ctx) catch |err| switch (err) {
                    error.WouldBlock => {
                        open_count += 1;
                        continue;
                    },
                    error.Closed => {
                        closed_count += 1;
                        continue;
                    },
                };
                self.scan_start_index = if (source_index + 1 == source_count_max) 0 else source_index + 1;
                return .{
                    .source_index = source_index,
                    .value = value,
                };
            }

            std.debug.assert(scanned_active_count == self.active_count);
            std.debug.assert(closed_count + open_count == self.active_count);
            if (open_count > 0) return error.WouldBlock;
            if (closed_count == self.active_count) return error.Closed;
            return error.WouldBlock;
        }

        pub fn recvAny(self: *Self, cancel: ?sync.cancel.CancelToken) error{ WouldBlock, Closed, Cancelled }!SelectResult {
            var attempts: u32 = 0;
            while (attempts < self.poll_attempts_max) : (attempts += 1) {
                if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
                return self.tryRecvAny() catch |err| switch (err) {
                    error.WouldBlock => {
                        std.Thread.yield() catch {};
                        continue;
                    },
                    error.Closed => return error.Closed,
                };
            }
            return error.WouldBlock;
        }

        pub fn recvAnyTimeout(
            self: *Self,
            cancel: ?sync.cancel.CancelToken,
            timeout_ns: u64,
        ) error{ Closed, Cancelled, Timeout, Unsupported }!SelectResult {
            var timeout_budget = qi.TimeoutBudget.init(timeout_ns) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            };
            while (true) {
                if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
                return self.tryRecvAny() catch |err| switch (err) {
                    error.WouldBlock => {
                        _ = timeout_budget.remainingOrTimeout() catch |budget_err| switch (budget_err) {
                            error.Timeout => return error.Timeout,
                            error.Unsupported => return error.Unsupported,
                        };
                        std.Thread.yield() catch {};
                        continue;
                    },
                    error.Closed => return error.Closed,
                };
            }
        }
    };
}

test "wait set selects the source that has data" {
    const wait_set_type = WaitSet(u8, 2);
    var wait_set = wait_set_type.init(.{});

    var c1 = try @import("../channel.zig").Channel(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer c1.deinit();
    var c2 = try @import("../channel.zig").Channel(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer c2.deinit();

    const idx1 = try wait_set.registerChannel(&c1);
    const idx2 = try wait_set.registerChannel(&c2);
    try std.testing.expect(idx1 != idx2);

    try c2.trySend(9);
    const selected = try wait_set.tryRecvAny();
    try std.testing.expectEqual(idx2, selected.source_index);
    try std.testing.expectEqual(@as(u8, 9), selected.value);
}

test "wait set timeout and cancellation behavior are bounded" {
    const wait_set_type = WaitSet(u8, 1);
    var wait_set = wait_set_type.init(.{ .poll_attempts_max = 8 });

    var c = try @import("../channel.zig").Channel(u8).init(std.testing.allocator, .{ .capacity = 1 });
    defer c.deinit();
    _ = try wait_set.registerChannel(&c);

    try std.testing.expectError(error.Timeout, wait_set.recvAnyTimeout(null, 0));

    var source = sync.cancel.CancelSource{};
    source.cancel();
    try std.testing.expectError(error.Cancelled, wait_set.recvAny(source.token()));
}

test "wait set returns WouldBlock when at least one source remains open" {
    const wait_set_type = WaitSet(u8, 2);
    var wait_set = wait_set_type.init(.{});

    var c1 = try @import("../channel.zig").Channel(u8).init(std.testing.allocator, .{ .capacity = 1 });
    defer c1.deinit();
    var c2 = try @import("../channel.zig").Channel(u8).init(std.testing.allocator, .{ .capacity = 1 });
    defer c2.deinit();

    _ = try wait_set.registerChannel(&c1);
    _ = try wait_set.registerChannel(&c2);

    c1.close();
    try std.testing.expectError(error.WouldBlock, wait_set.tryRecvAny());
}

test "wait set returns Closed when all sources are closed" {
    const wait_set_type = WaitSet(u8, 2);
    var wait_set = wait_set_type.init(.{});

    var c1 = try @import("../channel.zig").Channel(u8).init(std.testing.allocator, .{ .capacity = 1 });
    defer c1.deinit();
    var c2 = try @import("../channel.zig").Channel(u8).init(std.testing.allocator, .{ .capacity = 1 });
    defer c2.deinit();

    _ = try wait_set.registerChannel(&c1);
    _ = try wait_set.registerChannel(&c2);

    c1.close();
    c2.close();
    try std.testing.expectError(error.Closed, wait_set.tryRecvAny());
}
