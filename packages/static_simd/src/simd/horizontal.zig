//! Cross-lane reductions — sum, product, min, max.
//!
//! These operations collapse a vector into a single scalar value.
//! Polymorphic over Vec4f/Vec8f via `anytype` + comptime type checks.

const std = @import("std");
const testing = std.testing;
const vec2f = @import("vec2f.zig");
const vec4f = @import("vec4f.zig");
const vec8f = @import("vec8f.zig");
const vec16f = @import("vec16f.zig");

/// Compile-time check that `T` is a supported float vector wrapper type.
/// Produces a clear compile error if the caller passes an unsupported type.
fn assertF32Vec(comptime T: type) void {
    if (T != vec2f.Vec2f and T != vec4f.Vec4f and T != vec8f.Vec8f and
        T != vec16f.Vec16f)
    {
        @compileError("horizontal reduction requires an f32 vector type " ++
            "(Vec2f, Vec4f, Vec8f, or Vec16f), got: " ++ @typeName(T));
    }
}

/// Sum all lanes of a float vector.
pub inline fn sum(v: anytype) f32 {
    comptime assertF32Vec(@TypeOf(v));
    return @reduce(.Add, v.v);
}

/// Multiply all lanes of a float vector.
pub inline fn product(v: anytype) f32 {
    comptime assertF32Vec(@TypeOf(v));
    return @reduce(.Mul, v.v);
}

/// Minimum lane value.
pub inline fn min(v: anytype) f32 {
    comptime assertF32Vec(@TypeOf(v));
    return @reduce(.Min, v.v);
}

/// Maximum lane value.
pub inline fn max(v: anytype) f32 {
    comptime assertF32Vec(@TypeOf(v));
    return @reduce(.Max, v.v);
}

/// Index of the minimum lane in a Vec4f.
pub inline fn minIndex(v: vec4f.Vec4f) u2 {
    const arr = v.toArray();
    var idx: u2 = 0;
    var val: f32 = arr[0];
    inline for (1..4) |i| {
        if (arr[i] < val) {
            val = arr[i];
            idx = @intCast(i);
        }
    }
    return idx;
}

/// Index of the maximum lane in a Vec4f.
pub inline fn maxIndex(v: vec4f.Vec4f) u2 {
    const arr = v.toArray();
    var idx: u2 = 0;
    var val: f32 = arr[0];
    inline for (1..4) |i| {
        if (arr[i] > val) {
            val = arr[i];
            idx = @intCast(i);
        }
    }
    return idx;
}

/// Index of the minimum lane in a Vec8f.
pub inline fn minIndex8(v: vec8f.Vec8f) u3 {
    const arr = v.toArray();
    var idx: u3 = 0;
    var val: f32 = arr[0];
    inline for (1..8) |i| {
        if (arr[i] < val) {
            val = arr[i];
            idx = @intCast(i);
        }
    }
    return idx;
}

/// Index of the maximum lane in a Vec8f.
pub inline fn maxIndex8(v: vec8f.Vec8f) u3 {
    const arr = v.toArray();
    var idx: u3 = 0;
    var val: f32 = arr[0];
    inline for (1..8) |i| {
        if (arr[i] > val) {
            val = arr[i];
            idx = @intCast(i);
        }
    }
    return idx;
}

test "horizontal sum/product/min/max for Vec4f" {
    const v = vec4f.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });

    try testing.expectEqual(@as(f32, 10.0), sum(v));
    try testing.expectEqual(@as(f32, 24.0), product(v));
    try testing.expectEqual(@as(f32, 1.0), min(v));
    try testing.expectEqual(@as(f32, 4.0), max(v));
}

test "horizontal sum for Vec8f" {
    const v = vec8f.Vec8f.fromArray(.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expectEqual(@as(f32, 36.0), sum(v));
    try testing.expectEqual(@as(f32, 40320.0), product(v));
    try testing.expectEqual(@as(f32, 1.0), min(v));
    try testing.expectEqual(@as(f32, 8.0), max(v));
}

test "horizontal reductions support Vec2f and Vec16f" {
    const v2 = vec2f.Vec2f.init(.{ 2.0, -4.0 });
    try testing.expectEqual(@as(f32, -2.0), sum(v2));
    try testing.expectEqual(@as(f32, -8.0), product(v2));
    try testing.expectEqual(@as(f32, -4.0), min(v2));
    try testing.expectEqual(@as(f32, 2.0), max(v2));

    const v16 = vec16f.Vec16f.fromArray(.{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2 });
    try testing.expectEqual(@as(f32, 17.0), sum(v16));
    try testing.expectEqual(@as(f32, 2.0), product(v16));
    try testing.expectEqual(@as(f32, 1.0), min(v16));
    try testing.expectEqual(@as(f32, 2.0), max(v16));
}

test "minIndex/maxIndex for Vec4f" {
    const v = vec4f.Vec4f.init(.{ 5.0, 1.0, 9.0, 3.0 });
    try testing.expectEqual(@as(u2, 1), minIndex(v));
    try testing.expectEqual(@as(u2, 2), maxIndex(v));
}

test "minIndex8/maxIndex8 for Vec8f" {
    const v = vec8f.Vec8f.fromArray(.{ 5, 1, 9, 3, 2, 8, 0, 7 });
    try testing.expectEqual(@as(u3, 6), minIndex8(v));
    try testing.expectEqual(@as(u3, 2), maxIndex8(v));
}

test "minIndex and maxIndex return first match for ties" {
    const v4 = vec4f.Vec4f.init(.{ 1.0, 2.0, 1.0, 2.0 });
    try testing.expectEqual(@as(u2, 0), minIndex(v4));
    try testing.expectEqual(@as(u2, 1), maxIndex(v4));

    const v8 = vec8f.Vec8f.fromArray(.{ 3, 7, 7, 2, 2, 5, 1, 1 });
    try testing.expectEqual(@as(u3, 6), minIndex8(v8));
    try testing.expectEqual(@as(u3, 1), maxIndex8(v8));
}
