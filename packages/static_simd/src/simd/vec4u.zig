//! Vec4u — 4-lane u32 SIMD vector.
//!
//! Re-exports `VecType(4, u32)` from `vec_type.zig` as the authoritative
//! implementation. All operations are inherited from the generic factory.
//!
//! Key type: `Vec4u`.
//! Thread safety: immutable operations are thread-safe; no shared state.

const std = @import("std");
const vec_type = @import("vec_type.zig");

pub const Mask4 = @import("masked.zig").Mask4;

/// 4-wide u32 SIMD vector with arithmetic, comparison, load/store, and lane-wise helpers.
pub const Vec4u = vec_type.Vec4u;

test "Vec4u arithmetic" {
    const a = Vec4u.init(.{ 10, 20, 30, 40 });
    const b = Vec4u.init(.{ 1, 2, 3, 4 });

    const sum = Vec4u.add(a, b).toArray();
    try std.testing.expectEqual(@as(u32, 11), sum[0]);
    try std.testing.expectEqual(@as(u32, 22), sum[1]);
    try std.testing.expectEqual(@as(u32, 33), sum[2]);
    try std.testing.expectEqual(@as(u32, 44), sum[3]);

    const prod = Vec4u.mul(a, b).toArray();
    try std.testing.expectEqual(@as(u32, 10), prod[0]);
    try std.testing.expectEqual(@as(u32, 40), prod[1]);
    try std.testing.expectEqual(@as(u32, 90), prod[2]);
    try std.testing.expectEqual(@as(u32, 160), prod[3]);
}

test "Vec4u bitwise operations" {
    const a = Vec4u.splat(0xFF00);
    const b = Vec4u.splat(0x0FF0);

    const and_result = Vec4u.bitAnd(a, b).toArray();
    try std.testing.expectEqual(@as(u32, 0x0F00), and_result[0]);

    const or_result = Vec4u.bitOr(a, b).toArray();
    try std.testing.expectEqual(@as(u32, 0xFFF0), or_result[0]);

    const xor_result = Vec4u.bitXor(a, b).toArray();
    try std.testing.expectEqual(@as(u32, 0xF0F0), xor_result[0]);

    const not_result = Vec4u.bitNot(Vec4u.splat(0)).toArray();
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), not_result[0]);
}

test "Vec4u shifts" {
    const v = Vec4u.splat(1);

    const left = Vec4u.shl(v, 8).toArray();
    try std.testing.expectEqual(@as(u32, 256), left[0]);

    const big = Vec4u.splat(256);
    const right = Vec4u.shr(big, 4).toArray();
    try std.testing.expectEqual(@as(u32, 16), right[0]);
}

test "Vec4u sub, select, fromArray, and lane access" {
    const a = Vec4u.init(.{ 5, 6, 7, 8 });
    const b = Vec4u.init(.{ 1, 2, 3, 4 });
    const diff = Vec4u.sub(a, b).toArray();
    try std.testing.expectEqual(@as(u32, 4), diff[0]);
    try std.testing.expectEqual(@as(u32, 4), diff[1]);
    try std.testing.expectEqual(@as(u32, 4), diff[2]);
    try std.testing.expectEqual(@as(u32, 4), diff[3]);

    const selected = Vec4u.select(Mask4.fromBits(0b0101), a, b).toArray();
    try std.testing.expectEqual(@as(u32, 5), selected[0]);
    try std.testing.expectEqual(@as(u32, 2), selected[1]);
    try std.testing.expectEqual(@as(u32, 7), selected[2]);
    try std.testing.expectEqual(@as(u32, 4), selected[3]);

    const arr = [_]u32{ 9, 8, 7, 6 };
    const roundtrip = Vec4u.fromArray(arr).toArray();
    try std.testing.expectEqual(arr, roundtrip);

    var lanes = Vec4u.splat(0);
    lanes = lanes.insert(0, 123);
    lanes = lanes.insert(3, 456);
    try std.testing.expectEqual(@as(u32, 123), lanes.extract(0));
    try std.testing.expectEqual(@as(u32, 456), lanes.extract(3));
}
