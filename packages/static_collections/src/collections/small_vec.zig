//! Small-buffer-optimized vector: stores up to N items inline, spills to heap beyond that.
//!
//! Key type: `SmallVec(T, N)`. For small N the common case requires no allocation.
//! When the inline buffer is exceeded the data is moved to a heap-backed `Vec(T)`.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const vec_mod = @import("vec.zig");
const memory = @import("static_memory");
const assert = std.debug.assert;

pub fn SmallVec(comptime T: type, comptime InlineN: usize) type {
    // Comptime ZST guard: zero-size types have no storage to inline and trip
    // alignment assumptions in the inline array. Use a regular Vec for ZSTs.
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const inline_capacity: usize = InlineN;

        pub const Error = vec_mod.Error;
        pub const Config = struct {
            budget: ?*memory.budget.Budget = null,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        inline_items: [InlineN]T = undefined,
        inline_len: usize = 0,
        spill: ?vec_mod.Vec(T) = null,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Self {
            var self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
            };
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            if (self.spill) |*spill| spill.deinit();
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            self.assertInvariants();
            if (self.spill) |spill| return spill.len();
            return self.inline_len;
        }

        pub fn items(self: *Self) []T {
            self.assertInvariants();
            if (self.spill) |*spill| return spill.items();
            return self.inline_items[0..self.inline_len];
        }

        pub fn append(self: *Self, value: T) Error!void {
            self.assertInvariants();
            if (self.spill) |*spill| {
                try spill.append(value);
                self.assertInvariants();
                return;
            }
            if (self.inline_len < InlineN) {
                self.inline_items[self.inline_len] = value;
                self.inline_len += 1;
                assert(self.inline_len <= InlineN);
                self.assertInvariants();
                return;
            }

            const needed_capacity = std.math.add(usize, self.inline_len, 1) catch return error.Overflow;
            // Narrowing: needed_capacity is bounded by InlineN + 1 (a comptime constant) at this
            // code path (reached only when inline_len >= InlineN), so the u32 cast is safe.
            assert(needed_capacity <= std.math.maxInt(u32));
            const spill_initial_capacity: u32 = if (self.budget != null)
                @intCast(needed_capacity)
            else if (InlineN == 0)
                @intCast(needed_capacity)
            else
                @intCast(InlineN * 2);
            var spill = try vec_mod.Vec(T).init(self.allocator, .{
                .initial_capacity = spill_initial_capacity,
                .budget = self.budget,
            });
            errdefer spill.deinit();
            for (self.inline_items[0..self.inline_len]) |item| {
                try spill.append(item);
            }
            try spill.append(value);
            self.spill = spill;
            assert(self.spill != null);
            self.assertInvariants();
        }

        fn assertInvariants(self: *const Self) void {
            // Invariant: inline_len never exceeds the compile-time inline capacity.
            assert(self.inline_len <= InlineN);
            if (self.spill) |spill| {
                // Invariant: discriminant matches storage — if spill exists it holds at
                // least as many elements as were migrated from inline storage.
                assert(spill.len() >= self.inline_len);
                // Invariant: once spilled, inline_len is frozen at its migration value
                // which is at most InlineN; spill owns the authoritative length.
                assert(self.inline_len <= InlineN);
            }
        }
    };
}

test "small vec spills after inline capacity" {
    // Goal: verify growth transitions from inline storage to spill vector.
    // Method: append past inline capacity and validate resulting length.
    var s = SmallVec(u8, 2).init(std.testing.allocator, .{});
    defer s.deinit();
    try s.append(1);
    try s.append(2);
    try s.append(3);
    try std.testing.expectEqual(@as(usize, 3), s.len());
}

test "small vec preserves order across spill transition" {
    // Goal: preserve insertion order while migrating inline data to spill.
    // Method: append inline then spilled values and verify contiguous sequence.
    var s = SmallVec(u8, 2).init(std.testing.allocator, .{});
    defer s.deinit();
    try s.append(5);
    try s.append(6);
    try s.append(7);

    const values = s.items();
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqual(@as(u8, 5), values[0]);
    try std.testing.expectEqual(@as(u8, 6), values[1]);
    try std.testing.expectEqual(@as(u8, 7), values[2]);
}

test "small vec inline capacity zero spills immediately" {
    // Goal: handle InlineN=0 without special-case call-site behavior.
    // Method: append one value and assert storage length and content.
    var s = SmallVec(u8, 0).init(std.testing.allocator, .{});
    defer s.deinit();
    try s.append(9);
    try std.testing.expectEqual(@as(usize, 1), s.len());
    try std.testing.expectEqual(@as(u8, 9), s.items()[0]);
}
