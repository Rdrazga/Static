//! Fixed-capacity vector backed by a stack-allocated array.
//!
//! Key type: `FixedVec(T, N)`. Maximum capacity `N` is set at comptime. No heap
//! allocation; suitable for small collections with known upper bounds (e.g. scratch
//! buffers, per-frame work lists).
//!
//! Attempting to push beyond `N` returns `error.Full`.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const assert = std.debug.assert;

pub fn FixedVec(comptime T: type, comptime N: usize) type {
    // Comptime guard: a zero-capacity FixedVec is always full and useless as a container.
    comptime assert(N > 0);

    return struct {
        const Self = @This();
        pub const Element = T;
        pub const max_capacity: u32 = N;

        items_storage: [N]T = undefined,
        len_value: usize = 0,

        pub fn len(self: *const Self) usize {
            assert(self.len_value <= N);
            return self.len_value;
        }

        pub fn capacity(_: *const Self) usize {
            // Comptime-known result; assert it matches the type constant.
            comptime assert(N > 0);
            return max_capacity;
        }

        pub fn items(self: *Self) []T {
            assert(self.len_value <= N);
            const result = self.items_storage[0..self.len_value];
            // Postcondition: returned slice length must equal the logical length.
            assert(result.len == self.len_value);
            return result;
        }

        pub fn itemsConst(self: *const Self) []const T {
            assert(self.len_value <= N);
            const result = self.items_storage[0..self.len_value];
            // Postcondition: returned slice length must equal the logical length.
            assert(result.len == self.len_value);
            return result;
        }

        pub fn append(self: *Self, value: T) error{NoSpaceLeft}!void {
            assert(self.len_value <= N);
            if (self.len_value >= N) return error.NoSpaceLeft;
            self.items_storage[self.len_value] = value;
            self.len_value += 1;
            assert(self.len_value <= N);
            // Postcondition: length advanced by exactly one; never zero after a successful append.
            assert(self.len_value > 0);
        }

        pub fn clear(self: *Self) void {
            assert(self.len_value <= N);
            self.len_value = 0;
            assert(self.len_value == 0);
            // Postcondition: capacity is unaffected by clear.
            assert(self.capacity() == N);
        }
    };
}

test "fixed vec enforces capacity" {
    // Goal: verify bounded capacity rejects overflow writes.
    // Method: fill to capacity and assert one more append fails.
    var v = FixedVec(u8, 2){};
    try v.append(1);
    try v.append(2);
    try std.testing.expectError(error.NoSpaceLeft, v.append(3));
}

test "fixed vec clear resets logical length" {
    // Goal: ensure clear only resets logical length, not capacity.
    // Method: append values, clear, then verify len is zero and capacity unchanged.
    var v = FixedVec(u8, 3){};
    try v.append(4);
    try v.append(5);
    try std.testing.expectEqual(@as(usize, 2), v.len());
    v.clear();
    try std.testing.expectEqual(@as(usize, 0), v.len());
    try std.testing.expectEqual(@as(usize, 3), v.capacity());
}

test "fixed vec items reflects append order" {
    // Goal: ensure exposed slice matches append order and length.
    // Method: append two values and assert item slice content.
    var v = FixedVec(u16, 4){};
    try v.append(11);
    try v.append(22);
    const values = v.items();
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual(@as(u16, 11), values[0]);
    try std.testing.expectEqual(@as(u16, 22), values[1]);
}
