//! Vec8f — 8-lane f32 SIMD vector.
//!
//! Re-exports `VecType(8, f32)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec8f`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const vec_type = @import("vec_type.zig");

pub const Mask8 = @import("masked.zig").Mask8;

/// 8-wide f32 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec8f = vec_type.Vec8f;

test "Vec8f basic arithmetic" {
    const a = Vec8f.splat(3.0);
    const b = Vec8f.splat(2.0);

    const sum = Vec8f.add(a, b).toArray();
    for (sum) |val| {
        try std.testing.expectEqual(@as(f32, 5.0), val);
    }

    const diff = Vec8f.sub(a, b).toArray();
    for (diff) |val| {
        try std.testing.expectEqual(@as(f32, 1.0), val);
    }

    const prod = Vec8f.mul(a, b).toArray();
    for (prod) |val| {
        try std.testing.expectEqual(@as(f32, 6.0), val);
    }
}

test "Vec8f splat -> toArray" {
    const v = Vec8f.splat(42.0);
    const arr = v.toArray();
    for (arr) |val| {
        try std.testing.expectEqual(@as(f32, 42.0), val);
    }
}

test "Vec8f NaN propagation" {
    const nan_val = std.math.nan(f32);
    const nan_vec = Vec8f.splat(nan_val);
    const one = Vec8f.splat(1.0);

    const sum = Vec8f.add(nan_vec, one).toArray();
    try std.testing.expect(std.math.isNan(sum[0]));
    try std.testing.expect(std.math.isNan(sum[7]));

    const inf_vec = Vec8f.splat(std.math.inf(f32));
    const zero = Vec8f.splat(0.0);
    const prod = Vec8f.mul(inf_vec, zero).toArray();
    try std.testing.expect(std.math.isNan(prod[0]));
}

test "Vec8f div and helper operations" {
    const a = Vec8f.fromArray(.{ 8, -6, 4, -2, 10, -12, 14, -16 });
    const b = Vec8f.fromArray(.{ 2, -3, 1, -4, 5, -6, 7, -8 });

    const quot = Vec8f.div(a, b).toArray();
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), quot[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), quot[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), quot[2], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), quot[3], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), quot[4], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), quot[5], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), quot[6], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), quot[7], 1.0e-6);

    const neg = Vec8f.negate(a).toArray();
    try std.testing.expectEqual(@as(f32, -8.0), neg[0]);
    try std.testing.expectEqual(@as(f32, 16.0), neg[7]);

    const abs_vals = Vec8f.abs(a).toArray();
    try std.testing.expectEqual(@as(f32, 8.0), abs_vals[0]);
    try std.testing.expectEqual(@as(f32, 16.0), abs_vals[7]);

    const mins = Vec8f.min(a, b).toArray();
    const maxs = Vec8f.max(a, b).toArray();
    try std.testing.expectEqual(@as(f32, 2.0), mins[0]);
    try std.testing.expectEqual(@as(f32, 8.0), maxs[0]);
    try std.testing.expectEqual(@as(f32, -16.0), mins[7]);
    try std.testing.expectEqual(@as(f32, -8.0), maxs[7]);
}

test "Vec8f copySign, select, and lane access" {
    const magnitudes = Vec8f.splat(2.5);
    const signs = Vec8f.fromArray(.{ 1, -1, 1, -1, 1, -1, 1, -1 });
    const signed = Vec8f.copySign(magnitudes, signs).toArray();
    try std.testing.expectEqual(@as(f32, 2.5), signed[0]);
    try std.testing.expectEqual(@as(f32, -2.5), signed[1]);
    try std.testing.expectEqual(@as(f32, -2.5), signed[7]);

    const a = Vec8f.fromArray(.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    const b = Vec8f.splat(99.0);
    const selected = Vec8f.select(Mask8.fromBits(0b01010101), a, b).toArray();
    try std.testing.expectEqual(@as(f32, 0.0), selected[0]);
    try std.testing.expectEqual(@as(f32, 99.0), selected[1]);
    try std.testing.expectEqual(@as(f32, 6.0), selected[6]);
    try std.testing.expectEqual(@as(f32, 99.0), selected[7]);

    var lanes = Vec8f.splat(0.0);
    lanes = lanes.insert(0, 3.0);
    lanes = lanes.insert(7, 4.0);
    try std.testing.expectEqual(@as(f32, 3.0), lanes.extract(0));
    try std.testing.expectEqual(@as(f32, 4.0), lanes.extract(7));
}
