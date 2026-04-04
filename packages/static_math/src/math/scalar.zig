//! scalar: f32 math constants and single-value helpers.
//!
//! Key exports: constants `pi`, `tau`, `e`, `epsilon`; functions `lerp`,
//! `inverseLerp`, `remap`, `clamp`, `saturate`, `smoothstep`, `smootherstep`,
//! `sign`, `fract`, `step`, `mod`, `toRadians`, `toDegrees`.
//!
//! All functions are pure, allocation-free, and inline. Thread-safe.
//! Preconditions (e.g. `a != b` for `inverseLerp`, `y != 0` for `mod`)
//! are enforced via `std.debug.assert` — programmer errors per agents.md §3.10.

const std = @import("std");

pub const pi: f32 = 3.14159265358979323846;
pub const tau: f32 = 2.0 * pi;
pub const e: f32 = 2.71828182845904523536;
pub const epsilon: f32 = 1.0e-6;

pub inline fn toRadians(deg: f32) f32 {
    return deg * (pi / 180.0);
}

pub inline fn toDegrees(rad: f32) f32 {
    return rad * (180.0 / pi);
}

/// Linear interpolation. Supports extrapolation (t outside [0,1]).
/// Uses `a + (b - a) * t` form; not endpoint-exact at t=1.
pub inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Inverse lerp: find t such that lerp(a, b, t) == v.
/// Precondition: a != b.
pub inline fn inverseLerp(a: f32, b: f32, v: f32) f32 {
    std.debug.assert(a != b);
    return (v - a) / (b - a);
}

/// Remap v from [in_min, in_max] to [out_min, out_max].
/// Precondition: in_min != in_max.
pub inline fn remap(
    v: f32,
    in_min: f32,
    in_max: f32,
    out_min: f32,
    out_max: f32,
) f32 {
    return lerp(out_min, out_max, inverseLerp(in_min, in_max, v));
}

/// Clamp val to [min_val, max_val].
/// Precondition: min_val <= max_val.
pub inline fn clamp(val: f32, min_val: f32, max_val: f32) f32 {
    std.debug.assert(min_val <= max_val);
    return @max(min_val, @min(max_val, val));
}

/// Clamp val to [0, 1].
pub inline fn saturate(val: f32) f32 {
    return clamp(val, 0.0, 1.0);
}

/// Hermite interpolation (C1 continuous).
/// Precondition: edge0 < edge1.
pub inline fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    std.debug.assert(edge0 < edge1);
    const t = saturate((x - edge0) / (edge1 - edge0));
    return t * t * (3.0 - 2.0 * t);
}

/// Perlin improved interpolation (C2 continuous).
/// Precondition: edge0 < edge1.
pub inline fn smootherstep(edge0: f32, edge1: f32, x: f32) f32 {
    std.debug.assert(edge0 < edge1);
    const t = saturate((x - edge0) / (edge1 - edge0));
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Returns -1.0, 0.0, or 1.0. NaN returns 0.0.
pub inline fn sign(x: f32) f32 {
    if (x < 0.0) return -1.0;
    if (x > 0.0) return 1.0;
    return 0.0;
}

/// Shader-style fractional part: x - floor(x). Result in [0, 1).
pub inline fn fract(x: f32) f32 {
    return x - @floor(x);
}

/// Step function: 0.0 if x < edge, else 1.0.
pub inline fn step(edge: f32, x: f32) f32 {
    return if (x < edge) 0.0 else 1.0;
}

/// Floored modulo. Result has same sign as y.
/// Precondition: y != 0.
pub inline fn mod(x: f32, y: f32) f32 {
    std.debug.assert(y != 0.0);
    return x - y * @floor(x / y);
}

test "radians/degrees roundtrip" {
    try std.testing.expectApproxEqAbs(pi, toRadians(180.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 180.0), toDegrees(pi), epsilon);
}

test "lerp at 0, 0.5, 1 and extrapolation" {
    // Uses approx comparison: the `a + (b - a) * t` form is not
    // endpoint-exact at t=1 for arbitrary inputs (see doc comment).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lerp(0.0, 10.0, 0.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), lerp(0.0, 10.0, 0.5), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), lerp(0.0, 10.0, 1.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), lerp(0.0, 10.0, -0.5), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), lerp(0.0, 10.0, 1.5), epsilon);
}

test "inverseLerp" {
    try std.testing.expectEqual(@as(f32, 0.5), inverseLerp(0.0, 10.0, 5.0));
}

test "clamp boundaries" {
    try std.testing.expectEqual(@as(f32, 0.5), clamp(0.5, 0.0, 1.0));
    try std.testing.expectEqual(@as(f32, 0.0), clamp(-1.0, 0.0, 1.0));
    try std.testing.expectEqual(@as(f32, 1.0), clamp(2.0, 0.0, 1.0));
}

test "saturate" {
    try std.testing.expectEqual(@as(f32, 0.0), saturate(-1.0));
    try std.testing.expectEqual(@as(f32, 0.5), saturate(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), saturate(2.0));
}

test "smoothstep at edges and midpoint" {
    try std.testing.expectEqual(@as(f32, 0.0), smoothstep(0.0, 1.0, 0.0));
    try std.testing.expectEqual(@as(f32, 0.5), smoothstep(0.0, 1.0, 0.5));
    try std.testing.expectEqual(@as(f32, 1.0), smoothstep(0.0, 1.0, 1.0));
}

test "sign with negative/zero/positive/NaN" {
    try std.testing.expectEqual(@as(f32, -1.0), sign(-5.0));
    try std.testing.expectEqual(@as(f32, 0.0), sign(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), sign(5.0));
    try std.testing.expectEqual(@as(f32, 0.0), sign(std.math.nan(f32)));
}

test "fract with positive/negative/integer" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), fract(3.7), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), fract(3.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), fract(-1.2), epsilon);
}

test "step" {
    try std.testing.expectEqual(@as(f32, 0.0), step(0.5, 0.0));
    try std.testing.expectEqual(@as(f32, 1.0), step(0.5, 0.5));
    try std.testing.expectEqual(@as(f32, 1.0), step(0.5, 1.0));
}

test "mod with positive/negative" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mod(11.0, 10.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), mod(-1.0, 10.0), epsilon);
}

test "remap" {
    try std.testing.expectEqual(@as(f32, 50.0), remap(5.0, 0.0, 10.0, 0.0, 100.0));
}
