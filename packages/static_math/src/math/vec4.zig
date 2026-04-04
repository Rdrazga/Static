//! Vec4: 4-component 32-bit float vector.
//!
//! Key operations: `add`, `sub`, `dot`, `normalize`, `lerp`, `xyz`, `xy`.
//!
//! Stored as an `extern struct` for GPU/C ABI interop. Used as homogeneous
//! coordinates (w=1 for points, w=0 for directions) by Mat4 operations.
//! All operations are pure functions (no mutation). Thread-safe.
//! Preconditions (non-zero divisors) are enforced via `std.debug.assert`
//! — programmer errors per agents.md §3.10.1.

const std = @import("std");
const scalar = @import("scalar.zig");
const vec2_mod = @import("vec2.zig");
const vec3_mod = @import("vec3.zig");

pub const Vec4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    comptime {
        // Compile-time invariant: extern struct must be exactly 4 floats.
        std.debug.assert(@sizeOf(Vec4) == 4 * @sizeOf(f32));
    }

    // ── Constants ────────────────────────────────────────────────────

    pub const zero = Vec4{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.0 };
    pub const one = Vec4{ .x = 1.0, .y = 1.0, .z = 1.0, .w = 1.0 };

    // ── Construction ─────────────────────────────────────────────────

    pub inline fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub inline fn splat(v: f32) Vec4 {
        return .{ .x = v, .y = v, .z = v, .w = v };
    }

    pub inline fn fromVec3(v3: vec3_mod.Vec3, w_val: f32) Vec4 {
        return .{ .x = v3.x, .y = v3.y, .z = v3.z, .w = w_val };
    }

    pub inline fn fromArray(a: [4]f32) Vec4 {
        return .{ .x = a[0], .y = a[1], .z = a[2], .w = a[3] };
    }

    pub inline fn toArray(self: Vec4) [4]f32 {
        return .{ self.x, self.y, self.z, self.w };
    }

    // ── Arithmetic ───────────────────────────────────────────────────

    pub inline fn add(a: Vec4, b: Vec4) Vec4 {
        return .{
            .x = a.x + b.x,
            .y = a.y + b.y,
            .z = a.z + b.z,
            .w = a.w + b.w,
        };
    }

    pub inline fn sub(a: Vec4, b: Vec4) Vec4 {
        return .{
            .x = a.x - b.x,
            .y = a.y - b.y,
            .z = a.z - b.z,
            .w = a.w - b.w,
        };
    }

    pub inline fn mul(a: Vec4, b: Vec4) Vec4 {
        return .{
            .x = a.x * b.x,
            .y = a.y * b.y,
            .z = a.z * b.z,
            .w = a.w * b.w,
        };
    }

    pub inline fn div(a: Vec4, b: Vec4) Vec4 {
        std.debug.assert(b.x != 0.0);
        std.debug.assert(b.y != 0.0);
        std.debug.assert(b.z != 0.0);
        std.debug.assert(b.w != 0.0);
        return .{
            .x = a.x / b.x,
            .y = a.y / b.y,
            .z = a.z / b.z,
            .w = a.w / b.w,
        };
    }

    pub inline fn scale(v: Vec4, s: f32) Vec4 {
        return .{
            .x = v.x * s,
            .y = v.y * s,
            .z = v.z * s,
            .w = v.w * s,
        };
    }

    pub inline fn neg(v: Vec4) Vec4 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z, .w = -v.w };
    }

    // ── Geometry ─────────────────────────────────────────────────────

    pub inline fn dot(a: Vec4, b: Vec4) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }

    pub inline fn lengthSq(v: Vec4) f32 {
        return dot(v, v);
    }

    pub inline fn length(v: Vec4) f32 {
        return @sqrt(lengthSq(v));
    }

    /// Normalize the vector to unit length.
    /// Returns zero for zero-length vectors.
    pub inline fn normalize(v: Vec4) Vec4 {
        const len = length(v);
        if (len == 0.0) return zero;
        const inv = 1.0 / len;
        return scale(v, inv);
    }

    /// Non-asserting normalize for boundary-facing code. Returns `null`
    /// for zero-length input instead of silently returning `Vec4.zero`.
    pub inline fn tryNormalize(v: Vec4) ?Vec4 {
        const len = length(v);
        if (len == 0.0) return null;
        const inv = 1.0 / len;
        return scale(v, inv);
    }

    // ── Interpolation ────────────────────────────────────────────────

    pub inline fn lerp(a: Vec4, b: Vec4, t: f32) Vec4 {
        return .{
            .x = scalar.lerp(a.x, b.x, t),
            .y = scalar.lerp(a.y, b.y, t),
            .z = scalar.lerp(a.z, b.z, t),
            .w = scalar.lerp(a.w, b.w, t),
        };
    }

    // ── Component-wise ───────────────────────────────────────────────

    pub inline fn min(a: Vec4, b: Vec4) Vec4 {
        return .{
            .x = @min(a.x, b.x),
            .y = @min(a.y, b.y),
            .z = @min(a.z, b.z),
            .w = @min(a.w, b.w),
        };
    }

    pub inline fn max(a: Vec4, b: Vec4) Vec4 {
        return .{
            .x = @max(a.x, b.x),
            .y = @max(a.y, b.y),
            .z = @max(a.z, b.z),
            .w = @max(a.w, b.w),
        };
    }

    pub inline fn clamp(v: Vec4, min_v: Vec4, max_v: Vec4) Vec4 {
        return .{
            .x = scalar.clamp(v.x, min_v.x, max_v.x),
            .y = scalar.clamp(v.y, min_v.y, max_v.y),
            .z = scalar.clamp(v.z, min_v.z, max_v.z),
            .w = scalar.clamp(v.w, min_v.w, max_v.w),
        };
    }

    pub inline fn abs(v: Vec4) Vec4 {
        return .{
            .x = @abs(v.x),
            .y = @abs(v.y),
            .z = @abs(v.z),
            .w = @abs(v.w),
        };
    }

    // ── Comparison ───────────────────────────────────────────────────

    pub inline fn approxEqual(a: Vec4, b: Vec4, tolerance: f32) bool {
        std.debug.assert(tolerance >= 0.0);
        return @abs(a.x - b.x) <= tolerance and
            @abs(a.y - b.y) <= tolerance and
            @abs(a.z - b.z) <= tolerance and
            @abs(a.w - b.w) <= tolerance;
    }

    // ── Projection / Swizzle ─────────────────────────────────────────

    pub inline fn xyz(self: Vec4) vec3_mod.Vec3 {
        return .{ .x = self.x, .y = self.y, .z = self.z };
    }

    pub inline fn xy(self: Vec4) vec2_mod.Vec2 {
        return .{ .x = self.x, .y = self.y };
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const eps = scalar.epsilon;
const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "Vec4 basic arithmetic" {
    const a = Vec4.init(1.0, 2.0, 3.0, 4.0);
    const b = Vec4.init(5.0, 6.0, 7.0, 8.0);

    const sum = Vec4.add(a, b);
    try expectApprox(sum.x, 6.0, eps);
    try expectApprox(sum.y, 8.0, eps);
    try expectApprox(sum.z, 10.0, eps);
    try expectApprox(sum.w, 12.0, eps);

    const diff = Vec4.sub(b, a);
    try expectApprox(diff.x, 4.0, eps);
    try expectApprox(diff.y, 4.0, eps);
    try expectApprox(diff.z, 4.0, eps);
    try expectApprox(diff.w, 4.0, eps);

    const prod = Vec4.mul(a, b);
    try expectApprox(prod.x, 5.0, eps);
    try expectApprox(prod.y, 12.0, eps);
    try expectApprox(prod.z, 21.0, eps);
    try expectApprox(prod.w, 32.0, eps);

    const quot = Vec4.div(b, a);
    try expectApprox(quot.x, 5.0, eps);
    try expectApprox(quot.y, 3.0, eps);
    try expectApprox(quot.z, 7.0 / 3.0, eps);
    try expectApprox(quot.w, 2.0, eps);

    const scaled = Vec4.scale(a, 3.0);
    try expectApprox(scaled.x, 3.0, eps);
    try expectApprox(scaled.y, 6.0, eps);
    try expectApprox(scaled.z, 9.0, eps);
    try expectApprox(scaled.w, 12.0, eps);

    const negated = Vec4.neg(a);
    try expectApprox(negated.x, -1.0, eps);
    try expectApprox(negated.y, -2.0, eps);
    try expectApprox(negated.z, -3.0, eps);
    try expectApprox(negated.w, -4.0, eps);
}

test "Vec4 dot and length" {
    const a = Vec4.init(1.0, 2.0, 3.0, 4.0);
    const b = Vec4.init(5.0, 6.0, 7.0, 8.0);

    // dot = 1*5 + 2*6 + 3*7 + 4*8 = 5+12+21+32 = 70
    try expectApprox(Vec4.dot(a, b), 70.0, eps);

    // lengthSq = 1+4+9+16 = 30
    try expectApprox(Vec4.lengthSq(a), 30.0, eps);

    // length = sqrt(30)
    try expectApprox(Vec4.length(a), @sqrt(@as(f32, 30.0)), eps);
}

test "Vec4 normalize" {
    const v = Vec4.init(3.0, 0.0, 0.0, 4.0);
    const n = Vec4.normalize(v);
    // length of v is 5
    try expectApprox(n.x, 0.6, eps);
    try expectApprox(n.y, 0.0, eps);
    try expectApprox(n.z, 0.0, eps);
    try expectApprox(n.w, 0.8, eps);
    try expectApprox(Vec4.length(n), 1.0, eps);

    // Zero vector returns zero
    const z = Vec4.normalize(Vec4.zero);
    try expectApprox(z.x, 0.0, eps);
    try expectApprox(z.y, 0.0, eps);
    try expectApprox(z.z, 0.0, eps);
    try expectApprox(z.w, 0.0, eps);
}

test "Vec4 lerp" {
    const a = Vec4.init(0.0, 0.0, 0.0, 0.0);
    const b = Vec4.init(10.0, 20.0, 30.0, 40.0);

    const at0 = Vec4.lerp(a, b, 0.0);
    try expectApprox(at0.x, 0.0, eps);
    try expectApprox(at0.y, 0.0, eps);
    try expectApprox(at0.z, 0.0, eps);
    try expectApprox(at0.w, 0.0, eps);

    const at_half = Vec4.lerp(a, b, 0.5);
    try expectApprox(at_half.x, 5.0, eps);
    try expectApprox(at_half.y, 10.0, eps);
    try expectApprox(at_half.z, 15.0, eps);
    try expectApprox(at_half.w, 20.0, eps);

    const at1 = Vec4.lerp(a, b, 1.0);
    try expectApprox(at1.x, 10.0, eps);
    try expectApprox(at1.y, 20.0, eps);
    try expectApprox(at1.z, 30.0, eps);
    try expectApprox(at1.w, 40.0, eps);
}

test "Vec4 approxEqual" {
    const a = Vec4.init(1.0, 2.0, 3.0, 4.0);
    const b = Vec4.init(1.0000005, 2.0000005, 3.0000005, 4.0000005);
    const c = Vec4.init(1.1, 2.0, 3.0, 4.0);

    try expect(Vec4.approxEqual(a, b, eps));
    try expect(!Vec4.approxEqual(a, c, eps));
}

test "Vec4 fromArray/toArray roundtrip" {
    const arr = [4]f32{ 1.0, 2.0, 3.0, 4.0 };
    const v = Vec4.fromArray(arr);
    const out = v.toArray();

    try expectApprox(out[0], arr[0], eps);
    try expectApprox(out[1], arr[1], eps);
    try expectApprox(out[2], arr[2], eps);
    try expectApprox(out[3], arr[3], eps);
}

test "Vec4 clamp and abs" {
    const v = Vec4.init(-2.0, 0.5, 3.0, -0.5);
    const lo = Vec4.init(0.0, 0.0, 0.0, 0.0);
    const hi = Vec4.init(1.0, 1.0, 1.0, 1.0);

    const clamped = Vec4.clamp(v, lo, hi);
    try expectApprox(clamped.x, 0.0, eps);
    try expectApprox(clamped.y, 0.5, eps);
    try expectApprox(clamped.z, 1.0, eps);
    try expectApprox(clamped.w, 0.0, eps);

    const a = Vec4.abs(v);
    try expectApprox(a.x, 2.0, eps);
    try expectApprox(a.y, 0.5, eps);
    try expectApprox(a.z, 3.0, eps);
    try expectApprox(a.w, 0.5, eps);
}

test "Vec4 xyz/xy projection" {
    const v = Vec4.init(1.0, 2.0, 3.0, 4.0);

    const v3 = v.xyz();
    try expectApprox(v3.x, 1.0, eps);
    try expectApprox(v3.y, 2.0, eps);
    try expectApprox(v3.z, 3.0, eps);

    const v2 = v.xy();
    try expectApprox(v2.x, 1.0, eps);
    try expectApprox(v2.y, 2.0, eps);
}

test "Vec4 fromVec3" {
    const v3 = vec3_mod.Vec3{ .x = 1.0, .y = 2.0, .z = 3.0 };
    const v4 = Vec4.fromVec3(v3, 1.0);

    try expectApprox(v4.x, 1.0, eps);
    try expectApprox(v4.y, 2.0, eps);
    try expectApprox(v4.z, 3.0, eps);
    try expectApprox(v4.w, 1.0, eps);
}
