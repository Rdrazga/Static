//! Vec2f — 2-lane f32 SIMD vector.
//!
//! Re-exports `VecType(2, f32)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec2f`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const testing = std.testing;
const vec_type = @import("vec_type.zig");

pub const Mask2 = @import("masked.zig").Mask2;

/// 2-wide f32 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec2f = vec_type.Vec2f;

/// Construct from two scalar values. Equivalent to `fromArray(.{x, y})`.
pub inline fn init(x: f32, y: f32) Vec2f {
    return Vec2f.fromArray(.{ x, y });
}

test "Vec2f arithmetic matches scalar reference" {
    const a = init(1.0, 2.0);
    const b = init(10.0, 20.0);

    const sum = Vec2f.add(a, b).toArray();
    try testing.expectEqual(@as(f32, 11.0), sum[0]);
    try testing.expectEqual(@as(f32, 22.0), sum[1]);

    const prod = Vec2f.mul(a, b).toArray();
    try testing.expectEqual(@as(f32, 10.0), prod[0]);
    try testing.expectEqual(@as(f32, 40.0), prod[1]);
}

test "Vec2f fromArray -> toArray roundtrip" {
    const arr = [2]f32{ 1.5, 2.5 };
    const v = Vec2f.fromArray(arr);
    const out = v.toArray();
    try testing.expectEqual(arr, out);
}

test "Vec2f sign operations" {
    const v = init(-1.0, 2.0);

    const neg = Vec2f.negate(v).toArray();
    try testing.expectEqual(@as(f32, 1.0), neg[0]);
    try testing.expectEqual(@as(f32, -2.0), neg[1]);

    const a = Vec2f.abs(v).toArray();
    try testing.expectEqual(@as(f32, 1.0), a[0]);
    try testing.expectEqual(@as(f32, 2.0), a[1]);
}

test "Vec2f comparison, select, and lane access" {
    const a = init(4.0, -2.0);
    const b = init(1.0, -3.0);

    const diff = Vec2f.sub(a, b).toArray();
    try testing.expectEqual(@as(f32, 3.0), diff[0]);
    try testing.expectEqual(@as(f32, 1.0), diff[1]);

    const quot = Vec2f.div(a, b).toArray();
    try testing.expectEqual(@as(f32, 4.0), quot[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.6666667), quot[1], 1.0e-6);

    const mins = Vec2f.min(a, b).toArray();
    try testing.expectEqual(@as(f32, 1.0), mins[0]);
    try testing.expectEqual(@as(f32, -3.0), mins[1]);

    const maxs = Vec2f.max(a, b).toArray();
    try testing.expectEqual(@as(f32, 4.0), maxs[0]);
    try testing.expectEqual(@as(f32, -2.0), maxs[1]);

    const selected = Vec2f.select(Mask2.fromBits(0b01), a, b).toArray();
    try testing.expectEqual(@as(f32, 4.0), selected[0]);
    try testing.expectEqual(@as(f32, -3.0), selected[1]);

    var lanes = Vec2f.splat(0.0);
    lanes = lanes.insert(0, 9.0);
    lanes = lanes.insert(1, 8.0);
    try testing.expectEqual(@as(f32, 9.0), lanes.extract(0));
    try testing.expectEqual(@as(f32, 8.0), lanes.extract(1));
}

test "Vec2f copySign applies sign source per lane" {
    const magnitudes = init(3.0, -4.0);
    const signs = init(-1.0, 2.0);
    const result = Vec2f.copySign(magnitudes, signs).toArray();
    try testing.expectEqual(@as(f32, -3.0), result[0]);
    try testing.expectEqual(@as(f32, 4.0), result[1]);
}
