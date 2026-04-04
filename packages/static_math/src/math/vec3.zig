//! Vec3: 3-component 32-bit float vector.
//!
//! Key operations: `add`, `sub`, `dot`, `cross`, `normalize`, `slerp`,
//! `reflect`, `project`, `lerp`.
//!
//! Stored as an `extern struct` for GPU/C ABI interop. Right-handed
//! coordinate system: +X right, +Y up, -Z forward (consistent with Mat4).
//! All operations are pure functions (no mutation). Thread-safe.
//! Preconditions (non-zero divisors, unit-length slerp inputs) are
//! enforced via `std.debug.assert` — programmer errors per agents.md §3.10.1.

const std = @import("std");
const scalar = @import("scalar.zig");
const vec2_mod = @import("vec2.zig");

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    comptime {
        // Compile-time invariant: extern struct must be exactly 3 floats.
        std.debug.assert(@sizeOf(Vec3) == 3 * @sizeOf(f32));
    }

    // ── Constants ──────────────────────────────────────────────────────

    pub const zero = Vec3{ .x = 0.0, .y = 0.0, .z = 0.0 };
    pub const one = Vec3{ .x = 1.0, .y = 1.0, .z = 1.0 };
    pub const unit_x = Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 };
    pub const unit_y = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    pub const unit_z = Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 };
    pub const right = unit_x;
    pub const up = unit_y;
    pub const forward = Vec3{ .x = 0.0, .y = 0.0, .z = -1.0 };

    // ── Construction ──────────────────────────────────────────────────

    pub inline fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub inline fn splat(v: f32) Vec3 {
        return .{ .x = v, .y = v, .z = v };
    }

    pub inline fn fromVec2(v2: vec2_mod.Vec2, z_val: f32) Vec3 {
        return .{ .x = v2.x, .y = v2.y, .z = z_val };
    }

    pub inline fn fromArray(a: [3]f32) Vec3 {
        return .{ .x = a[0], .y = a[1], .z = a[2] };
    }

    pub inline fn toArray(self: Vec3) [3]f32 {
        return .{ self.x, self.y, self.z };
    }

    // ── Arithmetic ────────────────────────────────────────────────────

    pub inline fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub inline fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub inline fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }

    pub inline fn div(a: Vec3, b: Vec3) Vec3 {
        std.debug.assert(b.x != 0.0);
        std.debug.assert(b.y != 0.0);
        std.debug.assert(b.z != 0.0);
        return .{ .x = a.x / b.x, .y = a.y / b.y, .z = a.z / b.z };
    }

    pub inline fn scale(self: Vec3, s: f32) Vec3 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    pub inline fn neg(self: Vec3) Vec3 {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }

    // ── Geometry ──────────────────────────────────────────────────────

    pub inline fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub inline fn lengthSq(self: Vec3) f32 {
        return dot(self, self);
    }

    pub inline fn length(self: Vec3) f32 {
        return @sqrt(lengthSq(self));
    }

    /// Returns the normalized vector, or zero if the input is zero-length.
    ///
    /// §0 deviation: uses exact-zero check rather than an epsilon threshold.
    /// This is a deliberate "fast primitive" choice: callers needing robust
    /// near-zero handling should check length against their own tolerance
    /// before calling normalize. An epsilon here would mask upstream bugs
    /// where a genuinely degenerate vector is silently treated as valid.
    pub inline fn normalize(self: Vec3) Vec3 {
        const len = length(self);
        if (len == 0.0) return zero;
        const inv = 1.0 / len;
        return .{ .x = self.x * inv, .y = self.y * inv, .z = self.z * inv };
    }

    /// Non-asserting normalize for boundary-facing code. Returns `null`
    /// when the input is zero-length instead of silently returning `Vec3.zero`.
    pub inline fn tryNormalize(self: Vec3) ?Vec3 {
        const len = length(self);
        if (len == 0.0) return null;
        const inv = 1.0 / len;
        return .{ .x = self.x * inv, .y = self.y * inv, .z = self.z * inv };
    }

    pub inline fn distance(a: Vec3, b: Vec3) f32 {
        return sub(a, b).length();
    }

    pub inline fn distanceSq(a: Vec3, b: Vec3) f32 {
        return sub(a, b).lengthSq();
    }

    // ── Interpolation ─────────────────────────────────────────────────

    pub inline fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
            .z = a.z + (b.z - a.z) * t,
        };
    }

    /// Spherical linear interpolation between two direction vectors.
    ///
    /// Both inputs should be normalized. Falls back to `lerp` + normalize
    /// when the vectors are nearly parallel (angle < epsilon) to avoid
    /// division by a near-zero sine.
    pub inline fn slerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        // Precondition: both inputs should be unit vectors for slerp to be geometrically correct.
        std.debug.assert(@abs(lengthSq(a) - 1.0) <= scalar.epsilon * 100.0);
        std.debug.assert(@abs(lengthSq(b) - 1.0) <= scalar.epsilon * 100.0);
        const d = scalar.clamp(dot(a, b), -1.0, 1.0);
        const theta = std.math.acos(d);
        if (theta < scalar.epsilon) {
            // Nearly parallel: lerp is a safe approximation.
            return normalize(lerp(a, b, t));
        }
        const sin_theta = @sin(theta);
        const wa = @sin((1.0 - t) * theta) / sin_theta;
        const wb = @sin(t * theta) / sin_theta;
        return .{
            .x = a.x * wa + b.x * wb,
            .y = a.y * wa + b.y * wb,
            .z = a.z * wa + b.z * wb,
        };
    }

    // ── Component-wise ────────────────────────────────────────────────

    pub inline fn min(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = @min(a.x, b.x),
            .y = @min(a.y, b.y),
            .z = @min(a.z, b.z),
        };
    }

    pub inline fn max(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = @max(a.x, b.x),
            .y = @max(a.y, b.y),
            .z = @max(a.z, b.z),
        };
    }

    pub inline fn clamp(self: Vec3, lo: Vec3, hi: Vec3) Vec3 {
        return .{
            .x = scalar.clamp(self.x, lo.x, hi.x),
            .y = scalar.clamp(self.y, lo.y, hi.y),
            .z = scalar.clamp(self.z, lo.z, hi.z),
        };
    }

    pub inline fn abs(self: Vec3) Vec3 {
        return .{
            .x = @abs(self.x),
            .y = @abs(self.y),
            .z = @abs(self.z),
        };
    }

    // ── Comparison ────────────────────────────────────────────────────

    pub inline fn approxEqual(a: Vec3, b: Vec3, tolerance: f32) bool {
        std.debug.assert(tolerance >= 0.0);
        return @abs(a.x - b.x) <= tolerance and
            @abs(a.y - b.y) <= tolerance and
            @abs(a.z - b.z) <= tolerance;
    }

    // ── 3D-specific ───────────────────────────────────────────────────

    /// Reflect vector v about plane normal n.
    /// Precondition: n must be normalized.
    pub inline fn reflect(v: Vec3, n: Vec3) Vec3 {
        std.debug.assert(approxEqual(
            splat(n.lengthSq()),
            one,
            scalar.epsilon * 100.0,
        ));
        const d = dot(v, n);
        return .{
            .x = v.x - 2.0 * d * n.x,
            .y = v.y - 2.0 * d * n.y,
            .z = v.z - 2.0 * d * n.z,
        };
    }

    /// Project vector v onto vector `onto`.
    /// Precondition: `onto` must be non-zero.
    pub inline fn project(v: Vec3, onto: Vec3) Vec3 {
        const denom = dot(onto, onto);
        std.debug.assert(denom != 0.0);
        const s = dot(v, onto) / denom;
        return onto.scale(s);
    }

    /// Angle in radians between two vectors.
    /// Precondition: both vectors must be non-zero.
    pub inline fn angle(a: Vec3, b: Vec3) f32 {
        const len_a = a.length();
        const len_b = b.length();
        std.debug.assert(len_a != 0.0);
        std.debug.assert(len_b != 0.0);
        const cos_theta = scalar.clamp(
            dot(a, b) / (len_a * len_b),
            -1.0,
            1.0,
        );
        return std.math.acos(cos_theta);
    }

    // ── Swizzle ───────────────────────────────────────────────────────

    pub inline fn xy(self: Vec3) vec2_mod.Vec2 {
        return .{ .x = self.x, .y = self.y };
    }

    pub inline fn xz(self: Vec3) vec2_mod.Vec2 {
        return .{ .x = self.x, .y = self.z };
    }

    pub inline fn yz(self: Vec3) vec2_mod.Vec2 {
        return .{ .x = self.y, .y = self.z };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const eps = scalar.epsilon;
const expectApprox = std.testing.expectApproxEqAbs;

test "Vec3 basic arithmetic" {
    const a = Vec3.init(1.0, 2.0, 3.0);
    const b = Vec3.init(4.0, 5.0, 6.0);

    const sum = Vec3.add(a, b);
    try expectApprox(sum.x, 5.0, eps);
    try expectApprox(sum.y, 7.0, eps);
    try expectApprox(sum.z, 9.0, eps);

    const diff = Vec3.sub(b, a);
    try expectApprox(diff.x, 3.0, eps);
    try expectApprox(diff.y, 3.0, eps);
    try expectApprox(diff.z, 3.0, eps);

    const prod = Vec3.mul(a, b);
    try expectApprox(prod.x, 4.0, eps);
    try expectApprox(prod.y, 10.0, eps);
    try expectApprox(prod.z, 18.0, eps);

    const scaled = a.scale(3.0);
    try expectApprox(scaled.x, 3.0, eps);
    try expectApprox(scaled.y, 6.0, eps);
    try expectApprox(scaled.z, 9.0, eps);

    const negated = a.neg();
    try expectApprox(negated.x, -1.0, eps);
    try expectApprox(negated.y, -2.0, eps);
    try expectApprox(negated.z, -3.0, eps);
}

test "Vec3 dot and cross" {
    const a = Vec3.init(1.0, 2.0, 3.0);
    const b = Vec3.init(4.0, 5.0, 6.0);
    try expectApprox(Vec3.dot(a, b), 32.0, eps);

    const c = Vec3.cross(Vec3.unit_x, Vec3.unit_y);
    try expectApprox(c.x, 0.0, eps);
    try expectApprox(c.y, 0.0, eps);
    try expectApprox(c.z, 1.0, eps);
    try std.testing.expect(Vec3.approxEqual(c, Vec3.unit_z, eps));
}

test "Vec3 normalize" {
    const v = Vec3.init(3.0, 0.0, 4.0);
    const n = v.normalize();
    try expectApprox(n.length(), 1.0, eps);
    try expectApprox(n.x, 0.6, eps);
    try expectApprox(n.z, 0.8, eps);

    const z = Vec3.zero.normalize();
    try std.testing.expect(Vec3.approxEqual(z, Vec3.zero, eps));
}

test "Vec3 tryNormalize" {
    const v = Vec3.init(3.0, 0.0, 4.0);
    const n = Vec3.tryNormalize(v);
    try std.testing.expect(n != null);
    try expectApprox(n.?.length(), 1.0, eps);

    // Zero vector returns null.
    try std.testing.expect(Vec3.tryNormalize(Vec3.zero) == null);
}

test "Vec3 reflect" {
    // Reflect (1, -1, 0) about the Y-axis normal (0, 1, 0).
    const v = Vec3.init(1.0, -1.0, 0.0);
    const n = Vec3.unit_y;
    const r = Vec3.reflect(v, n);
    try expectApprox(r.x, 1.0, eps);
    try expectApprox(r.y, 1.0, eps);
    try expectApprox(r.z, 0.0, eps);
}

test "Vec3 project" {
    // Project (3, 4, 0) onto the X axis.
    const v = Vec3.init(3.0, 4.0, 0.0);
    const onto = Vec3.unit_x;
    const p = Vec3.project(v, onto);
    try expectApprox(p.x, 3.0, eps);
    try expectApprox(p.y, 0.0, eps);
    try expectApprox(p.z, 0.0, eps);
}

test "Vec3 approxEqual" {
    const a = Vec3.init(1.0, 2.0, 3.0);
    const b = Vec3.init(1.0 + eps * 0.5, 2.0, 3.0 - eps * 0.5);
    try std.testing.expect(Vec3.approxEqual(a, b, eps));

    const c = Vec3.init(1.0 + 0.01, 2.0, 3.0);
    try std.testing.expect(!Vec3.approxEqual(a, c, eps));
}

test "Vec3 fromArray/toArray roundtrip" {
    const arr = [3]f32{ 1.0, 2.0, 3.0 };
    const v = Vec3.fromArray(arr);
    const out = v.toArray();
    try expectApprox(out[0], arr[0], eps);
    try expectApprox(out[1], arr[1], eps);
    try expectApprox(out[2], arr[2], eps);
}

test "Vec3 distanceSq" {
    const a = Vec3.init(1.0, 0.0, 0.0);
    const b = Vec3.init(4.0, 0.0, 0.0);
    try expectApprox(Vec3.distanceSq(a, b), 9.0, eps);
    try expectApprox(Vec3.distance(a, b), 3.0, eps);
}

test "Vec3 swizzle xy/xz/yz" {
    const v = Vec3.init(1.0, 2.0, 3.0);

    const s_xy = v.xy();
    try expectApprox(s_xy.x, 1.0, eps);
    try expectApprox(s_xy.y, 2.0, eps);

    const s_xz = v.xz();
    try expectApprox(s_xz.x, 1.0, eps);
    try expectApprox(s_xz.y, 3.0, eps);

    const s_yz = v.yz();
    try expectApprox(s_yz.x, 2.0, eps);
    try expectApprox(s_yz.y, 3.0, eps);
}
