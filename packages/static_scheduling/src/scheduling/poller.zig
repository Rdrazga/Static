//! Poller interface and deterministic fake implementation.
//!
//! The fake poller is intentionally single-shot and non-blocking.
//! A `null` timeout means "poll once without a timeout budget", not "block
//! forever". If no events are pending, the fake returns `error.Timeout`.

const std = @import("std");
const sync = @import("static_sync");

pub const Interest = packed struct(u8) {
    readable: bool = false,
    writable: bool = false,
    hangup: bool = false,
    @"error": bool = false,
    reserved: u4 = 0,
};

pub const PollError = error{
    InvalidInput,
    InvalidConfig,
    OutOfMemory,
    NoSpaceLeft,
    Timeout,
    Cancelled,
    Unsupported,
};

pub fn Poller(comptime NativeHandle: type) type {
    return struct {
        pub const Handle = NativeHandle;
        pub const Token = u64;

        pub const Event = struct {
            token: Token,
            interest: Interest,
        };

        pub const VTable = struct {
            deinit: *const fn (ctx: *anyopaque) void,
            register: *const fn (ctx: *anyopaque, handle: Handle, token: Token, interest: Interest) PollError!void,
            unregister: *const fn (ctx: *anyopaque, handle: Handle) PollError!void,
            poll: *const fn (ctx: *anyopaque, events_out: []Event, timeout_ns: ?u64, cancel: ?sync.cancel.CancelToken) PollError!u32,
        };

        ctx: *anyopaque,
        vtable: *const VTable,

        pub fn deinit(self: *@This()) void {
            self.vtable.deinit(self.ctx);
        }

        pub fn register(self: *@This(), handle: Handle, token: Token, interest: Interest) PollError!void {
            try self.vtable.register(self.ctx, handle, token, interest);
        }

        pub fn unregister(self: *@This(), handle: Handle) PollError!void {
            try self.vtable.unregister(self.ctx, handle);
        }

        pub fn poll(
            self: *@This(),
            events_out: []Event,
            timeout_ns: ?u64,
            cancel: ?sync.cancel.CancelToken,
        ) PollError!u32 {
            return self.vtable.poll(self.ctx, events_out, timeout_ns, cancel);
        }
    };
}

pub fn FakePoller(comptime NativeHandle: type) type {
    const PollerType = Poller(NativeHandle);
    const Event = PollerType.Event;
    const Token = PollerType.Token;

    return struct {
        const Self = @This();

        pub const Handle = NativeHandle;
        pub const Config = struct {
            registrations_max: u32,
            pending_events_max: u32,
        };

        const Registration = struct {
            handle: Handle,
            token: Token,
            interest: Interest,
        };

        const PendingEvent = struct {
            handle: Handle,
            interest: Interest,
        };

        allocator: std.mem.Allocator,
        registrations: []Registration,
        registrations_len: u32 = 0,
        pending: []PendingEvent,
        pending_len: u32 = 0,

        const vtable: PollerType.VTable = .{
            .deinit = deinitVTable,
            .register = registerVTable,
            .unregister = unregisterVTable,
            .poll = pollVTable,
        };

        pub fn init(allocator: std.mem.Allocator, cfg: Config) PollError!Self {
            if (cfg.registrations_max == 0) return error.InvalidConfig;
            if (cfg.pending_events_max == 0) return error.InvalidConfig;

            const registrations = allocator.alloc(Registration, cfg.registrations_max) catch return error.OutOfMemory;
            errdefer allocator.free(registrations);

            const pending = allocator.alloc(PendingEvent, cfg.pending_events_max) catch return error.OutOfMemory;
            errdefer allocator.free(pending);

            return .{
                .allocator = allocator,
                .registrations = registrations,
                .pending = pending,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.pending);
            self.allocator.free(self.registrations);
            self.* = undefined;
        }

        pub fn asPoller(self: *Self) PollerType {
            return .{
                .ctx = self,
                .vtable = &vtable,
            };
        }

        pub fn register(self: *Self, handle: Handle, token: Token, interest: Interest) PollError!void {
            if (self.findRegistration(handle)) |index| {
                self.registrations[index].token = token;
                self.registrations[index].interest = interest;
                return;
            }

            if (self.registrations_len == self.registrations.len) return error.NoSpaceLeft;
            self.registrations[self.registrations_len] = .{
                .handle = handle,
                .token = token,
                .interest = interest,
            };
            self.registrations_len += 1;
        }

        pub fn unregister(self: *Self, handle: Handle) PollError!void {
            const index = self.findRegistration(handle) orelse return error.InvalidInput;
            self.removeRegistration(index);
        }

        pub fn inject(self: *Self, handle: Handle, interest: Interest) PollError!void {
            const registration_index = self.findRegistration(handle) orelse return error.InvalidInput;
            if (self.pending_len == self.pending.len) return error.NoSpaceLeft;

            const reg = self.registrations[registration_index];
            self.pending[self.pending_len] = .{
                .handle = handle,
                .interest = mergeInterest(.{}, intersectInterest(interest, reg.interest)),
            };
            self.pending_len += 1;
        }

        pub fn poll(
            self: *Self,
            events_out: []Event,
            timeout_ns: ?u64,
            cancel: ?sync.cancel.CancelToken,
        ) PollError!u32 {
            if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;
            if (events_out.len == 0 and self.pending_len > 0) return error.NoSpaceLeft;

            if (self.pending_len == 0) {
                if (timeout_ns) |timeout| {
                    if (timeout == 0) return error.Timeout;
                    return error.Timeout;
                }
                // The fake poller never blocks indefinitely. A null timeout
                // means "poll current pending events only" so empty state still
                // reports Timeout in a deterministic, non-blocking way.
                return error.Timeout;
            }

            const unique_count = self.countUniqueTokens();
            if (unique_count > events_out.len) return error.NoSpaceLeft;

            var out_len: u32 = 0;
            var index: u32 = 0;
            while (index < self.pending_len) : (index += 1) {
                const pending = self.pending[index];
                const reg_index = self.findRegistration(pending.handle) orelse continue;
                const token = self.registrations[reg_index].token;

                if (findEventToken(events_out[0..out_len], token)) |existing| {
                    events_out[existing].interest = mergeInterest(events_out[existing].interest, pending.interest);
                } else {
                    events_out[out_len] = .{
                        .token = token,
                        .interest = pending.interest,
                    };
                    out_len += 1;
                }
            }

            self.pending_len = 0;
            return out_len;
        }

        fn findRegistration(self: *Self, handle: Handle) ?u32 {
            var index: u32 = 0;
            while (index < self.registrations_len) : (index += 1) {
                if (self.registrations[index].handle == handle) return index;
            }
            return null;
        }

        fn removeRegistration(self: *Self, index: u32) void {
            std.debug.assert(index < self.registrations_len);
            const last_index = self.registrations_len - 1;
            if (index != last_index) {
                self.registrations[index] = self.registrations[last_index];
            }
            self.registrations_len -= 1;
        }

        fn countUniqueTokens(self: *Self) usize {
            var unique_len: usize = 0;
            var index: u32 = 0;
            while (index < self.pending_len) : (index += 1) {
                const pending = self.pending[index];
                const reg_index = self.findRegistration(pending.handle) orelse continue;
                const token = self.registrations[reg_index].token;
                if (self.tokenAlreadyCounted(index, token)) continue;
                unique_len += 1;
            }
            return unique_len;
        }

        fn tokenAlreadyCounted(self: *Self, pending_end_exclusive: u32, token: Token) bool {
            var prior_index: u32 = 0;
            while (prior_index < pending_end_exclusive) : (prior_index += 1) {
                const prior_pending = self.pending[prior_index];
                const reg_index = self.findRegistration(prior_pending.handle) orelse continue;
                if (self.registrations[reg_index].token == token) return true;
            }
            return false;
        }

        fn deinitVTable(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit();
        }

        fn registerVTable(ctx: *anyopaque, handle: Handle, token: Token, interest: Interest) PollError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.register(handle, token, interest);
        }

        fn unregisterVTable(ctx: *anyopaque, handle: Handle) PollError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.unregister(handle);
        }

        fn pollVTable(ctx: *anyopaque, events_out: []Event, timeout_ns: ?u64, cancel: ?sync.cancel.CancelToken) PollError!u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.poll(events_out, timeout_ns, cancel);
        }

        fn findEventToken(events: []const Event, token: Token) ?u32 {
            var index: usize = 0;
            while (index < events.len) : (index += 1) {
                if (events[index].token == token) return @intCast(index);
            }
            return null;
        }
    };
}

fn mergeInterest(a: Interest, b: Interest) Interest {
    return .{
        .readable = a.readable or b.readable,
        .writable = a.writable or b.writable,
        .hangup = a.hangup or b.hangup,
        .@"error" = a.@"error" or b.@"error",
        .reserved = 0,
    };
}

fn intersectInterest(a: Interest, b: Interest) Interest {
    return .{
        .readable = a.readable and b.readable,
        .writable = a.writable and b.writable,
        .hangup = a.hangup and b.hangup,
        .@"error" = a.@"error" and b.@"error",
        .reserved = 0,
    };
}

test "poller fake register inject and coalesced poll" {
    var fake = try FakePoller(i32).init(std.testing.allocator, .{
        .registrations_max = 8,
        .pending_events_max = 8,
    });
    defer fake.deinit();

    try fake.register(7, 100, .{ .readable = true, .writable = true });
    try fake.inject(7, .{ .readable = true });
    try fake.inject(7, .{ .writable = true });

    var iface = fake.asPoller();
    var out: [2]Poller(i32).Event = undefined;
    const count = try iface.poll(&out, 0, null);
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u64, 100), out[0].token);
    try std.testing.expect(out[0].interest.readable);
    try std.testing.expect(out[0].interest.writable);
}

test "poller fake timeout and cancellation semantics" {
    var fake = try FakePoller(i32).init(std.testing.allocator, .{
        .registrations_max = 2,
        .pending_events_max = 2,
    });
    defer fake.deinit();

    var iface = fake.asPoller();
    var out: [1]Poller(i32).Event = undefined;
    try std.testing.expectError(error.Timeout, iface.poll(&out, 0, null));
    try std.testing.expectError(error.Timeout, iface.poll(&out, null, null));

    var source = sync.cancel.CancelSource{};
    source.cancel();
    try std.testing.expectError(error.Cancelled, iface.poll(&out, null, source.token()));
}

test "poller fake ready events beat timeout budgets" {
    var fake = try FakePoller(i32).init(std.testing.allocator, .{
        .registrations_max = 2,
        .pending_events_max = 2,
    });
    defer fake.deinit();

    try fake.register(11, 5, .{ .readable = true });
    try fake.inject(11, .{ .readable = true });

    var iface = fake.asPoller();
    var out: [1]Poller(i32).Event = undefined;

    const zero_count = try iface.poll(&out, 0, null);
    try std.testing.expectEqual(@as(u32, 1), zero_count);
    try std.testing.expectEqual(@as(u64, 5), out[0].token);
    try std.testing.expect(out[0].interest.readable);

    try fake.inject(11, .{ .readable = true });

    const finite_count = try iface.poll(&out, 10 * std.time.ns_per_ms, null);
    try std.testing.expectEqual(@as(u32, 1), finite_count);
    try std.testing.expectEqual(@as(u64, 5), out[0].token);
    try std.testing.expect(out[0].interest.readable);

    try std.testing.expectError(error.Timeout, iface.poll(&out, 10 * std.time.ns_per_ms, null));
}

test "poller fake unregister removes registrations" {
    var fake = try FakePoller(i32).init(std.testing.allocator, .{
        .registrations_max = 2,
        .pending_events_max = 2,
    });
    defer fake.deinit();

    try fake.register(11, 5, .{ .readable = true });
    try fake.unregister(11);
    try std.testing.expectError(error.InvalidInput, fake.inject(11, .{ .readable = true }));
}

test "poller fake unregister drops queued pending events for removed registrations" {
    var fake = try FakePoller(i32).init(std.testing.allocator, .{
        .registrations_max = 2,
        .pending_events_max = 2,
    });
    defer fake.deinit();

    try fake.register(11, 5, .{ .readable = true });
    try fake.inject(11, .{ .readable = true });
    try fake.unregister(11);

    var iface = fake.asPoller();
    var out: [1]Poller(i32).Event = undefined;
    try std.testing.expectEqual(@as(u32, 0), try iface.poll(&out, 0, null));
    try std.testing.expectError(error.Timeout, iface.poll(&out, 0, null));
}

test "poller fake counts more than 128 unique tokens without hidden cap" {
    var fake = try FakePoller(i32).init(std.testing.allocator, .{
        .registrations_max = 130,
        .pending_events_max = 130,
    });
    defer fake.deinit();

    var index: u32 = 0;
    while (index < 130) : (index += 1) {
        const handle: i32 = @intCast(index + 1);
        const token: u64 = index + 1000;
        try fake.register(handle, token, .{ .readable = true });
        try fake.inject(handle, .{ .readable = true });
    }

    var iface = fake.asPoller();
    var out: [130]Poller(i32).Event = undefined;
    const count = try iface.poll(&out, 0, null);
    try std.testing.expectEqual(@as(u32, 130), count);
    try std.testing.expectEqual(@as(u64, 1000), out[0].token);
    try std.testing.expectEqual(@as(u64, 1129), out[129].token);
}
