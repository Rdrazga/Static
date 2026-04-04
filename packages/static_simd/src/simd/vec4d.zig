//! Vec4d — 4-lane f64 SIMD vector.
//!
//! Re-exports `VecType(4, f64)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec4d`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const vec_type = @import("vec_type.zig");

pub const Mask4 = @import("masked.zig").Mask4;

/// 4-wide f64 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec4d = vec_type.Vec4d;

test "Vec4d arithmetic matches scalar reference" {
    const a = Vec4d.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b = Vec4d.init(.{ 10.0, 20.0, 30.0, 40.0 });

    const sum = Vec4d.add(a, b).toArray();
    try std.testing.expectEqual(@as(f64, 11.0), sum[0]);
    try std.testing.expectEqual(@as(f64, 22.0), sum[1]);
    try std.testing.expectEqual(@as(f64, 33.0), sum[2]);
    try std.testing.expectEqual(@as(f64, 44.0), sum[3]);

    const prod = Vec4d.mul(a, b).toArray();
    try std.testing.expectEqual(@as(f64, 10.0), prod[0]);
    try std.testing.expectEqual(@as(f64, 40.0), prod[1]);
    try std.testing.expectEqual(@as(f64, 90.0), prod[2]);
    try std.testing.expectEqual(@as(f64, 160.0), prod[3]);
}

test "Vec4d fromArray -> toArray roundtrip" {
    const arr = [4]f64{ 1.5, 2.5, 3.5, 4.5 };
    const v = Vec4d.fromArray(arr);
    const out = v.toArray();
    try std.testing.expectEqual(arr, out);
}

test "Vec4d precision check — f64 vs f32" {
    // 1.0 + 1e-12 should be distinguishable in f64 but not in f32.
    const tiny: f64 = 1.0e-12;
    const one_d = Vec4d.splat(1.0);
    const eps_d = Vec4d.splat(tiny);
    const sum_d = Vec4d.add(one_d, eps_d).toArray();
    try std.testing.expect(sum_d[0] != 1.0);

    // The same value in f32 collapses to 1.0.
    const tiny_f32: f32 = @floatCast(tiny);
    try std.testing.expectEqual(@as(f32, 1.0), 1.0 + tiny_f32);
}

test "Vec4d arithmetic, sign, and comparison helpers" {
    const a = Vec4d.init(.{ 8.0, -6.0, 4.0, -2.0 });
    const b = Vec4d.init(.{ 2.0, -3.0, 1.0, -4.0 });

    const diff = Vec4d.sub(a, b).toArray();
    try std.testing.expectEqual(@as(f64, 6.0), diff[0]);
    try std.testing.expectEqual(@as(f64, -3.0), diff[1]);
    try std.testing.expectEqual(@as(f64, 3.0), diff[2]);
    try std.testing.expectEqual(@as(f64, 2.0), diff[3]);

    const quot = Vec4d.div(a, b).toArray();
    try std.testing.expectEqual(@as(f64, 4.0), quot[0]);
    try std.testing.expectEqual(@as(f64, 2.0), quot[1]);
    try std.testing.expectEqual(@as(f64, 4.0), quot[2]);
    try std.testing.expectEqual(@as(f64, 0.5), quot[3]);

    const neg = Vec4d.negate(a).toArray();
    try std.testing.expectEqual(@as(f64, -8.0), neg[0]);
    try std.testing.expectEqual(@as(f64, 6.0), neg[1]);

    const abs_vals = Vec4d.abs(a).toArray();
    try std.testing.expectEqual(@as(f64, 8.0), abs_vals[0]);
    try std.testing.expectEqual(@as(f64, 6.0), abs_vals[1]);

    const mins = Vec4d.min(a, b).toArray();
    const maxs = Vec4d.max(a, b).toArray();
    try std.testing.expectEqual(@as(f64, 2.0), mins[0]);
    try std.testing.expectEqual(@as(f64, 8.0), maxs[0]);
    try std.testing.expectEqual(@as(f64, -6.0), mins[1]);
    try std.testing.expectEqual(@as(f64, -3.0), maxs[1]);
}

test "Vec4d copySign, select, and lane access" {
    const magnitudes = Vec4d.init(.{ 1.0, -2.0, 3.0, -4.0 });
    const signs = Vec4d.init(.{ -1.0, 1.0, -1.0, 1.0 });
    const signed = Vec4d.copySign(magnitudes, signs).toArray();
    try std.testing.expectEqual(@as(f64, -1.0), signed[0]);
    try std.testing.expectEqual(@as(f64, 2.0), signed[1]);
    try std.testing.expectEqual(@as(f64, -3.0), signed[2]);
    try std.testing.expectEqual(@as(f64, 4.0), signed[3]);

    const a = Vec4d.init(.{ 10.0, 20.0, 30.0, 40.0 });
    const b = Vec4d.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const selected = Vec4d.select(Mask4.fromBits(0b0101), a, b).toArray();
    try std.testing.expectEqual(@as(f64, 10.0), selected[0]);
    try std.testing.expectEqual(@as(f64, 2.0), selected[1]);
    try std.testing.expectEqual(@as(f64, 30.0), selected[2]);
    try std.testing.expectEqual(@as(f64, 4.0), selected[3]);

    var lanes = Vec4d.splat(0.0);
    lanes = lanes.insert(0, 7.0);
    lanes = lanes.insert(3, -9.0);
    try std.testing.expectEqual(@as(f64, 7.0), lanes.extract(0));
    try std.testing.expectEqual(@as(f64, -9.0), lanes.extract(3));
}
