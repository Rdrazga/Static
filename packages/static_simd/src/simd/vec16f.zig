//! Vec16f — 16-lane f32 SIMD vector.
//!
//! Re-exports `VecType(16, f32)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec16f`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const vec_type = @import("vec_type.zig");

pub const Mask16 = @import("masked.zig").Mask16;

/// 16-wide f32 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec16f = vec_type.Vec16f;

test "Vec16f basic arithmetic" {
    const a = Vec16f.splat(5.0);
    const b = Vec16f.splat(3.0);

    const sum = Vec16f.add(a, b).toArray();
    for (sum) |val| {
        try std.testing.expectEqual(@as(f32, 8.0), val);
    }

    const diff = Vec16f.sub(a, b).toArray();
    for (diff) |val| {
        try std.testing.expectEqual(@as(f32, 2.0), val);
    }
}

test "Vec16f splat -> toArray" {
    const v = Vec16f.splat(7.0);
    const arr = v.toArray();
    for (arr) |val| {
        try std.testing.expectEqual(@as(f32, 7.0), val);
    }
}

test "Vec16f lane access" {
    var v = Vec16f.splat(0.0);
    v = v.insert(0, 1.0);
    v = v.insert(15, 16.0);
    try std.testing.expectEqual(@as(f32, 1.0), v.extract(0));
    try std.testing.expectEqual(@as(f32, 16.0), v.extract(15));
    try std.testing.expectEqual(@as(f32, 0.0), v.extract(8));
}

test "Vec16f arithmetic and sign operations" {
    const a = Vec16f.fromArray(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const b = Vec16f.splat(2.0);

    const prod = Vec16f.mul(a, b).toArray();
    try std.testing.expectEqual(@as(f32, 2.0), prod[0]);
    try std.testing.expectEqual(@as(f32, 32.0), prod[15]);

    const quot = Vec16f.div(a, b).toArray();
    try std.testing.expectEqual(@as(f32, 0.5), quot[0]);
    try std.testing.expectEqual(@as(f32, 8.0), quot[15]);

    const neg = Vec16f.negate(a).toArray();
    try std.testing.expectEqual(@as(f32, -1.0), neg[0]);
    try std.testing.expectEqual(@as(f32, -16.0), neg[15]);

    const abs_vals = Vec16f.abs(Vec16f.negate(a)).toArray();
    try std.testing.expectEqual(@as(f32, 1.0), abs_vals[0]);
    try std.testing.expectEqual(@as(f32, 16.0), abs_vals[15]);
}

test "Vec16f min/max/select and copySign" {
    const a = Vec16f.fromArray(.{ -8, -7, -6, -5, -4, -3, -2, -1, 1, 2, 3, 4, 5, 6, 7, 8 });
    const b = Vec16f.fromArray(.{ 8, 7, 6, 5, 4, 3, 2, 1, -1, -2, -3, -4, -5, -6, -7, -8 });

    const mins = Vec16f.min(a, b).toArray();
    const maxs = Vec16f.max(a, b).toArray();
    try std.testing.expectEqual(@as(f32, -8.0), mins[0]);
    try std.testing.expectEqual(@as(f32, 8.0), maxs[0]);
    try std.testing.expectEqual(@as(f32, -8.0), mins[15]);
    try std.testing.expectEqual(@as(f32, 8.0), maxs[15]);

    const mask = Mask16.fromBits(0xAAAA);
    const selected = Vec16f.select(mask, a, b).toArray();
    try std.testing.expectEqual(@as(f32, 8.0), selected[0]);
    try std.testing.expectEqual(@as(f32, -7.0), selected[1]);

    const mag = Vec16f.splat(3.0);
    const signed = Vec16f.copySign(mag, a).toArray();
    try std.testing.expectEqual(@as(f32, -3.0), signed[0]);
    try std.testing.expectEqual(@as(f32, 3.0), signed[15]);
}

test "Vec16f init and fromArray roundtrip" {
    const i = Vec16f.init(.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }).toArray();
    try std.testing.expectEqual(@as(f32, 0.0), i[0]);
    try std.testing.expectEqual(@as(f32, 15.0), i[15]);

    const arr = [_]f32{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
    const v = Vec16f.fromArray(arr);
    try std.testing.expectEqual(arr, v.toArray());
}
