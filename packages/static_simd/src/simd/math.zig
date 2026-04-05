//! Elementwise math — sqrt, rsqrt, reciprocal, FMA, clamp, lerp.
//!
//! All functions accept any float VecType via `anytype`, with comptime
//! validation that rejects unsupported types at compile time with a clear
//! error message. The `horizontal.zig` module uses the same pattern.
//!
//! Backward-compatible width-suffixed aliases are provided at the bottom so
//! existing call sites (`sqrt4f`, `lerp8f`, etc.) continue to work unchanged.
//! Treat them as a compatibility ceiling rather than a direction for adding
//! more parallel wrapper names before a real consumer asks for them.
//!
//! Thread safety: all operations are pure functions; no shared state.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const vec_type = @import("vec_type.zig");

// ---------------------------------------------------------------------------
// Comptime type validation helper
// ---------------------------------------------------------------------------

/// Asserts at comptime that `T` is one of the supported float vector types.
/// Produces a clear compile error if not.
fn assertFloatVec(comptime T: type) void {
    if (T != vec_type.Vec4f and T != vec_type.Vec8f and T != vec_type.Vec16f) {
        @compileError(
            "math operations require Vec4f, Vec8f, or Vec16f; got: " ++ @typeName(T),
        );
    }
}

/// Return the f32 vector width corresponding to type T.
fn vecLen(comptime T: type) comptime_int {
    comptime assertFloatVec(T);
    return switch (T) {
        vec_type.Vec4f => 4,
        vec_type.Vec8f => 8,
        vec_type.Vec16f => 16,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Generic operations (anytype, comptime-validated)
// ---------------------------------------------------------------------------

/// Lane-wise square root. Input must be a float VecType.
pub inline fn sqrt(a: anytype) @TypeOf(a) {
    comptime assertFloatVec(@TypeOf(a));
    return .{ .v = @sqrt(a.v) };
}

/// Full-precision reciprocal square root: 1.0 / sqrt(x).
/// Returns +Inf for zero inputs; NaN for negative inputs.
pub inline fn rsqrt(a: anytype) @TypeOf(a) {
    comptime assertFloatVec(@TypeOf(a));
    const N = comptime vecLen(@TypeOf(a));
    const one: @Vector(N, f32) = @splat(1.0);
    return .{ .v = one / @sqrt(a.v) };
}

/// Full-precision reciprocal: 1.0 / x.
/// Returns +/-Inf for zero inputs.
pub inline fn reciprocal(a: anytype) @TypeOf(a) {
    comptime assertFloatVec(@TypeOf(a));
    const N = comptime vecLen(@TypeOf(a));
    const one: @Vector(N, f32) = @splat(1.0);
    return .{ .v = one / a.v };
}

/// Fused multiply-add: a * b + c.
pub inline fn mulAdd(a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
    comptime assertFloatVec(@TypeOf(a));
    const N = comptime vecLen(@TypeOf(a));
    return .{ .v = @mulAdd(@Vector(N, f32), a.v, b.v, c.v) };
}

/// a * b - c.
pub inline fn mulSub(a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
    comptime assertFloatVec(@TypeOf(a));
    const N = comptime vecLen(@TypeOf(a));
    return .{ .v = @mulAdd(@Vector(N, f32), a.v, b.v, -c.v) };
}

/// c - a * b (negated multiply-add).
pub inline fn nmulAdd(a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
    comptime assertFloatVec(@TypeOf(a));
    const N = comptime vecLen(@TypeOf(a));
    return .{ .v = @mulAdd(@Vector(N, f32), -a.v, b.v, c.v) };
}

/// Lane-wise clamp to [min_val, max_val]. Asserts min_val <= max_val per lane.
pub inline fn clamp(v: anytype, min_val: @TypeOf(v), max_val: @TypeOf(v)) @TypeOf(v) {
    comptime assertFloatVec(@TypeOf(v));
    assert(@reduce(.And, min_val.v <= max_val.v));
    return .{ .v = @min(@max(v.v, min_val.v), max_val.v) };
}

/// Linear interpolation via FMA: a + t * (b - a).
pub inline fn lerp(a: anytype, b: @TypeOf(a), t: @TypeOf(a)) @TypeOf(a) {
    comptime assertFloatVec(@TypeOf(a));
    const N = comptime vecLen(@TypeOf(a));
    return .{ .v = @mulAdd(@Vector(N, f32), t.v, b.v - a.v, a.v) };
}

// ---------------------------------------------------------------------------
// Backward-compatible width-suffixed aliases
// ---------------------------------------------------------------------------

pub const sqrt4f = sqrt;
pub const sqrt8f = sqrt;
pub const sqrt16f = sqrt;

pub const rsqrt4f = rsqrt;
pub const rsqrt8f = rsqrt;
pub const rsqrt16f = rsqrt;

pub const reciprocal4f = reciprocal;
pub const reciprocal8f = reciprocal;
pub const reciprocal16f = reciprocal;

pub const mulAdd4f = mulAdd;
pub const mulAdd8f = mulAdd;
pub const mulAdd16f = mulAdd;

pub const mulSub4f = mulSub;
pub const mulSub8f = mulSub;
pub const mulSub16f = mulSub;

pub const nmulAdd4f = nmulAdd;
pub const nmulAdd8f = nmulAdd;
pub const nmulAdd16f = nmulAdd;

pub const clamp4f = clamp;
pub const clamp8f = clamp;
pub const clamp16f = clamp;

pub const lerp4f = lerp;
pub const lerp8f = lerp;
pub const lerp16f = lerp;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sqrt of perfect squares — Vec4f, Vec8f, Vec16f" {
    const v4 = vec_type.Vec4f.init(.{ 1.0, 4.0, 9.0, 16.0 });
    const r4 = sqrt(v4).toArray();
    try testing.expectApproxEqAbs(@as(f32, 1.0), r4[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), r4[1], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 3.0), r4[2], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 4.0), r4[3], 1.0e-6);

    const squares8 = vec_type.Vec8f.fromArray(.{ 1.0, 4.0, 9.0, 16.0, 25.0, 36.0, 49.0, 64.0 });
    const roots8 = sqrt(squares8).toArray();
    inline for (0..8) |i| {
        const expected: f32 = @floatFromInt(i + 1);
        try testing.expectApproxEqAbs(expected, roots8[i], 1.0e-6);
    }
}

test "rsqrt identity: rsqrt(x) * sqrt(x) ≈ 1 — Vec4f" {
    const v = vec_type.Vec4f.init(.{ 1.0, 4.0, 9.0, 16.0 });
    const rs = rsqrt(v);
    const s = sqrt(v);
    const prod = vec_type.Vec4f.mul(rs, s).toArray();
    for (prod) |p| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), p, 1.0e-5);
    }
}

test "mulAdd against manual a*b+c — Vec4f" {
    const a = vec_type.Vec4f.init(.{ 2.0, 3.0, 4.0, 5.0 });
    const b = vec_type.Vec4f.init(.{ 10.0, 10.0, 10.0, 10.0 });
    const c = vec_type.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });

    const result = mulAdd(a, b, c).toArray();
    try testing.expectApproxEqAbs(@as(f32, 21.0), result[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 32.0), result[1], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 43.0), result[2], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 54.0), result[3], 1.0e-6);
}

test "clamp boundary cases — Vec4f" {
    const v = vec_type.Vec4f.init(.{ -1.0, 0.5, 1.5, 0.0 });
    const lo = vec_type.Vec4f.splat(0.0);
    const hi = vec_type.Vec4f.splat(1.0);
    const result = clamp(v, lo, hi).toArray();

    try testing.expectEqual(@as(f32, 0.0), result[0]);
    try testing.expectEqual(@as(f32, 0.5), result[1]);
    try testing.expectEqual(@as(f32, 1.0), result[2]);
    try testing.expectEqual(@as(f32, 0.0), result[3]);
}

test "lerp at t=0, 0.5, 1 — Vec4f" {
    const a = vec_type.Vec4f.splat(0.0);
    const b = vec_type.Vec4f.splat(10.0);

    const at_zero = lerp(a, b, vec_type.Vec4f.splat(0.0)).toArray();
    try testing.expectApproxEqAbs(@as(f32, 0.0), at_zero[0], 1.0e-6);

    const at_half = lerp(a, b, vec_type.Vec4f.splat(0.5)).toArray();
    try testing.expectApproxEqAbs(@as(f32, 5.0), at_half[0], 1.0e-6);

    const at_one = lerp(a, b, vec_type.Vec4f.splat(1.0)).toArray();
    try testing.expectApproxEqAbs(@as(f32, 10.0), at_one[0], 1.0e-6);
}

test "mulSub and nmulAdd against manual formulas — Vec4f" {
    const a = vec_type.Vec4f.init(.{ 2.0, 3.0, 4.0, 5.0 });
    const b = vec_type.Vec4f.init(.{ 10.0, 10.0, 10.0, 10.0 });
    const c = vec_type.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });

    const sub = mulSub(a, b, c).toArray();
    try testing.expectApproxEqAbs(@as(f32, 19.0), sub[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 28.0), sub[1], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 37.0), sub[2], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 46.0), sub[3], 1.0e-6);

    const nma = nmulAdd(a, b, c).toArray();
    try testing.expectApproxEqAbs(@as(f32, -19.0), nma[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, -28.0), nma[1], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, -37.0), nma[2], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, -46.0), nma[3], 1.0e-6);
}

test "reciprocal and rsqrt special values follow IEEE behaviour — Vec4f" {
    const recip = reciprocal(vec_type.Vec4f.init(.{ 1.0, -2.0, 0.0, -0.0 })).toArray();
    try testing.expectApproxEqAbs(@as(f32, 1.0), recip[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), recip[1], 1.0e-6);
    try testing.expect(std.math.isInf(recip[2]));
    try testing.expect(!std.math.signbit(recip[2]));
    try testing.expect(std.math.isInf(recip[3]));
    try testing.expect(std.math.signbit(recip[3]));

    const rs = rsqrt(vec_type.Vec4f.init(.{ 1.0, 4.0, 0.0, -1.0 })).toArray();
    try testing.expectApproxEqAbs(@as(f32, 1.0), rs[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rs[1], 1.0e-6);
    try testing.expect(std.math.isInf(rs[2]));
    try testing.expect(!std.math.signbit(rs[2]));
    try testing.expect(std.math.isNan(rs[3]));
}

test "8-lane math functions produce expected outputs" {
    const a = vec_type.Vec8f.fromArray(.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    const b = vec_type.Vec8f.splat(10.0);
    const t = vec_type.Vec8f.splat(0.5);
    const lerped = lerp(a, b, t).toArray();
    try testing.expectApproxEqAbs(@as(f32, 5.0), lerped[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 8.5), lerped[7], 1.0e-6);
}

test "16-lane math functions produce expected outputs" {
    const a = vec_type.Vec16f.fromArray(.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
    const two = vec_type.Vec16f.splat(2.0);
    const one = vec_type.Vec16f.splat(1.0);

    const fma = mulAdd(a, two, one).toArray();
    inline for (0..16) |i| {
        const ai: f32 = @floatFromInt(i);
        try testing.expectApproxEqAbs(2.0 * ai + 1.0, fma[i], 1.0e-6);
    }

    const clamped = clamp(
        vec_type.Vec16f.fromArray(.{ -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }),
        vec_type.Vec16f.splat(0.0),
        vec_type.Vec16f.splat(10.0),
    ).toArray();
    try testing.expectEqual(@as(f32, 0.0), clamped[0]);
    try testing.expectEqual(@as(f32, 10.0), clamped[15]);
}

// Backward-compat alias smoke test: ensure the old names still compile and produce correct results.
test "backward-compat aliases sqrt4f/lerp8f still work" {
    const v4 = vec_type.Vec4f.init(.{ 1.0, 4.0, 9.0, 16.0 });
    const r4 = sqrt4f(v4).toArray();
    try testing.expectApproxEqAbs(@as(f32, 1.0), r4[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 4.0), r4[3], 1.0e-6);

    const a8 = vec_type.Vec8f.splat(0.0);
    const b8 = vec_type.Vec8f.splat(10.0);
    const t8 = vec_type.Vec8f.splat(0.5);
    const l8 = lerp8f(a8, b8, t8).toArray();
    try testing.expectApproxEqAbs(@as(f32, 5.0), l8[0], 1.0e-6);
}
