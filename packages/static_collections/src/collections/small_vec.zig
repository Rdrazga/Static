//! Small-buffer-optimized vector: stores up to N items inline, spills to heap beyond that.
//!
//! Key type: `SmallVec(T, N)`. For small N the common case requires no allocation.
//! When the inline buffer is exceeded the data is moved to a heap-backed `Vec(T)`.
//!
//! Spill is permanent: once heap-allocated, the SmallVec remains heap-backed
//! regardless of subsequent element count. `shrinkToFit()` may still reduce the
//! spilled Vec's reserved capacity, but it never migrates elements back into the
//! inline buffer. Use `ensureCapacity` during setup to pre-allocate if the
//! expected size is known to exceed inline capacity.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const testing = std.testing;
const vec_mod = @import("vec.zig");
const memory = @import("static_memory");
const assert = std.debug.assert;

pub fn SmallVec(comptime T: type, comptime InlineN: usize) type {
    // Comptime ZST guard: zero-size types have no storage to inline and trip
    // alignment assumptions in the inline array. Use a regular Vec for ZSTs.
    comptime {
        assert(@sizeOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const inline_capacity: usize = InlineN;

        pub const Error = vec_mod.Error;
        pub const Config = struct {
            budget: ?*memory.budget.Budget,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        inline_items: [InlineN]T = undefined,
        inline_len: usize = 0,
        spill: ?vec_mod.Vec(T) = null,

        pub fn init(allocator: std.mem.Allocator, config: Config) Self {
            var self: Self = .{
                .allocator = allocator,
                .budget = config.budget,
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

        pub fn pop(self: *Self) ?T {
            self.assertInvariants();
            if (self.spill) |*spill| {
                const out = spill.pop();
                self.assertInvariants();
                return out;
            }
            if (self.inline_len == 0) return null;
            self.inline_len -= 1;
            const out = self.inline_items[self.inline_len];
            assert(self.inline_len <= InlineN);
            self.assertInvariants();
            return out;
        }

        /// Shrinks the spilled Vec's capacity to match its length. No-op if inline.
        pub fn shrinkToFit(self: *Self) void {
            self.assertInvariants();
            if (self.spill) |*spill| spill.shrinkToFit();
            self.assertInvariants();
        }

        /// Creates an independent copy. If spilled, the inner Vec is cloned.
        pub fn clone(self: *const Self) Error!Self {
            self.assertInvariants();
            var result: Self = .{
                .allocator = self.allocator,
                .budget = self.budget,
            };
            if (self.spill) |spill| {
                result.spill = try spill.clone();
                result.inline_len = 0;
            } else {
                result.inline_len = self.inline_len;
                @memcpy(result.inline_items[0..self.inline_len], self.inline_items[0..self.inline_len]);
            }
            result.assertInvariants();
            return result;
        }

        /// Pre-allocates spill capacity so that subsequent appends up to `n`
        /// total elements do not allocate. If `n <= InlineN`, this is a no-op.
        pub fn ensureCapacity(self: *Self, n: usize) Error!void {
            self.assertInvariants();
            if (n <= InlineN) return;
            if (n > std.math.maxInt(u32)) return error.Overflow;
            if (self.spill) |*spill| {
                try spill.ensureCapacity(n);
                self.assertInvariants();
                return;
            }
            // Trigger spill with sufficient capacity.
            var spill = try vec_mod.Vec(T).init(self.allocator, .{
                .initial_capacity = @intCast(n),
                .budget = self.budget,
            });
            errdefer spill.deinit();
            spill.appendSliceAssumeCapacity(self.inline_items[0..self.inline_len]);
            self.spill = spill;
            self.inline_len = 0;
            self.assertInvariants();
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
            if (needed_capacity > std.math.maxInt(u32)) return error.Overflow;
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
            // Bulk-copy inline items through Vec's public API, then append
            // the new value that triggered the spill.
            assert(spill.capacity() >= self.inline_len + 1);
            spill.appendSliceAssumeCapacity(self.inline_items[0..self.inline_len]);
            try spill.append(value);
            self.spill = spill;
            self.inline_len = 0;
            assert(self.spill != null);
            self.assertInvariants();
        }

        fn assertInvariants(self: *const Self) void {
            // Invariant: inline_len never exceeds the compile-time inline capacity.
            assert(self.inline_len <= InlineN);
            if (self.spill) |spill| {
                // Once spilled, the heap-backed Vec becomes the only authoritative
                // storage and the inline prefix is retired.
                assert(self.inline_len == 0);
                assert(spill.len() > 0 or spill.capacity() > 0);
            }
        }
    };
}

test "small vec spills after inline capacity" {
    // Goal: verify growth transitions from inline storage to spill vector.
    // Method: append past inline capacity and validate resulting length.
    var s = SmallVec(u8, 2).init(testing.allocator, .{ .budget = null });
    defer s.deinit();
    try s.append(1);
    try s.append(2);
    try s.append(3);
    try testing.expectEqual(@as(usize, 3), s.len());
}

test "small vec preserves order across spill transition" {
    // Goal: preserve insertion order while migrating inline data to spill.
    // Method: append inline then spilled values and verify contiguous sequence.
    var s = SmallVec(u8, 2).init(testing.allocator, .{ .budget = null });
    defer s.deinit();
    try s.append(5);
    try s.append(6);
    try s.append(7);

    const values = s.items();
    try testing.expectEqual(@as(usize, 3), values.len);
    try testing.expectEqual(@as(u8, 5), values[0]);
    try testing.expectEqual(@as(u8, 6), values[1]);
    try testing.expectEqual(@as(u8, 7), values[2]);
}

test "small vec inline capacity zero spills immediately" {
    // Goal: handle InlineN=0 without special-case call-site behavior.
    // Method: append one value and assert storage length and content.
    var s = SmallVec(u8, 0).init(testing.allocator, .{ .budget = null });
    defer s.deinit();
    try s.append(9);
    try testing.expectEqual(@as(usize, 1), s.len());
    try testing.expectEqual(@as(u8, 9), s.items()[0]);
}

test "small vec pop returns last element from inline and spill" {
    // Goal: validate LIFO pop semantics across inline and spill storage.
    // Method: pop inline items, then pop after spill transition.
    var s = SmallVec(u8, 2).init(testing.allocator, .{ .budget = null });
    defer s.deinit();

    try testing.expect(s.pop() == null);
    try s.append(1);
    try s.append(2);
    try testing.expectEqual(@as(u8, 2), s.pop().?);
    try testing.expectEqual(@as(u8, 1), s.pop().?);
    try testing.expect(s.pop() == null);

    // After spill
    try s.append(10);
    try s.append(20);
    try s.append(30);
    try testing.expectEqual(@as(u8, 30), s.pop().?);
    try testing.expectEqual(@as(usize, 2), s.len());
}

test "small vec spilled storage can drain back to empty" {
    var s = SmallVec(u8, 2).init(testing.allocator, .{ .budget = null });
    defer s.deinit();

    try s.append(1);
    try s.append(2);
    try s.append(3);

    try testing.expectEqual(@as(u8, 3), s.pop().?);
    try testing.expectEqual(@as(u8, 2), s.pop().?);
    try testing.expectEqual(@as(u8, 1), s.pop().?);
    try testing.expect(s.pop() == null);
    try testing.expectEqual(@as(usize, 0), s.len());
}

test "small vec spilled storage may shrink below inline capacity without respilling inline" {
    var s = SmallVec(u8, 2).init(testing.allocator, .{ .budget = null });
    defer s.deinit();

    try s.append(1);
    try s.append(2);
    try s.append(3);
    try testing.expect(s.spill != null);

    _ = s.pop();
    _ = s.pop();
    try testing.expectEqual(@as(usize, 1), s.len());

    s.shrinkToFit();
    try testing.expect(s.spill != null);
    try testing.expectEqual(@as(usize, 1), s.spill.?.capacity());
    try testing.expectEqual(@as(u8, 1), s.items()[0]);
}

test "small vec ensureCapacity returns Overflow for oversized public requests" {
    var s = SmallVec(u8, 2).init(testing.allocator, .{ .budget = null });
    defer s.deinit();

    try testing.expectError(error.Overflow, s.ensureCapacity(@as(usize, std.math.maxInt(u32)) + 1));
}
