//! Bounds-checked slice load/store for SIMD vectors.
//!
//! All operations return `SimdError!T` or `SimdError!void`.
//! Bounds checks are always enabled, even in release builds,
//! because out-of-bounds SIMD access is an operating error per agents.md §3.10.

const std = @import("std");
const testing = std.testing;
const vec2f = @import("vec2f.zig");
const vec4f = @import("vec4f.zig");
const vec8f = @import("vec8f.zig");
const vec16f = @import("vec16f.zig");
const vec4d = @import("vec4d.zig");
const vec2i = @import("vec2i.zig");
const vec4i = @import("vec4i.zig");
const vec8i = @import("vec8i.zig");
const vec4u = @import("vec4u.zig");

pub const SimdError = error{IndexOutOfBounds};

// -- f32 loads/stores --

pub inline fn load2f(slice: []const f32) SimdError!vec2f.Vec2f {
    if (slice.len < 2) return error.IndexOutOfBounds;
    return vec2f.Vec2f.fromArray(slice[0..2].*);
}

pub inline fn store2f(slice: []f32, v: vec2f.Vec2f) SimdError!void {
    if (slice.len < 2) return error.IndexOutOfBounds;
    const arr = v.toArray();
    slice[0] = arr[0];
    slice[1] = arr[1];
}

pub inline fn load4f(slice: []const f32) SimdError!vec4f.Vec4f {
    if (slice.len < 4) return error.IndexOutOfBounds;
    return vec4f.Vec4f.fromArray(slice[0..4].*);
}

pub inline fn store4f(slice: []f32, v: vec4f.Vec4f) SimdError!void {
    if (slice.len < 4) return error.IndexOutOfBounds;
    const arr = v.toArray();
    inline for (0..4) |i| {
        slice[i] = arr[i];
    }
}

pub inline fn load8f(slice: []const f32) SimdError!vec8f.Vec8f {
    if (slice.len < 8) return error.IndexOutOfBounds;
    return vec8f.Vec8f.fromArray(slice[0..8].*);
}

pub inline fn store8f(slice: []f32, v: vec8f.Vec8f) SimdError!void {
    if (slice.len < 8) return error.IndexOutOfBounds;
    const arr = v.toArray();
    inline for (0..8) |i| {
        slice[i] = arr[i];
    }
}

pub inline fn load16f(slice: []const f32) SimdError!vec16f.Vec16f {
    if (slice.len < 16) return error.IndexOutOfBounds;
    return vec16f.Vec16f.fromArray(slice[0..16].*);
}

pub inline fn store16f(slice: []f32, v: vec16f.Vec16f) SimdError!void {
    if (slice.len < 16) return error.IndexOutOfBounds;
    const arr = v.toArray();
    inline for (0..16) |i| {
        slice[i] = arr[i];
    }
}

// -- f64 loads/stores --

pub inline fn load4d(slice: []const f64) SimdError!vec4d.Vec4d {
    if (slice.len < 4) return error.IndexOutOfBounds;
    return vec4d.Vec4d.fromArray(slice[0..4].*);
}

pub inline fn store4d(slice: []f64, v: vec4d.Vec4d) SimdError!void {
    if (slice.len < 4) return error.IndexOutOfBounds;
    const arr = v.toArray();
    inline for (0..4) |i| {
        slice[i] = arr[i];
    }
}

// -- i32 loads/stores --

pub inline fn load2i(slice: []const i32) SimdError!vec2i.Vec2i {
    if (slice.len < 2) return error.IndexOutOfBounds;
    return vec2i.Vec2i.fromArray(slice[0..2].*);
}

pub inline fn store2i(slice: []i32, v: vec2i.Vec2i) SimdError!void {
    if (slice.len < 2) return error.IndexOutOfBounds;
    const arr = v.toArray();
    slice[0] = arr[0];
    slice[1] = arr[1];
}

pub inline fn load4i(slice: []const i32) SimdError!vec4i.Vec4i {
    if (slice.len < 4) return error.IndexOutOfBounds;
    return vec4i.Vec4i.fromArray(slice[0..4].*);
}

pub inline fn store4i(slice: []i32, v: vec4i.Vec4i) SimdError!void {
    if (slice.len < 4) return error.IndexOutOfBounds;
    const arr = v.toArray();
    inline for (0..4) |i| {
        slice[i] = arr[i];
    }
}

pub inline fn load8i(slice: []const i32) SimdError!vec8i.Vec8i {
    if (slice.len < 8) return error.IndexOutOfBounds;
    return vec8i.Vec8i.fromArray(slice[0..8].*);
}

pub inline fn store8i(slice: []i32, v: vec8i.Vec8i) SimdError!void {
    if (slice.len < 8) return error.IndexOutOfBounds;
    const arr = v.toArray();
    inline for (0..8) |i| {
        slice[i] = arr[i];
    }
}

// -- u32 loads/stores --

pub inline fn load4u(slice: []const u32) SimdError!vec4u.Vec4u {
    if (slice.len < 4) return error.IndexOutOfBounds;
    return vec4u.Vec4u.fromArray(slice[0..4].*);
}

pub inline fn store4u(slice: []u32, v: vec4u.Vec4u) SimdError!void {
    if (slice.len < 4) return error.IndexOutOfBounds;
    const arr = v.toArray();
    inline for (0..4) |i| {
        slice[i] = arr[i];
    }
}

test "load4f/store4f roundtrip" {
    var buf = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const v = try load4f(&buf);
    const arr = v.toArray();
    try testing.expectEqual(@as(f32, 1.0), arr[0]);
    try testing.expectEqual(@as(f32, 4.0), arr[3]);

    var out = [_]f32{ 0.0, 0.0, 0.0, 0.0, 99.0 };
    try store4f(&out, v);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    try testing.expectEqual(@as(f32, 4.0), out[3]);
    // Verify store did not write beyond 4 elements.
    try testing.expectEqual(@as(f32, 99.0), out[4]);
}

test "load4f out of bounds returns error" {
    var buf = [_]f32{ 1.0, 2.0, 3.0 };
    try testing.expectError(error.IndexOutOfBounds, load4f(&buf));
}

test "store4f out of bounds returns error, no partial write" {
    var buf = [_]f32{ 99.0, 99.0 };
    const v = vec4f.Vec4f.splat(1.0);
    try testing.expectError(error.IndexOutOfBounds, store4f(&buf, v));
    // Verify no partial write occurred.
    try testing.expectEqual(@as(f32, 99.0), buf[0]);
    try testing.expectEqual(@as(f32, 99.0), buf[1]);
}

test "load4i/store4i roundtrip" {
    var buf = [_]i32{ 10, 20, 30, 40 };
    const v = try load4i(&buf);
    try testing.expectEqual(@as(i32, 10), v.toArray()[0]);

    var out = [_]i32{ 0, 0, 0, 0 };
    try store4i(&out, v);
    try testing.expectEqual(@as(i32, 40), out[3]);
}

test "load4u/store4u roundtrip" {
    var buf = [_]u32{ 100, 200, 300, 400 };
    const v = try load4u(&buf);
    try testing.expectEqual(@as(u32, 100), v.toArray()[0]);

    var out = [_]u32{ 0, 0, 0, 0 };
    try store4u(&out, v);
    try testing.expectEqual(@as(u32, 400), out[3]);
}

test "f32 load/store variants roundtrip and bounds checks" {
    const v2 = vec2f.Vec2f.init(.{ 3.0, 4.0 });
    var out2 = [_]f32{ 0.0, 0.0 };
    try store2f(&out2, v2);
    try testing.expectEqualSlices(f32, &.{ 3.0, 4.0 }, out2[0..]);
    const rt2 = try load2f(&out2);
    const rt2_arr = rt2.toArray();
    try testing.expectEqualSlices(f32, &.{ 3.0, 4.0 }, rt2_arr[0..]);
    var short2 = [_]f32{1.0};
    try testing.expectError(error.IndexOutOfBounds, load2f(&short2));
    try testing.expectError(error.IndexOutOfBounds, store2f(&short2, v2));

    const v8 = vec8f.Vec8f.fromArray(.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    var out8 = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try store8f(&out8, v8);
    try testing.expectEqual(@as(f32, 7.0), out8[7]);
    const rt8 = try load8f(&out8);
    try testing.expectEqual(@as(f32, 0.0), rt8.toArray()[0]);
    var short8 = [_]f32{ 1, 2, 3, 4, 5, 6, 7 };
    try testing.expectError(error.IndexOutOfBounds, load8f(&short8));
    try testing.expectError(error.IndexOutOfBounds, store8f(&short8, v8));

    const v16 = vec16f.Vec16f.fromArray(.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
    var out16 = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try store16f(&out16, v16);
    try testing.expectEqual(@as(f32, 15.0), out16[15]);
    const rt16 = try load16f(&out16);
    try testing.expectEqual(@as(f32, 10.0), rt16.toArray()[10]);
    var short16 = [_]f32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    try testing.expectError(error.IndexOutOfBounds, load16f(&short16));
    try testing.expectError(error.IndexOutOfBounds, store16f(&short16, v16));
}

test "f64 and i32 load/store variants roundtrip and bounds checks" {
    const v4d = vec4d.Vec4d.fromArray(.{ 1.0, 2.0, 3.0, 4.0 });
    var out4d = [_]f64{ 0.0, 0.0, 0.0, 0.0 };
    try store4d(&out4d, v4d);
    try testing.expectEqual(@as(f64, 4.0), out4d[3]);
    const rt4d = try load4d(&out4d);
    try testing.expectEqual(@as(f64, 2.0), rt4d.toArray()[1]);
    var short4d = [_]f64{ 1.0, 2.0, 3.0 };
    try testing.expectError(error.IndexOutOfBounds, load4d(&short4d));
    try testing.expectError(error.IndexOutOfBounds, store4d(&short4d, v4d));

    const v2i = vec2i.Vec2i.init(.{ -1, 2 });
    var out2i = [_]i32{ 0, 0 };
    try store2i(&out2i, v2i);
    try testing.expectEqual(@as(i32, -1), out2i[0]);
    const rt2i = try load2i(&out2i);
    try testing.expectEqual(@as(i32, 2), rt2i.toArray()[1]);
    var short2i = [_]i32{1};
    try testing.expectError(error.IndexOutOfBounds, load2i(&short2i));
    try testing.expectError(error.IndexOutOfBounds, store2i(&short2i, v2i));

    const v8i = vec8i.Vec8i.fromArray(.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    var out8i = [_]i32{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try store8i(&out8i, v8i);
    try testing.expectEqual(@as(i32, 7), out8i[7]);
    const rt8i = try load8i(&out8i);
    try testing.expectEqual(@as(i32, 5), rt8i.toArray()[5]);
    var short8i = [_]i32{ 0, 1, 2, 3, 4, 5, 6 };
    try testing.expectError(error.IndexOutOfBounds, load8i(&short8i));
    try testing.expectError(error.IndexOutOfBounds, store8i(&short8i, v8i));
}

test "store4u out of bounds returns error without mutation" {
    var short = [_]u32{ 9, 9, 9 };
    const before = short;
    try testing.expectError(error.IndexOutOfBounds, store4u(&short, vec4u.Vec4u.splat(1)));
    try testing.expectEqualSlices(u32, before[0..], short[0..]);
}
