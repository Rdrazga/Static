//! Vec2i — 2-lane i32 SIMD vector.
//!
//! Re-exports `VecType(2, i32)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec2i`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const vec_type = @import("vec_type.zig");

pub const Mask2 = @import("masked.zig").Mask2;

/// 2-wide i32 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec2i = vec_type.Vec2i;

test "Vec2i arithmetic matches scalar reference" {
    const a = Vec2i.init(.{ 3, -5 });
    const b = Vec2i.init(.{ 10, 20 });

    const sum = Vec2i.add(a, b).toArray();
    try std.testing.expectEqual(@as(i32, 13), sum[0]);
    try std.testing.expectEqual(@as(i32, 15), sum[1]);

    const prod = Vec2i.mul(a, b).toArray();
    try std.testing.expectEqual(@as(i32, 30), prod[0]);
    try std.testing.expectEqual(@as(i32, -100), prod[1]);
}

test "Vec2i bitwise operations" {
    const a = Vec2i.splat(0b1100);
    const b = Vec2i.splat(0b1010);

    const and_result = Vec2i.bitAnd(a, b).toArray();
    try std.testing.expectEqual(@as(i32, 0b1000), and_result[0]);

    const or_result = Vec2i.bitOr(a, b).toArray();
    try std.testing.expectEqual(@as(i32, 0b1110), or_result[0]);

    const xor_result = Vec2i.bitXor(a, b).toArray();
    try std.testing.expectEqual(@as(i32, 0b0110), xor_result[0]);
}

test "Vec2i fromArray -> toArray roundtrip" {
    const arr = [2]i32{ -42, 99 };
    const v = Vec2i.fromArray(arr);
    const out = v.toArray();
    try std.testing.expectEqual(arr, out);
}

test "Vec2i sign, comparison, select, and lane access" {
    const a = Vec2i.init(.{ -7, 9 });
    const b = Vec2i.init(.{ 3, -10 });

    const diff = Vec2i.sub(a, b).toArray();
    try std.testing.expectEqual(@as(i32, -10), diff[0]);
    try std.testing.expectEqual(@as(i32, 19), diff[1]);

    const neg = Vec2i.negate(a).toArray();
    try std.testing.expectEqual(@as(i32, 7), neg[0]);
    try std.testing.expectEqual(@as(i32, -9), neg[1]);

    const abs_vals = Vec2i.abs(a).toArray();
    try std.testing.expectEqual(@as(i32, 7), abs_vals[0]);
    try std.testing.expectEqual(@as(i32, 9), abs_vals[1]);

    const mins = Vec2i.min(a, b).toArray();
    const maxs = Vec2i.max(a, b).toArray();
    try std.testing.expectEqual(@as(i32, -7), mins[0]);
    try std.testing.expectEqual(@as(i32, 3), maxs[0]);
    try std.testing.expectEqual(@as(i32, -10), mins[1]);
    try std.testing.expectEqual(@as(i32, 9), maxs[1]);

    const selected = Vec2i.select(Mask2.fromBits(0b01), a, b).toArray();
    try std.testing.expectEqual(@as(i32, -7), selected[0]);
    try std.testing.expectEqual(@as(i32, -10), selected[1]);

    var lanes = Vec2i.splat(0);
    lanes = lanes.insert(0, 11);
    lanes = lanes.insert(1, -12);
    try std.testing.expectEqual(@as(i32, 11), lanes.extract(0));
    try std.testing.expectEqual(@as(i32, -12), lanes.extract(1));
}

test "Vec2i shift and bit-not operations" {
    const v = Vec2i.init(.{ 1, -8 });
    const left = Vec2i.shl(v, 2).toArray();
    try std.testing.expectEqual(@as(i32, 4), left[0]);
    try std.testing.expectEqual(@as(i32, -32), left[1]);

    const right = Vec2i.shr(v, 1).toArray();
    try std.testing.expectEqual(@as(i32, 0), right[0]);
    try std.testing.expectEqual(@as(i32, -4), right[1]);

    const not_v = Vec2i.bitNot(v).toArray();
    try std.testing.expectEqual(@as(i32, ~@as(i32, 1)), not_v[0]);
    try std.testing.expectEqual(@as(i32, ~@as(i32, -8)), not_v[1]);
}
