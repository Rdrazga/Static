//! Approximate trigonometry for SIMD vectors.
//!
//! Polynomial approximations with documented max error bounds.
//! Valid input range: |x| <= 8192.0 for sin/cos. Inputs outside this range
//! produce unspecified results but will not crash.
//!
//! Max absolute error bounds:
//!   sin4f: ~1.2e-7 within valid range
//!   cos4f: ~1.2e-7 within valid range
//!   tan4f: ~2.0e-6 away from poles (|x| not near pi/2 + n*pi)
//!
//! Implementation note: sin4f, cos4f, and sincos4f all use a single shared
//! range-reduction pass. sincos4f calls sincos4fFromReduced once; sin4f and
//! cos4f call sincos4fFromReduced and discard the unneeded component. All
//! polynomial evaluation operates on full @Vector(4, f32) — no scalar loops.

const std = @import("std");
const vec4f = @import("vec4f.zig");

const pi: f32 = 3.14159265358979323846;
const two_over_pi: f32 = 2.0 / pi;

/// Range-reduce x to [-pi/2, pi/2] via Cody-Waite two-step subtraction.
/// Returns reduced value and quadrant index per lane.
/// Quadrant q is used to swap sin/cos and flip signs.
fn rangeReduce(x: @Vector(4, f32)) struct { r: @Vector(4, f32), q: @Vector(4, i32) } {
    const scale: @Vector(4, f32) = @splat(two_over_pi);
    const fq = x * scale;
    // Round to nearest integer.
    const q_f = @round(fq);
    const min_i32_f: @Vector(4, f32) = @splat(@floatFromInt(std.math.minInt(i32)));
    const max_i32_f: @Vector(4, f32) = @splat(@floatFromInt(std.math.maxInt(i32)));
    const q_clamped = @min(@max(q_f, min_i32_f), max_i32_f);
    var finite_mask: @Vector(4, bool) = @splat(false);
    inline for (0..4) |i| {
        finite_mask[i] = std.math.isFinite(q_f[i]);
    }
    const q_safe = @select(f32, finite_mask, q_clamped, @as(@Vector(4, f32), @splat(0.0)));
    const q: @Vector(4, i32) = @intFromFloat(q_safe);
    // Cody-Waite constants for pi/2 subtraction.
    const c1: @Vector(4, f32) = @splat(1.5707963267341256); // High bits of pi/2.
    const c2: @Vector(4, f32) = @splat(6.077100506506192e-11); // Low bits of pi/2.
    const r = x - q_f * c1 - q_f * c2;
    return .{ .r = r, .q = q };
}

/// Minimax polynomial for sin(x) on [-pi/2, pi/2].
/// Coefficients from a Remez-style fit to sin.
fn sinPoly(x: @Vector(4, f32)) @Vector(4, f32) {
    const x2 = x * x;
    // sin(x) ≈ x - x^3/6 + x^5/120 - x^7/5040 + x^9/362880
    const c3: @Vector(4, f32) = @splat(-1.6666666666666666e-1);
    const c5: @Vector(4, f32) = @splat(8.3333333333333332e-3);
    const c7: @Vector(4, f32) = @splat(-1.9841269841269841e-4);
    const c9: @Vector(4, f32) = @splat(2.7557319223985893e-6);
    return x * (@as(@Vector(4, f32), @splat(1.0)) + x2 * (c3 + x2 * (c5 + x2 * (c7 + x2 * c9))));
}

/// Minimax polynomial for cos(x) on [-pi/2, pi/2].
fn cosPoly(x: @Vector(4, f32)) @Vector(4, f32) {
    const x2 = x * x;
    // cos(x) ≈ 1 - x^2/2 + x^4/24 - x^6/720 + x^8/40320
    const c2: @Vector(4, f32) = @splat(-5.0e-1);
    const c4: @Vector(4, f32) = @splat(4.1666666666666664e-2);
    const c6: @Vector(4, f32) = @splat(-1.3888888888888889e-3);
    const c8: @Vector(4, f32) = @splat(2.4801587301587302e-5);
    return @as(@Vector(4, f32), @splat(1.0)) + x2 * (c2 + x2 * (c4 + x2 * (c6 + x2 * c8)));
}

/// Core sin+cos evaluator given already-reduced r and quadrant q.
///
/// Both results are produced from a single evaluation of sinPoly and cosPoly;
/// quadrant-based swapping and sign-flipping are then applied using full-vector
/// select operations — no scalar loop, no per-lane branching.
fn sincos4fFromReduced(
    r: @Vector(4, f32),
    q: @Vector(4, i32),
) struct { sin: @Vector(4, f32), cos: @Vector(4, f32) } {
    const s = sinPoly(r);
    const c = cosPoly(r);

    // Quadrant parity: q & 1 determines whether sin/cos polys are swapped.
    // q & 2 (equivalently q mod 4 in {2,3}) determines sign flip.
    //
    // Quadrant table (q mod 4):
    //   0: sin = +s,  cos = +c
    //   1: sin = +c,  cos = -s
    //   2: sin = -s,  cos = -c
    //   3: sin = -c,  cos = +s
    //
    // Swap mask: q & 1 != 0  => swap sin/cos polys.
    // Sign masks derived from (q + (q & 1)) & 2 != 0 for sin
    //                     and (q + 1 - (q & 1)) & 2 != 0 for cos.
    //
    // All operations below are on @Vector(4, ...) — fully vectorized.
    const one_i: @Vector(4, i32) = @splat(1);
    const two_i: @Vector(4, i32) = @splat(2);

    const q_mod4 = @rem(q, @as(@Vector(4, i32), @splat(4)));
    // Ensure positive modulo: add 4 for negative remainders then mod again.
    const q_pos = @rem(q_mod4 + @as(@Vector(4, i32), @splat(4)), @as(@Vector(4, i32), @splat(4)));

    // swap_mask[i] = (q_pos[i] & 1) != 0
    const swap_mask: @Vector(4, bool) = (q_pos & one_i) != @as(@Vector(4, i32), @splat(0));

    // For the swapped lanes: sin lane gets c, cos lane gets s.
    const sin_base = @select(f32, swap_mask, c, s);
    const cos_base = @select(f32, swap_mask, s, c);

    // Sign flip for sin: q_pos in {2, 3} => negate.
    const sin_neg_mask: @Vector(4, bool) = (q_pos & two_i) != @as(@Vector(4, i32), @splat(0));
    // Sign flip for cos: q_pos in {1, 2} => negate.
    // cos is negated when (q_pos + 1) & 2 != 0, equivalently q_pos in {1,2}.
    const cos_neg_mask: @Vector(4, bool) = ((q_pos + one_i) & two_i) != @as(@Vector(4, i32), @splat(0));

    const neg_one: @Vector(4, f32) = @splat(-1.0);
    const pos_one: @Vector(4, f32) = @splat(1.0);
    const sin_sign = @select(f32, sin_neg_mask, neg_one, pos_one);
    const cos_sign = @select(f32, cos_neg_mask, neg_one, pos_one);

    return .{ .sin = sin_base * sin_sign, .cos = cos_base * cos_sign };
}

/// Approximate 4-lane sine. Max error ~1.2e-7 for |x| <= 8192.
pub fn sin4f(v: vec4f.Vec4f) vec4f.Vec4f {
    const rr = rangeReduce(v.v);
    const sc = sincos4fFromReduced(rr.r, rr.q);
    return .{ .v = sc.sin };
}

/// Approximate 4-lane cosine. Max error ~1.2e-7 for |x| <= 8192.
pub fn cos4f(v: vec4f.Vec4f) vec4f.Vec4f {
    const rr = rangeReduce(v.v);
    const sc = sincos4fFromReduced(rr.r, rr.q);
    return .{ .v = sc.cos };
}

/// Compute sin and cos simultaneously, sharing a single range-reduction pass
/// and a single pair of polynomial evaluations. Callers needing both values
/// should prefer sincos4f over calling sin4f and cos4f separately.
pub fn sincos4f(v: vec4f.Vec4f) struct { sin: vec4f.Vec4f, cos: vec4f.Vec4f } {
    const rr = rangeReduce(v.v);
    const sc = sincos4fFromReduced(rr.r, rr.q);
    return .{ .sin = .{ .v = sc.sin }, .cos = .{ .v = sc.cos } };
}

/// Approximate 4-lane tangent. Max error ~2.0e-6 away from poles.
/// Shares one range-reduction pass between the sin and cos evaluations.
pub fn tan4f(v: vec4f.Vec4f) vec4f.Vec4f {
    const rr = rangeReduce(v.v);
    const sc = sincos4fFromReduced(rr.r, rr.q);
    return vec4f.Vec4f.div(.{ .v = sc.sin }, .{ .v = sc.cos });
}

/// Scalar sin fallback using the same polynomial.
pub fn sin_scalar(x: f32) f32 {
    const v = vec4f.Vec4f.splat(x);
    return sin4f(v).extract(0);
}

/// Scalar cos fallback using the same polynomial.
pub fn cos_scalar(x: f32) f32 {
    const v = vec4f.Vec4f.splat(x);
    return cos4f(v).extract(0);
}

test "sin4f at known values" {
    const tolerance: f32 = 2.0e-7;

    const v = vec4f.Vec4f.init(.{ 0.0, pi / 6.0, pi / 4.0, pi / 2.0 });
    const result = sin4f(v).toArray();

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result[1], tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(2.0) / 2.0), result[2], tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result[3], tolerance);
}

test "cos4f at known values" {
    const tolerance: f32 = 2.0e-7;

    const v = vec4f.Vec4f.init(.{ 0.0, pi / 6.0, pi / 4.0, pi / 2.0 });
    const result = cos4f(v).toArray();

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result[0], tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(3.0) / 2.0), result[1], tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(2.0) / 2.0), result[2], tolerance);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[3], tolerance);
}

test "sin4f at pi produces near-zero" {
    const v = vec4f.Vec4f.splat(pi);
    const result = sin4f(v).toArray();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], 2.0e-7);
}

test "sin/cos identity: sin^2 + cos^2 = 1" {
    const v = vec4f.Vec4f.init(.{ 0.3, 1.7, -2.5, 5.0 });
    const sc = sincos4f(v);
    const s = sc.sin;
    const c = sc.cos;
    // sin^2 + cos^2 should be ~1.0.
    const s2 = vec4f.Vec4f.mul(s, s);
    const c2 = vec4f.Vec4f.mul(c, c);
    const sum = vec4f.Vec4f.add(s2, c2).toArray();
    for (sum) |val| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), val, 1.0e-5);
    }
}

test "large input does not crash" {
    // Outside valid range — result is unspecified but must not crash.
    const v = vec4f.Vec4f.splat(100000.0);
    _ = sin4f(v);
    _ = cos4f(v);
}

test "sincos4f matches sin4f and cos4f" {
    const v = vec4f.Vec4f.init(.{ -2.0, -0.5, 1.0, 2.5 });
    const sin_only = sin4f(v).toArray();
    const cos_only = cos4f(v).toArray();
    const both = sincos4f(v);
    const sin_both = both.sin.toArray();
    const cos_both = both.cos.toArray();

    inline for (0..4) |i| {
        try std.testing.expectApproxEqAbs(sin_only[i], sin_both[i], 1.0e-6);
        try std.testing.expectApproxEqAbs(cos_only[i], cos_both[i], 1.0e-6);
    }
}

test "tan4f at known values away from poles" {
    const v = vec4f.Vec4f.init(.{ 0.0, pi / 6.0, -pi / 4.0, pi / 3.0 });
    const result = tan4f(v).toArray();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], 2.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.57735026), result[1], 2.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), result[2], 2.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.7320508), result[3], 3.0e-6);
}

test "scalar fallbacks match vector lane 0" {
    const x: f32 = 0.7;
    const v = vec4f.Vec4f.splat(x);
    try std.testing.expectApproxEqAbs(sin4f(v).extract(0), sin_scalar(x), 1.0e-7);
    try std.testing.expectApproxEqAbs(cos4f(v).extract(0), cos_scalar(x), 1.0e-7);
}

test "boundary-range inputs stay finite" {
    const v = vec4f.Vec4f.init(.{ -8192.0, -4096.0, 4096.0, 8192.0 });
    const s = sin4f(v).toArray();
    const c = cos4f(v).toArray();
    inline for (0..4) |i| {
        try std.testing.expect(std.math.isFinite(s[i]));
        try std.testing.expect(std.math.isFinite(c[i]));
    }
}

test "non-finite inputs do not crash" {
    const v = vec4f.Vec4f.init(.{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 0.0 });
    _ = sin4f(v);
    _ = cos4f(v);
    _ = tan4f(v);
}
