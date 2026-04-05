//! Vec8i — 8-lane i32 SIMD vector.
//!
//! Re-exports `VecType(8, i32)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec8i`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const testing = std.testing;
const vec_type = @import("vec_type.zig");

pub const Mask8 = @import("masked.zig").Mask8;

/// 8-wide i32 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec8i = vec_type.Vec8i;

test "Vec8i basic arithmetic" {
    const a = Vec8i.splat(7);
    const b = Vec8i.splat(3);

    const sum = Vec8i.add(a, b).toArray();
    for (sum) |val| {
        try testing.expectEqual(@as(i32, 10), val);
    }

    const diff = Vec8i.sub(a, b).toArray();
    for (diff) |val| {
        try testing.expectEqual(@as(i32, 4), val);
    }

    const prod = Vec8i.mul(a, b).toArray();
    for (prod) |val| {
        try testing.expectEqual(@as(i32, 21), val);
    }
}

test "Vec8i bitwise operations" {
    const a = Vec8i.splat(0b1100);
    const b = Vec8i.splat(0b1010);

    const and_result = Vec8i.bitAnd(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b1000), and_result[0]);
    try testing.expectEqual(@as(i32, 0b1000), and_result[7]);

    const or_result = Vec8i.bitOr(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b1110), or_result[0]);

    const xor_result = Vec8i.bitXor(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b0110), xor_result[0]);
}

test "Vec8i shifts and roundtrip" {
    const v = Vec8i.splat(1);
    const left = Vec8i.shl(v, 3).toArray();
    for (left) |val| {
        try testing.expectEqual(@as(i32, 8), val);
    }

    const arr = [8]i32{ -1, 0, 1, 2, 3, 4, 5, 6 };
    const from = Vec8i.fromArray(arr);
    const out = from.toArray();
    try testing.expectEqual(arr, out);
}

test "Vec8i sign, comparison, and select helpers" {
    const a = Vec8i.fromArray(.{ -8, -6, -4, -2, 2, 4, 6, 8 });
    const b = Vec8i.fromArray(.{ -7, -6, -3, -1, 1, 3, 7, 9 });

    const neg = Vec8i.negate(a).toArray();
    try testing.expectEqual(@as(i32, 8), neg[0]);
    try testing.expectEqual(@as(i32, -8), neg[7]);

    const abs_vals = Vec8i.abs(a).toArray();
    try testing.expectEqual(@as(i32, 8), abs_vals[0]);
    try testing.expectEqual(@as(i32, 8), abs_vals[7]);

    const mins = Vec8i.min(a, b).toArray();
    const maxs = Vec8i.max(a, b).toArray();
    try testing.expectEqual(@as(i32, -8), mins[0]);
    try testing.expectEqual(@as(i32, -7), maxs[0]);
    try testing.expectEqual(@as(i32, 6), mins[6]);
    try testing.expectEqual(@as(i32, 7), maxs[6]);

    const selected = Vec8i.select(Mask8.fromBits(0b01010101), a, b).toArray();
    try testing.expectEqual(@as(i32, -8), selected[0]);
    try testing.expectEqual(@as(i32, -6), selected[1]);
    try testing.expectEqual(@as(i32, 6), selected[6]);
    try testing.expectEqual(@as(i32, 9), selected[7]);
}

test "Vec8i bit-not and lane access" {
    const v = Vec8i.fromArray(.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    const not_v = Vec8i.bitNot(v).toArray();
    try testing.expectEqual(@as(i32, -1), not_v[0]);
    try testing.expectEqual(@as(i32, ~@as(i32, 7)), not_v[7]);

    const shifted = Vec8i.shr(Vec8i.fromArray(.{ -16, -8, -4, -2, 2, 4, 8, 16 }), 1).toArray();
    try testing.expectEqual(@as(i32, -8), shifted[0]);
    try testing.expectEqual(@as(i32, 8), shifted[7]);

    var lanes = Vec8i.splat(0);
    lanes = lanes.insert(0, 17);
    lanes = lanes.insert(7, -18);
    try testing.expectEqual(@as(i32, 17), lanes.extract(0));
    try testing.expectEqual(@as(i32, -18), lanes.extract(7));
}
