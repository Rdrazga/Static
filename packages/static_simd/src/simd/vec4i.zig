//! Vec4i — 4-lane i32 SIMD vector.
//!
//! Re-exports `VecType(4, i32)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec4i`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const testing = std.testing;
const vec_type = @import("vec_type.zig");

pub const Mask4 = @import("masked.zig").Mask4;

/// 4-wide i32 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec4i = vec_type.Vec4i;

test "Vec4i arithmetic matches scalar reference" {
    const a = Vec4i.init(.{ 1, 2, 3, 4 });
    const b = Vec4i.init(.{ 10, 20, 30, 40 });

    const sum = Vec4i.add(a, b).toArray();
    try testing.expectEqual(@as(i32, 11), sum[0]);
    try testing.expectEqual(@as(i32, 22), sum[1]);
    try testing.expectEqual(@as(i32, 33), sum[2]);
    try testing.expectEqual(@as(i32, 44), sum[3]);

    const prod = Vec4i.mul(a, b).toArray();
    try testing.expectEqual(@as(i32, 10), prod[0]);
    try testing.expectEqual(@as(i32, 40), prod[1]);
    try testing.expectEqual(@as(i32, 90), prod[2]);
    try testing.expectEqual(@as(i32, 160), prod[3]);
}

test "Vec4i bitwise operations" {
    const a = Vec4i.splat(0b1100);
    const b = Vec4i.splat(0b1010);

    const and_result = Vec4i.bitAnd(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b1000), and_result[0]);

    const or_result = Vec4i.bitOr(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b1110), or_result[0]);

    const xor_result = Vec4i.bitXor(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b0110), xor_result[0]);

    const not_result = Vec4i.bitNot(Vec4i.splat(0)).toArray();
    try testing.expectEqual(@as(i32, -1), not_result[0]);
}

test "Vec4i shifts" {
    const v = Vec4i.splat(1);

    const left = Vec4i.shl(v, 4).toArray();
    try testing.expectEqual(@as(i32, 16), left[0]);

    const big = Vec4i.splat(64);
    const right = Vec4i.shr(big, 2).toArray();
    try testing.expectEqual(@as(i32, 16), right[0]);
}

test "Vec4i fromArray -> toArray roundtrip" {
    const arr = [4]i32{ -1, 0, 42, 1000 };
    const v = Vec4i.fromArray(arr);
    const out = v.toArray();
    try testing.expectEqual(arr, out);
}

test "Vec4i sign, comparison, select, and lane helpers" {
    const a = Vec4i.init(.{ -5, 6, -7, 8 });
    const b = Vec4i.init(.{ 1, -2, -7, 9 });

    const diff = Vec4i.sub(a, b).toArray();
    try testing.expectEqual(@as(i32, -6), diff[0]);
    try testing.expectEqual(@as(i32, 8), diff[1]);
    try testing.expectEqual(@as(i32, 0), diff[2]);
    try testing.expectEqual(@as(i32, -1), diff[3]);

    const neg = Vec4i.negate(a).toArray();
    try testing.expectEqual(@as(i32, 5), neg[0]);
    try testing.expectEqual(@as(i32, -6), neg[1]);
    try testing.expectEqual(@as(i32, 7), neg[2]);
    try testing.expectEqual(@as(i32, -8), neg[3]);

    const abs_vals = Vec4i.abs(a).toArray();
    try testing.expectEqual(@as(i32, 5), abs_vals[0]);
    try testing.expectEqual(@as(i32, 6), abs_vals[1]);
    try testing.expectEqual(@as(i32, 7), abs_vals[2]);
    try testing.expectEqual(@as(i32, 8), abs_vals[3]);

    const mins = Vec4i.min(a, b).toArray();
    const maxs = Vec4i.max(a, b).toArray();
    try testing.expectEqual(@as(i32, -5), mins[0]);
    try testing.expectEqual(@as(i32, 1), maxs[0]);
    try testing.expectEqual(@as(i32, -2), mins[1]);
    try testing.expectEqual(@as(i32, 6), maxs[1]);

    const selected = Vec4i.select(Mask4.fromBits(0b0101), a, b).toArray();
    try testing.expectEqual(@as(i32, -5), selected[0]);
    try testing.expectEqual(@as(i32, -2), selected[1]);
    try testing.expectEqual(@as(i32, -7), selected[2]);
    try testing.expectEqual(@as(i32, 9), selected[3]);

    var lanes = Vec4i.splat(0);
    lanes = lanes.insert(0, 12);
    lanes = lanes.insert(3, -13);
    try testing.expectEqual(@as(i32, 12), lanes.extract(0));
    try testing.expectEqual(@as(i32, -13), lanes.extract(3));
}
