//! Vec4f — 4-lane f32 SIMD vector.
//!
//! Re-exports `VecType(4, f32)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec4f`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const vec_type = @import("vec_type.zig");

pub const Mask4 = @import("masked.zig").Mask4;

/// 4-wide f32 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec4f = vec_type.Vec4f;

test "Vec4f arithmetic matches scalar reference" {
    const a = Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b = Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });

    const sum = Vec4f.add(a, b).toArray();
    try std.testing.expectEqual(@as(f32, 11.0), sum[0]);
    try std.testing.expectEqual(@as(f32, 22.0), sum[1]);
    try std.testing.expectEqual(@as(f32, 33.0), sum[2]);
    try std.testing.expectEqual(@as(f32, 44.0), sum[3]);

    const prod = Vec4f.mul(a, b).toArray();
    try std.testing.expectEqual(@as(f32, 10.0), prod[0]);
    try std.testing.expectEqual(@as(f32, 40.0), prod[1]);
    try std.testing.expectEqual(@as(f32, 90.0), prod[2]);
    try std.testing.expectEqual(@as(f32, 160.0), prod[3]);
}

test "Vec4f fromArray -> toArray roundtrip" {
    const arr = [4]f32{ 1.5, 2.5, 3.5, 4.5 };
    const v = Vec4f.fromArray(arr);
    const out = v.toArray();
    try std.testing.expectEqual(arr, out);
}

test "Vec4f sign operations" {
    const v = Vec4f.init(.{ -1.0, 2.0, -3.0, 0.0 });

    const neg = Vec4f.negate(v).toArray();
    try std.testing.expectEqual(@as(f32, 1.0), neg[0]);
    try std.testing.expectEqual(@as(f32, -2.0), neg[1]);

    const a = Vec4f.abs(v).toArray();
    try std.testing.expectEqual(@as(f32, 1.0), a[0]);
    try std.testing.expectEqual(@as(f32, 3.0), a[2]);
}

test "Vec4f lane extract and insert" {
    const v = Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });
    try std.testing.expectEqual(@as(f32, 30.0), v.extract(2));

    const v2 = v.insert(1, 99.0);
    try std.testing.expectEqual(@as(f32, 99.0), v2.extract(1));
    try std.testing.expectEqual(@as(f32, 10.0), v2.extract(0));
}

test "Vec4f NaN propagation (mandatory)" {
    const nan_val = std.math.nan(f32);
    const nan_vec = Vec4f.splat(nan_val);
    const one = Vec4f.splat(1.0);

    // add(nan, 1.0) must produce NaN.
    const sum = Vec4f.add(nan_vec, one).toArray();
    try std.testing.expect(std.math.isNan(sum[0]));
    try std.testing.expect(std.math.isNan(sum[1]));

    // mul(inf, 0.0) must produce NaN.
    const inf_vec = Vec4f.splat(std.math.inf(f32));
    const zero = Vec4f.splat(0.0);
    const prod = Vec4f.mul(inf_vec, zero).toArray();
    try std.testing.expect(std.math.isNan(prod[0]));
}

test "Vec4f div by zero produces Inf" {
    const numerators = Vec4f.init(.{ 1.0, -1.0, 1.0, -1.0 });
    const zeros = Vec4f.init(.{ 0.0, 0.0, -0.0, -0.0 });
    const result = Vec4f.div(numerators, zeros).toArray();
    try std.testing.expect(std.math.isInf(result[0]));
    try std.testing.expect(!std.math.signbit(result[0]));
    try std.testing.expect(std.math.isInf(result[1]));
    try std.testing.expect(std.math.signbit(result[1]));
    try std.testing.expect(std.math.isInf(result[2]));
    try std.testing.expect(std.math.signbit(result[2]));
    try std.testing.expect(std.math.isInf(result[3]));
    try std.testing.expect(!std.math.signbit(result[3]));
}

test "Vec4f comparison, select, and copySign helpers" {
    const a = Vec4f.init(.{ 5.0, -2.0, 7.0, -9.0 });
    const b = Vec4f.init(.{ 1.0, -3.0, 8.0, -4.0 });

    const diff = Vec4f.sub(a, b).toArray();
    try std.testing.expectEqual(@as(f32, 4.0), diff[0]);
    try std.testing.expectEqual(@as(f32, 1.0), diff[1]);
    try std.testing.expectEqual(@as(f32, -1.0), diff[2]);
    try std.testing.expectEqual(@as(f32, -5.0), diff[3]);

    const mins = Vec4f.min(a, b).toArray();
    const maxs = Vec4f.max(a, b).toArray();
    try std.testing.expectEqual(@as(f32, 1.0), mins[0]);
    try std.testing.expectEqual(@as(f32, 5.0), maxs[0]);
    try std.testing.expectEqual(@as(f32, -3.0), mins[1]);
    try std.testing.expectEqual(@as(f32, -2.0), maxs[1]);

    const selected = Vec4f.select(Mask4.fromBits(0b0101), a, b).toArray();
    try std.testing.expectEqual(@as(f32, 5.0), selected[0]);
    try std.testing.expectEqual(@as(f32, -3.0), selected[1]);
    try std.testing.expectEqual(@as(f32, 7.0), selected[2]);
    try std.testing.expectEqual(@as(f32, -4.0), selected[3]);

    const copy_sign = Vec4f.copySign(Vec4f.splat(2.0), a).toArray();
    try std.testing.expectEqual(@as(f32, 2.0), copy_sign[0]);
    try std.testing.expectEqual(@as(f32, -2.0), copy_sign[1]);
    try std.testing.expectEqual(@as(f32, 2.0), copy_sign[2]);
    try std.testing.expectEqual(@as(f32, -2.0), copy_sign[3]);
}
