//! ChaseLevDeque: lock-free bounded work-stealing deque.
//!
//! Capacity: fixed at init time; must be a power of two >= 2.
//! Thread safety: one owner thread uses pushBottom/popBottom; thief threads use stealTop.
//! Blocking behavior: non-blocking; operations return `error.WouldBlock` on full/empty/contention.
const std = @import("std");
const ring = @import("../ring_buffer.zig");
const memory = @import("static_memory");
const sync = @import("static_sync");
const qi = @import("../queue_internal.zig");
const contracts = @import("../../contracts.zig");

pub const Error = ring.Error;

pub fn ChaseLevDeque(comptime T: type) type {
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
        std.debug.assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();
        const AtomicSeq = std.atomic.Value(u64);

        pub const Element = T;
        pub const concurrency: contracts.Concurrency = .work_stealing;
        pub const is_lock_free = true;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .approximate;
        pub const PushError = error{WouldBlock};
        pub const PopError = error{WouldBlock};
        pub const StealError = error{WouldBlock};
        pub const Config = struct {
            capacity: usize,
            cas_retries_max: u32 = 1024,
            backoff_exponent_max: u8 = 0,
            budget: ?*memory.budget.Budget = null,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        buffer: []T,
        buffer_mask: u64,
        cas_retries_max: u32,
        backoff_exponent_max: u8,

        top: AtomicSeq align(std.atomic.cache_line) = AtomicSeq.init(0),
        bottom: AtomicSeq align(std.atomic.cache_line) = AtomicSeq.init(0),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            if (cfg.capacity < 2 or !std.math.isPowerOfTwo(cfg.capacity)) {
                return error.InvalidConfig;
            }
            if (!qi.capacityFitsSignedSequenceDistance(cfg.capacity)) {
                return error.InvalidConfig;
            }
            if (cfg.cas_retries_max == 0) {
                return error.InvalidConfig;
            }
            if (cfg.backoff_exponent_max > 16) {
                return error.InvalidConfig;
            }

            const bytes = qi.bytesForItems(cfg.capacity, @sizeOf(T));
            try qi.tryReserveBudget(cfg.budget, bytes);
            errdefer if (cfg.budget) |budget| budget.release(bytes);

            const buffer = allocator.alloc(T, cfg.capacity) catch return error.OutOfMemory;
            errdefer allocator.free(buffer);

            const self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
                .buffer = buffer,
                .buffer_mask = @intCast(cfg.capacity - 1),
                .cas_retries_max = cfg.cas_retries_max,
                .backoff_exponent_max = cfg.backoff_exponent_max,
            };
            std.debug.assert(self.buffer.len == cfg.capacity);
            return self;
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.buffer.len > 0);
            if (self.budget) |budget| {
                budget.release(qi.bytesForItems(self.buffer.len, @sizeOf(T)));
            }
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            std.debug.assert(self.buffer.len > 0);
            return self.buffer.len;
        }

        pub fn len(self: *const Self) usize {
            const top_seq = self.top.load(.acquire);
            const bottom_seq = self.bottom.load(.acquire);
            const distance_signed = qi.seqDistanceSigned(bottom_seq, top_seq);
            if (distance_signed <= 0) return 0;
            const distance: u64 = @intCast(distance_signed);
            const capacity_u64: u64 = @intCast(self.buffer.len);
            if (distance > capacity_u64) return self.buffer.len;
            return @intCast(distance);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn pushBottom(self: *Self, value: T) PushError!void {
            const bottom_seq = self.bottom.load(.monotonic);
            const top_seq = self.top.load(.acquire);
            const distance_signed = qi.seqDistanceSigned(bottom_seq, top_seq);
            if (distance_signed < 0) return error.WouldBlock;
            const distance: u64 = @intCast(distance_signed);
            if (distance >= self.buffer.len) return error.WouldBlock;

            const index = @as(usize, @intCast(bottom_seq & self.buffer_mask));
            self.buffer[index] = value;
            self.bottom.store(bottom_seq +% 1, .release);
        }

        pub fn popBottom(self: *Self) PopError!T {
            const bottom_seq = self.bottom.load(.monotonic);
            const top_seq = self.top.load(.acquire);
            if (qi.seqDistanceSigned(bottom_seq, top_seq) <= 0) return error.WouldBlock;

            const new_bottom = bottom_seq -% 1;
            self.bottom.store(new_bottom, .seq_cst);
            const observed_top = self.top.load(.seq_cst);
            if (qi.seqDistanceSigned(observed_top, new_bottom) > 0) {
                self.bottom.store(observed_top, .release);
                return error.WouldBlock;
            }

            const index = @as(usize, @intCast(new_bottom & self.buffer_mask));
            const value = self.buffer[index];

            if (observed_top == new_bottom) {
                const next_top = observed_top +% 1;
                if (self.top.cmpxchgStrong(observed_top, next_top, .seq_cst, .seq_cst) != null) {
                    self.bottom.store(next_top, .release);
                    return error.WouldBlock;
                }
                self.bottom.store(next_top, .release);
            }

            return value;
        }

        pub fn stealTop(self: *Self) StealError!T {
            var backoff = sync.backoff.Backoff{ .exponent = 0, .max_exponent = self.backoff_exponent_max };
            var retries: u32 = 0;
            while (retries < self.cas_retries_max) : (retries += 1) {
                const top_seq = self.top.load(.seq_cst);
                const bottom_seq = self.bottom.load(.seq_cst);
                if (qi.seqDistanceSigned(bottom_seq, top_seq) <= 0) return error.WouldBlock;

                const index = @as(usize, @intCast(top_seq & self.buffer_mask));
                const value = self.buffer[index];
                const next_top = top_seq +% 1;
                if (self.top.cmpxchgWeak(top_seq, next_top, .seq_cst, .seq_cst) == null) {
                    return value;
                }
                backoff.step();
            }
            return error.WouldBlock;
        }
    };
}

test "chase-lev deque owner and thief semantics" {
    var dq = try ChaseLevDeque(u8).init(std.testing.allocator, .{ .capacity = 4 });
    defer dq.deinit();

    try dq.pushBottom(1);
    try dq.pushBottom(2);
    try std.testing.expectEqual(@as(u8, 1), try dq.stealTop());
    try std.testing.expectEqual(@as(u8, 2), try dq.popBottom());
    try std.testing.expectError(error.WouldBlock, dq.popBottom());
}

test "chase-lev deque applies bounded full behavior" {
    var dq = try ChaseLevDeque(u8).init(std.testing.allocator, .{ .capacity = 2 });
    defer dq.deinit();

    try dq.pushBottom(7);
    try dq.pushBottom(8);
    try std.testing.expectError(error.WouldBlock, dq.pushBottom(9));
}
