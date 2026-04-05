//! Fixed-capacity vector backed by a stack-allocated array.
//!
//! Key type: `FixedVec(T, N)`. Maximum capacity `N` is set at comptime. No heap
//! allocation; suitable for small collections with known upper bounds (e.g. scratch
//! buffers, per-frame work lists).
//!
//! Attempting to push beyond `N` returns `error.NoSpaceLeft`.
//!
//! Note: the error set (`error{NoSpaceLeft}`) is narrower than `Vec.Error`.
//! FixedVec is not a drop-in substitute for Vec without adjusting error handling.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

pub fn FixedVec(comptime T: type, comptime N: usize) type {
    comptime {
        // A zero-capacity FixedVec is always full and useless as a container.
        if (N == 0) @compileError("FixedVec requires at least one element of capacity.");
        // max_capacity is stored as u32; reject values that would overflow.
        if (N > std.math.maxInt(u32)) @compileError("FixedVec capacity N exceeds u32 range.");
    }

    return struct {
        const Self = @This();
        pub const Element = T;
        pub const max_capacity: u32 = N;

        items_storage: [N]T = undefined,
        len_value: u32 = 0,

        pub fn len(self: *const Self) u32 {
            assert(self.len_value <= max_capacity);
            return self.len_value;
        }

        pub fn capacity(_: *const Self) u32 {
            comptime assert(N > 0);
            return max_capacity;
        }

        pub fn items(self: *Self) []T {
            assert(self.len_value <= max_capacity);
            const result = self.items_storage[0..self.len_value];
            assert(result.len == self.len_value);
            return result;
        }

        pub fn itemsConst(self: *const Self) []const T {
            assert(self.len_value <= max_capacity);
            const result = self.items_storage[0..self.len_value];
            assert(result.len == self.len_value);
            return result;
        }

        pub fn append(self: *Self, value: T) error{NoSpaceLeft}!void {
            assert(self.len_value <= max_capacity);
            if (self.len_value >= max_capacity) return error.NoSpaceLeft;
            self.items_storage[self.len_value] = value;
            self.len_value += 1;
            assert(self.len_value <= max_capacity);
            assert(self.len_value > 0);
        }

        /// Returns an independent copy. FixedVec is stack-allocated,
        /// so this is a simple struct copy.
        pub fn clone(self: *const Self) Self {
            assert(self.len_value <= max_capacity);
            var result: Self = .{
                .len_value = self.len_value,
            };
            @memcpy(result.items_storage[0..self.len_value], self.items_storage[0..self.len_value]);
            assert(result.len_value == self.len_value);
            return result;
        }

        pub fn pop(self: *Self) ?T {
            assert(self.len_value <= max_capacity);
            if (self.len_value == 0) return null;
            self.len_value -= 1;
            const out = self.items_storage[self.len_value];
            assert(self.len_value <= max_capacity);
            return out;
        }

        pub fn clear(self: *Self) void {
            assert(self.len_value <= max_capacity);
            self.len_value = 0;
            assert(self.len_value == 0);
            assert(self.capacity() == max_capacity);
        }
    };
}

test "fixed vec enforces capacity" {
    // Goal: verify bounded capacity rejects overflow writes.
    // Method: fill to capacity and assert one more append fails.
    var v = FixedVec(u8, 2){};
    try v.append(1);
    try v.append(2);
    try testing.expectError(error.NoSpaceLeft, v.append(3));
}

test "fixed vec clear resets logical length" {
    // Goal: ensure clear only resets logical length, not capacity.
    // Method: append values, clear, then verify len is zero and capacity unchanged.
    var v = FixedVec(u8, 3){};
    try v.append(4);
    try v.append(5);
    try testing.expectEqual(@as(usize, 2), v.len());
    v.clear();
    try testing.expectEqual(@as(usize, 0), v.len());
    try testing.expectEqual(@as(usize, 3), v.capacity());
}

test "fixed vec items reflects append order" {
    // Goal: ensure exposed slice matches append order and length.
    // Method: append two values and assert item slice content.
    var v = FixedVec(u16, 4){};
    try v.append(11);
    try v.append(22);
    const values = v.items();
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqual(@as(u16, 11), values[0]);
    try testing.expectEqual(@as(u16, 22), values[1]);
}

test "fixed vec pop returns last element or null when empty" {
    // Goal: validate LIFO pop semantics and empty-vector behavior.
    // Method: pop from empty, then append/pop values back to empty.
    var v = FixedVec(u8, 3){};
    try testing.expect(v.pop() == null);
    try v.append(10);
    try v.append(20);
    try testing.expectEqual(@as(u8, 20), v.pop().?);
    try testing.expectEqual(@as(u8, 10), v.pop().?);
    try testing.expect(v.pop() == null);
    try testing.expectEqual(@as(usize, 0), v.len());
}
