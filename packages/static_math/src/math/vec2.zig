//! Vec2: 2-component 32-bit float vector.
//!
//! Key operations: `add`, `sub`, `dot`, `cross`, `normalize`, `lerp`,
//! `rotate`, `perpendicular`.
//!
//! Stored as an `extern struct` with `f32` components for GPU/C ABI interop.
//! Column-major convention is not applicable to Vec2; coordinates are
//! interpreted by the caller (e.g. screen-space vs world-space).
//! All operations are pure functions (no mutation). Thread-safe.
//! Preconditions (non-zero divisors, non-zero inputs to `angle`) are
//! enforced via `std.debug.assert` — programmer errors per agents.md §3.10.1.

const std = @import("std");
const assert = std.debug.assert;
const scalar = @import("scalar.zig");

pub const Vec2 = extern struct {
    x: f32,
    y: f32,

    comptime {
        // Compile-time invariant: extern struct must be exactly 2 floats.
        assert(@sizeOf(Vec2) == 2 * @sizeOf(f32));
    }

    // ── Constants ────────────────────────────────────────────────────

    pub const zero = Vec2{ .x = 0.0, .y = 0.0 };
    pub const one = Vec2{ .x = 1.0, .y = 1.0 };
    pub const unit_x = Vec2{ .x = 1.0, .y = 0.0 };
    pub const unit_y = Vec2{ .x = 0.0, .y = 1.0 };

    // ── Construction ─────────────────────────────────────────────────

    pub inline fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub inline fn splat(v: f32) Vec2 {
        return .{ .x = v, .y = v };
    }

    pub inline fn fromArray(a: [2]f32) Vec2 {
        return .{ .x = a[0], .y = a[1] };
    }

    pub inline fn toArray(self: Vec2) [2]f32 {
        return .{ self.x, self.y };
    }

    // ── Arithmetic ───────────────────────────────────────────────────

    pub inline fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub inline fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub inline fn mul(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x * b.x, .y = a.y * b.y };
    }

    pub inline fn div(a: Vec2, b: Vec2) Vec2 {
        assert(b.x != 0.0);
        assert(b.y != 0.0);
        return .{ .x = a.x / b.x, .y = a.y / b.y };
    }

    pub inline fn scale(v: Vec2, s: f32) Vec2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }

    pub inline fn neg(v: Vec2) Vec2 {
        return .{ .x = -v.x, .y = -v.y };
    }

    // ── Geometry ─────────────────────────────────────────────────────

    pub inline fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    /// 2D cross product: returns the z-component of the 3D cross product.
    pub inline fn cross(a: Vec2, b: Vec2) f32 {
        return a.x * b.y - a.y * b.x;
    }

    pub inline fn lengthSq(v: Vec2) f32 {
        return dot(v, v);
    }

    pub inline fn length(v: Vec2) f32 {
        return @sqrt(lengthSq(v));
    }

    /// Returns the unit vector. If the input is zero-length, returns
    /// `Vec2.zero` instead of producing NaN.
    pub inline fn normalize(v: Vec2) Vec2 {
        const len = length(v);
        if (len == 0.0) return zero;
        const inv = 1.0 / len;
        return .{ .x = v.x * inv, .y = v.y * inv };
    }

    /// Non-asserting normalize for boundary-facing code. Returns `null`
    /// for zero-length input instead of silently returning `Vec2.zero`.
    pub inline fn tryNormalize(v: Vec2) ?Vec2 {
        const len = length(v);
        if (len == 0.0) return null;
        const inv = 1.0 / len;
        return .{ .x = v.x * inv, .y = v.y * inv };
    }

    pub inline fn distance(a: Vec2, b: Vec2) f32 {
        return length(sub(a, b));
    }

    pub inline fn distanceSq(a: Vec2, b: Vec2) f32 {
        return lengthSq(sub(a, b));
    }

    // ── Interpolation ────────────────────────────────────────────────

    pub inline fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{
            .x = scalar.lerp(a.x, b.x, t),
            .y = scalar.lerp(a.y, b.y, t),
        };
    }

    // ── Component-wise ───────────────────────────────────────────────

    pub inline fn min(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) };
    }

    pub inline fn max(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) };
    }

    pub inline fn clamp(v: Vec2, lo: Vec2, hi: Vec2) Vec2 {
        return .{
            .x = scalar.clamp(v.x, lo.x, hi.x),
            .y = scalar.clamp(v.y, lo.y, hi.y),
        };
    }

    pub inline fn abs(v: Vec2) Vec2 {
        return .{ .x = @abs(v.x), .y = @abs(v.y) };
    }

    // ── Comparison ───────────────────────────────────────────────────

    pub inline fn approxEqual(a: Vec2, b: Vec2, tolerance: f32) bool {
        assert(tolerance >= 0.0);
        return @abs(a.x - b.x) <= tolerance and
            @abs(a.y - b.y) <= tolerance;
    }

    // ── 2D-specific ──────────────────────────────────────────────────

    /// 90-degree counter-clockwise rotation: returns {-y, x}.
    pub inline fn perpendicular(v: Vec2) Vec2 {
        return .{ .x = -v.y, .y = v.x };
    }

    /// Rotate `v` by `angle_rad` radians (counter-clockwise).
    pub inline fn rotate(v: Vec2, angle_rad: f32) Vec2 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return .{
            .x = v.x * c - v.y * s,
            .y = v.x * s + v.y * c,
        };
    }

    /// Angle in radians between two vectors.
    /// Precondition: both vectors must be non-zero.
    pub inline fn angle(a: Vec2, b: Vec2) f32 {
        const len_a = length(a);
        const len_b = length(b);
        assert(len_a > 0.0);
        assert(len_b > 0.0);
        const d = dot(a, b) / (len_a * len_b);
        return std.math.acos(scalar.clamp(d, -1.0, 1.0));
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;
const eps = scalar.epsilon;

test "Vec2 basic arithmetic" {
    const a = Vec2.init(1.0, 2.0);
    const b = Vec2.init(3.0, 4.0);

    const sum = Vec2.add(a, b);
    try testing.expectApproxEqAbs(@as(f32, 4.0), sum.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 6.0), sum.y, eps);

    const diff = Vec2.sub(a, b);
    try testing.expectApproxEqAbs(@as(f32, -2.0), diff.x, eps);
    try testing.expectApproxEqAbs(@as(f32, -2.0), diff.y, eps);

    const prod = Vec2.mul(a, b);
    try testing.expectApproxEqAbs(@as(f32, 3.0), prod.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 8.0), prod.y, eps);

    const quot = Vec2.div(a, b);
    try testing.expectApproxEqAbs(1.0 / 3.0, quot.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.5), quot.y, eps);

    const scaled = Vec2.scale(a, 3.0);
    try testing.expectApproxEqAbs(@as(f32, 3.0), scaled.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 6.0), scaled.y, eps);

    const negated = Vec2.neg(a);
    try testing.expectApproxEqAbs(@as(f32, -1.0), negated.x, eps);
    try testing.expectApproxEqAbs(@as(f32, -2.0), negated.y, eps);
}

test "Vec2 geometry" {
    const a = Vec2.init(3.0, 4.0);
    const b = Vec2.init(1.0, 0.0);

    try testing.expectApproxEqAbs(@as(f32, 3.0), Vec2.dot(a, b), eps);
    try testing.expectApproxEqAbs(@as(f32, -4.0), Vec2.cross(a, b), eps);
    try testing.expectApproxEqAbs(@as(f32, 25.0), Vec2.lengthSq(a), eps);
    try testing.expectApproxEqAbs(@as(f32, 5.0), Vec2.length(a), eps);

    const c = Vec2.init(6.0, 8.0);
    try testing.expectApproxEqAbs(@as(f32, 5.0), Vec2.distance(a, c), eps);
    try testing.expectApproxEqAbs(@as(f32, 25.0), Vec2.distanceSq(a, c), eps);
}

test "Vec2 normalize" {
    const v = Vec2.init(3.0, 4.0);
    const n = Vec2.normalize(v);
    try testing.expectApproxEqAbs(@as(f32, 0.6), n.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.8), n.y, eps);
    try testing.expectApproxEqAbs(@as(f32, 1.0), Vec2.length(n), eps);

    const z = Vec2.normalize(Vec2.zero);
    try testing.expectApproxEqAbs(@as(f32, 0.0), z.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.0), z.y, eps);
}

test "Vec2 perpendicular and cross" {
    const v = Vec2.init(1.0, 2.0);
    const p = Vec2.perpendicular(v);
    try testing.expectApproxEqAbs(@as(f32, -2.0), p.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 1.0), p.y, eps);

    // perpendicular is orthogonal
    try testing.expectApproxEqAbs(@as(f32, 0.0), Vec2.dot(v, p), eps);

    // cross(v, perp(v)) == lengthSq(v) for CCW perpendicular
    try testing.expectApproxEqAbs(Vec2.lengthSq(v), Vec2.cross(v, p), eps);
}

test "Vec2 approxEqual" {
    const a = Vec2.init(1.0, 2.0);
    const b = Vec2.init(1.0, 2.0);
    const c = Vec2.init(1.1, 2.0);

    try testing.expect(Vec2.approxEqual(a, b, eps));
    try testing.expect(!Vec2.approxEqual(a, c, eps));
    try testing.expect(Vec2.approxEqual(a, c, 0.2));
}

test "Vec2 fromArray/toArray roundtrip" {
    const arr = [2]f32{ 5.0, 7.0 };
    const v = Vec2.fromArray(arr);
    try testing.expectApproxEqAbs(@as(f32, 5.0), v.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 7.0), v.y, eps);

    const out = v.toArray();
    try testing.expectApproxEqAbs(arr[0], out[0], eps);
    try testing.expectApproxEqAbs(arr[1], out[1], eps);
}

test "Vec2 lerp" {
    const a = Vec2.init(0.0, 0.0);
    const b = Vec2.init(10.0, 20.0);

    const at0 = Vec2.lerp(a, b, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), at0.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.0), at0.y, eps);

    const at_half = Vec2.lerp(a, b, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 5.0), at_half.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 10.0), at_half.y, eps);

    const at1 = Vec2.lerp(a, b, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 10.0), at1.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 20.0), at1.y, eps);
}

test "Vec2 rotate" {
    const v = Vec2.init(1.0, 0.0);
    const rotated = Vec2.rotate(v, scalar.pi / 2.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), rotated.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 1.0), rotated.y, eps);

    // Full 180-degree rotation.
    const r180 = Vec2.rotate(v, scalar.pi);
    try testing.expectApproxEqAbs(@as(f32, -1.0), r180.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.0), r180.y, eps);
}
