//! Quaternion type for 3D rotations (f32).
//!
//! Conventions:
//! - Right-handed coordinate system.
//! - Hamilton multiplication semantics.
//! - Storage order: (x, y, z, w) where w is the scalar part.
//!
//! All functions are pure, allocation-free, and inline where possible.
//! Preconditions are enforced via assertions (programmer errors).

const std = @import("std");
const scalar = @import("scalar.zig");
const vec3_mod = @import("vec3.zig");
const mat3_mod = @import("mat3.zig");
const mat4_mod = @import("mat4.zig");

pub const Quat = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    comptime {
        // Compile-time invariant: extern struct must be exactly 4 floats.
        std.debug.assert(@sizeOf(Quat) == 4 * @sizeOf(f32));
    }

    // ── Constants ──────────────────────────────────────────────────────

    pub const identity = Quat{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 1.0 };

    // ── Construction ──────────────────────────────────────────────────

    pub inline fn init(x: f32, y: f32, z: f32, w: f32) Quat {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    /// Create from axis-angle (radians).
    /// Precondition: `axis` should be normalized.
    pub inline fn fromAxisAngle(
        axis: vec3_mod.Vec3,
        angle_rad: f32,
    ) Quat {
        // Precondition: axis must be unit length (mirrors Mat3.fromRotation pattern).
        std.debug.assert(vec3_mod.Vec3.approxEqual(
            vec3_mod.Vec3.splat(axis.lengthSq()),
            vec3_mod.Vec3.one,
            scalar.epsilon * 100.0,
        ));
        const half = angle_rad * 0.5;
        const s = @sin(half);
        const c = @cos(half);
        return .{
            .x = axis.x * s,
            .y = axis.y * s,
            .z = axis.z * s,
            .w = c,
        };
    }

    /// Create from Euler angles (radians), applied in X (pitch),
    /// then Y (yaw), then Z (roll) order.
    pub inline fn fromEuler(pitch: f32, yaw: f32, roll: f32) Quat {
        const qx = fromAxisAngle(vec3_mod.Vec3.unit_x, pitch);
        const qy = fromAxisAngle(vec3_mod.Vec3.unit_y, yaw);
        const qz = fromAxisAngle(vec3_mod.Vec3.unit_z, roll);
        return mul(qz, mul(qy, qx));
    }

    /// Create from 3x3 rotation matrix (Shepperd's method).
    /// Precondition: matrix represents a rotation (orthonormal basis).
    pub fn fromMat3(m: mat3_mod.Mat3) Quat {
        // Precondition: matrix must be orthonormal (det ≈ 1 means rotation, not reflection/scale).
        std.debug.assert(@abs(mat3_mod.Mat3.determinant(m) - 1.0) <= scalar.epsilon * 1000.0);

        const m00 = mat3_mod.Mat3.at(m, 0, 0);
        const m11 = mat3_mod.Mat3.at(m, 1, 1);
        const m22 = mat3_mod.Mat3.at(m, 2, 2);
        const trace = m00 + m11 + m22;

        const result: Quat = if (trace > 0.0) blk: {
            const s = @sqrt(trace + 1.0) * 2.0; // s = 4*w
            break :blk .{
                .w = 0.25 * s,
                .x = (mat3_mod.Mat3.at(m, 2, 1) -
                    mat3_mod.Mat3.at(m, 1, 2)) / s,
                .y = (mat3_mod.Mat3.at(m, 0, 2) -
                    mat3_mod.Mat3.at(m, 2, 0)) / s,
                .z = (mat3_mod.Mat3.at(m, 1, 0) -
                    mat3_mod.Mat3.at(m, 0, 1)) / s,
            };
        } else if (m00 > m11 and m00 > m22) blk: {
            const s = @sqrt(1.0 + m00 - m11 - m22) * 2.0; // s = 4*x
            break :blk .{
                .w = (mat3_mod.Mat3.at(m, 2, 1) -
                    mat3_mod.Mat3.at(m, 1, 2)) / s,
                .x = 0.25 * s,
                .y = (mat3_mod.Mat3.at(m, 0, 1) +
                    mat3_mod.Mat3.at(m, 1, 0)) / s,
                .z = (mat3_mod.Mat3.at(m, 0, 2) +
                    mat3_mod.Mat3.at(m, 2, 0)) / s,
            };
        } else if (m11 > m22) blk: {
            const s = @sqrt(1.0 + m11 - m00 - m22) * 2.0; // s = 4*y
            break :blk .{
                .w = (mat3_mod.Mat3.at(m, 0, 2) -
                    mat3_mod.Mat3.at(m, 2, 0)) / s,
                .x = (mat3_mod.Mat3.at(m, 0, 1) +
                    mat3_mod.Mat3.at(m, 1, 0)) / s,
                .y = 0.25 * s,
                .z = (mat3_mod.Mat3.at(m, 1, 2) +
                    mat3_mod.Mat3.at(m, 2, 1)) / s,
            };
        } else blk: {
            const s = @sqrt(1.0 + m22 - m00 - m11) * 2.0; // s = 4*z
            break :blk .{
                .w = (mat3_mod.Mat3.at(m, 1, 0) -
                    mat3_mod.Mat3.at(m, 0, 1)) / s,
                .x = (mat3_mod.Mat3.at(m, 0, 2) +
                    mat3_mod.Mat3.at(m, 2, 0)) / s,
                .y = (mat3_mod.Mat3.at(m, 1, 2) +
                    mat3_mod.Mat3.at(m, 2, 1)) / s,
                .z = 0.25 * s,
            };
        };

        // Postcondition: result must be approximately unit-length.
        std.debug.assert(@abs(lengthSq(result) - 1.0) <= scalar.epsilon * 1000.0);
        return result;
    }

    /// Create from the upper-left 3x3 portion of a Mat4.
    /// Precondition: matrix represents a rotation (orthonormal, no
    /// scale/shear).
    pub inline fn fromMat4(m: mat4_mod.Mat4) Quat {
        // Precondition: upper-left 3x3 must have det ≈ 1.0 (pair assertion with fromMat3).
        const m3 = mat4_mod.Mat4.toMat3(m);
        std.debug.assert(@abs(mat3_mod.Mat3.determinant(m3) - 1.0) <= scalar.epsilon * 1000.0);
        return fromMat3(m3);
    }

    /// Create a quaternion that rotates `from_dir` to `to_dir`.
    /// Handles parallel (identity) and anti-parallel (180-degree)
    /// cases.
    /// Precondition: both vectors should be normalized.
    pub fn fromTo(
        from_dir: vec3_mod.Vec3,
        to_dir: vec3_mod.Vec3,
    ) Quat {
        const d = vec3_mod.Vec3.dot(from_dir, to_dir);
        if (d >= 1.0) return identity;
        if (d <= -1.0) {
            // 180-degree rotation around any perpendicular axis.
            var axis = vec3_mod.Vec3.cross(
                vec3_mod.Vec3.unit_x,
                from_dir,
            );
            if (vec3_mod.Vec3.lengthSq(axis) == 0.0) {
                axis = vec3_mod.Vec3.cross(
                    vec3_mod.Vec3.unit_y,
                    from_dir,
                );
            }
            axis = vec3_mod.Vec3.normalize(axis);
            return fromAxisAngle(axis, scalar.pi);
        }

        const c = vec3_mod.Vec3.cross(from_dir, to_dir);
        const q = Quat{
            .x = c.x,
            .y = c.y,
            .z = c.z,
            .w = 1.0 + d,
        };
        return normalize(q);
    }

    /// Create look rotation from forward and up direction vectors.
    /// Precondition: both vectors should be normalized and not
    /// parallel.
    pub fn lookRotation(
        forward_dir: vec3_mod.Vec3,
        up_dir: vec3_mod.Vec3,
    ) Quat {
        // Precondition: forward_dir must be non-zero (zero cannot be normalized).
        std.debug.assert(vec3_mod.Vec3.lengthSq(forward_dir) > 0.0);
        // Precondition: up_dir must be non-zero (zero cross product gives degenerate right axis).
        std.debug.assert(vec3_mod.Vec3.lengthSq(up_dir) > 0.0);
        const f = vec3_mod.Vec3.normalize(forward_dir);
        // Local +Z points backward, so -Z points forward.
        const z_axis = vec3_mod.Vec3.neg(f);
        var x_axis = vec3_mod.Vec3.cross(up_dir, z_axis);
        x_axis = vec3_mod.Vec3.normalize(x_axis);
        const y_axis = vec3_mod.Vec3.cross(z_axis, x_axis);
        const m = mat3_mod.Mat3.fromCols(x_axis, y_axis, z_axis);
        return fromMat3(m);
    }

    // ── Operations ────────────────────────────────────────────────────

    /// Quaternion multiplication (composition).
    /// Result represents: first apply `b`, then apply `a`.
    pub inline fn mul(a: Quat, b: Quat) Quat {
        return .{
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        };
    }

    pub inline fn conjugate(q: Quat) Quat {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = q.w };
    }

    /// Multiplicative inverse.
    /// Precondition: quaternion must be non-zero.
    pub inline fn inverse(q: Quat) Quat {
        const len_sq = lengthSq(q);
        std.debug.assert(len_sq != 0.0);
        const inv = 1.0 / len_sq;
        const c = conjugate(q);
        return .{
            .x = c.x * inv,
            .y = c.y * inv,
            .z = c.z * inv,
            .w = c.w * inv,
        };
    }

    /// Normalize the quaternion. Returns identity for zero-length
    /// (not NaN).
    pub inline fn normalize(q: Quat) Quat {
        const len_sq = lengthSq(q);
        if (len_sq == 0.0) return identity;
        const inv = 1.0 / @sqrt(len_sq);
        return .{
            .x = q.x * inv,
            .y = q.y * inv,
            .z = q.z * inv,
            .w = q.w * inv,
        };
    }

    /// Non-asserting normalize for boundary-facing code. Returns `null`
    /// for zero-length input instead of silently returning `Quat.identity`.
    pub inline fn tryNormalize(q: Quat) ?Quat {
        const len_sq = lengthSq(q);
        if (len_sq == 0.0) return null;
        const inv = 1.0 / @sqrt(len_sq);
        return .{
            .x = q.x * inv,
            .y = q.y * inv,
            .z = q.z * inv,
            .w = q.w * inv,
        };
    }

    pub inline fn neg(q: Quat) Quat {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = -q.w };
    }

    pub inline fn dot(a: Quat, b: Quat) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }

    pub inline fn lengthSq(q: Quat) f32 {
        return q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
    }

    pub inline fn length(q: Quat) f32 {
        return @sqrt(lengthSq(q));
    }

    // ── Queries ───────────────────────────────────────────────────────

    pub inline fn isNormalized(q: Quat, tolerance: f32) bool {
        return @abs(length(q) - 1.0) <= tolerance;
    }

    // ── Rotation ──────────────────────────────────────────────────────

    /// Rotate a vector by this quaternion.
    pub fn rotate(q: Quat, v: vec3_mod.Vec3) vec3_mod.Vec3 {
        const qv = vec3_mod.Vec3.init(q.x, q.y, q.z);
        const t = vec3_mod.Vec3.scale(
            vec3_mod.Vec3.cross(qv, v),
            2.0,
        );
        return vec3_mod.Vec3.add(
            vec3_mod.Vec3.add(v, vec3_mod.Vec3.scale(t, q.w)),
            vec3_mod.Vec3.cross(qv, t),
        );
    }

    // ── Interpolation ─────────────────────────────────────────────────

    /// Component-wise linear interpolation. NOT normalized.
    pub inline fn lerp(a: Quat, b: Quat, t: f32) Quat {
        return .{
            .x = scalar.lerp(a.x, b.x, t),
            .y = scalar.lerp(a.y, b.y, t),
            .z = scalar.lerp(a.z, b.z, t),
            .w = scalar.lerp(a.w, b.w, t),
        };
    }

    /// Normalized linear interpolation.
    pub inline fn nlerp(a: Quat, b: Quat, t: f32) Quat {
        return normalize(lerp(a, b, t));
    }

    /// Spherical linear interpolation.
    /// Flips sign if dot < 0; falls back to nlerp if dot > 0.9995.
    pub fn slerp(a: Quat, b: Quat, t: f32) Quat {
        // Precondition: both inputs must be unit quaternions.
        std.debug.assert(@abs(lengthSq(a) - 1.0) <= scalar.epsilon * 1000.0);
        std.debug.assert(@abs(lengthSq(b) - 1.0) <= scalar.epsilon * 1000.0);

        var b2 = b;
        var d = dot(a, b);
        if (d < 0.0) {
            b2 = neg(b);
            d = -d;
        }

        if (d > 0.9995) {
            return nlerp(a, b2, t);
        }

        const theta = std.math.acos(scalar.clamp(d, -1.0, 1.0));
        const sin_theta = @sin(theta);
        // d <= 0.9995 guarantees theta >= acos(0.9995) ≈ 0.032 rad, so
        // sin_theta >= sin(0.032) ≈ 0.032 >> 0. Guard against near-zero division.
        std.debug.assert(sin_theta > scalar.epsilon);

        const w1 = @sin((1.0 - t) * theta) / sin_theta;
        const w2 = @sin(t * theta) / sin_theta;

        return .{
            .x = a.x * w1 + b2.x * w2,
            .y = a.y * w1 + b2.y * w2,
            .z = a.z * w1 + b2.z * w2,
            .w = a.w * w1 + b2.w * w2,
        };
    }

    // ── Conversion ────────────────────────────────────────────────────

    pub fn toAxisAngle(
        q: Quat,
    ) struct { axis: vec3_mod.Vec3, angle: f32 } {
        const nq = normalize(q);
        const w_clamped = scalar.clamp(nq.w, -1.0, 1.0);
        const angle = 2.0 * std.math.acos(w_clamped);

        const s_sq = 1.0 - w_clamped * w_clamped;
        if (s_sq <= 1.0e-8) {
            return .{
                .axis = vec3_mod.Vec3.unit_x,
                .angle = 0.0,
            };
        }
        const inv_s = 1.0 / @sqrt(s_sq);
        return .{
            .axis = vec3_mod.Vec3.init(
                nq.x * inv_s,
                nq.y * inv_s,
                nq.z * inv_s,
            ),
            .angle = angle,
        };
    }

    /// Convert to Euler angles (radians), matching `fromEuler()`
    /// order. Returns `.pitch` (X), `.yaw` (Y), `.roll` (Z).
    pub fn toEuler(
        q: Quat,
    ) struct { pitch: f32, yaw: f32, roll: f32 } {
        const nq = normalize(q);

        const sinr_cosp = 2.0 * (nq.w * nq.x + nq.y * nq.z);
        const cosr_cosp = 1.0 -
            2.0 * (nq.x * nq.x + nq.y * nq.y);
        const pitch = std.math.atan2(sinr_cosp, cosr_cosp);

        const sinp = 2.0 * (nq.w * nq.y - nq.z * nq.x);
        const yaw = if (@abs(sinp) >= 1.0)
            @as(f32, std.math.copysign(scalar.pi / 2.0, sinp))
        else
            std.math.asin(sinp);

        const siny_cosp = 2.0 * (nq.w * nq.z + nq.x * nq.y);
        const cosy_cosp = 1.0 -
            2.0 * (nq.y * nq.y + nq.z * nq.z);
        const roll = std.math.atan2(siny_cosp, cosy_cosp);

        return .{ .pitch = pitch, .yaw = yaw, .roll = roll };
    }

    pub fn toMat3(q: Quat) mat3_mod.Mat3 {
        const xx = q.x * q.x;
        const yy = q.y * q.y;
        const zz = q.z * q.z;
        const xy = q.x * q.y;
        const xz = q.x * q.z;
        const yz = q.y * q.z;
        const wx = q.w * q.x;
        const wy = q.w * q.y;
        const wz = q.w * q.z;

        // Column-major rotation matrix.
        const c0 = vec3_mod.Vec3.init(
            1.0 - 2.0 * (yy + zz),
            2.0 * (xy + wz),
            2.0 * (xz - wy),
        );
        const c1 = vec3_mod.Vec3.init(
            2.0 * (xy - wz),
            1.0 - 2.0 * (xx + zz),
            2.0 * (yz + wx),
        );
        const c2 = vec3_mod.Vec3.init(
            2.0 * (xz + wy),
            2.0 * (yz - wx),
            1.0 - 2.0 * (xx + yy),
        );
        return mat3_mod.Mat3.fromCols(c0, c1, c2);
    }

    pub inline fn toMat4(q: Quat) mat4_mod.Mat4 {
        return mat4_mod.Mat4.fromMat3(toMat3(q));
    }

    // ── Comparison ────────────────────────────────────────────────────

    /// Approximate equality, accounting for quaternion double-cover
    /// (q and -q represent the same rotation).
    pub fn approxEqual(a: Quat, b: Quat, tolerance: f32) bool {
        const d1 = @abs(a.x - b.x) + @abs(a.y - b.y) +
            @abs(a.z - b.z) + @abs(a.w - b.w);
        const nb = neg(b);
        const d2 = @abs(a.x - nb.x) + @abs(a.y - nb.y) +
            @abs(a.z - nb.z) + @abs(a.w - nb.w);
        return @min(d1, d2) <= tolerance;
    }

    // ── Basis ─────────────────────────────────────────────────────────

    pub fn forward(q: Quat) vec3_mod.Vec3 {
        return rotate(q, vec3_mod.Vec3.forward);
    }

    pub fn right(q: Quat) vec3_mod.Vec3 {
        return rotate(q, vec3_mod.Vec3.right);
    }

    pub fn up(q: Quat) vec3_mod.Vec3 {
        return rotate(q, vec3_mod.Vec3.up);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const eps = scalar.epsilon;
const expectApprox = std.testing.expectApproxEqAbs;

test "Quat identity rotation" {
    const v = vec3_mod.Vec3.init(1.0, 2.0, 3.0);
    const result = Quat.rotate(Quat.identity, v);
    try expectApprox(result.x, v.x, eps);
    try expectApprox(result.y, v.y, eps);
    try expectApprox(result.z, v.z, eps);
}

test "Quat axis-angle rotation" {
    // 90 degrees around Y rotates +X to -Z.
    const q = Quat.fromAxisAngle(
        vec3_mod.Vec3.unit_y,
        scalar.pi / 2.0,
    );
    const v = Quat.rotate(q, vec3_mod.Vec3.unit_x);
    try expectApprox(v.x, 0.0, 1.0e-5);
    try expectApprox(v.y, 0.0, 1.0e-5);
    try expectApprox(v.z, -1.0, 1.0e-5);
}

test "Quat inverse" {
    const q = Quat.fromAxisAngle(
        vec3_mod.Vec3.unit_y,
        scalar.pi / 3.0,
    );
    const inv = Quat.inverse(q);
    const prod = Quat.mul(q, inv);
    try std.testing.expect(
        Quat.approxEqual(prod, Quat.identity, 1.0e-4),
    );
}

test "Quat mat3/mat4 roundtrip" {
    const q = Quat.fromAxisAngle(
        vec3_mod.Vec3.unit_z,
        0.9,
    );
    const m = Quat.toMat4(q);
    const q2 = Quat.fromMat4(m);
    try std.testing.expect(Quat.approxEqual(q, q2, 1.0e-4));
}

test "Quat fromEuler/toEuler roundtrip" {
    // Non-gimbal-lock angles.
    const pitch: f32 = 0.3;
    const yaw: f32 = 0.5;
    const roll: f32 = 0.7;
    const q = Quat.fromEuler(pitch, yaw, roll);
    const e = Quat.toEuler(q);
    try expectApprox(e.pitch, pitch, 1.0e-4);
    try expectApprox(e.yaw, yaw, 1.0e-4);
    try expectApprox(e.roll, roll, 1.0e-4);
}

test "Quat fromTo parallel" {
    const dir = vec3_mod.Vec3.unit_x;
    const q = Quat.fromTo(dir, dir);
    try std.testing.expect(
        Quat.approxEqual(q, Quat.identity, 1.0e-5),
    );
}

test "Quat fromTo anti-parallel" {
    const from = vec3_mod.Vec3.unit_x;
    const to = vec3_mod.Vec3.neg(vec3_mod.Vec3.unit_x);
    const q = Quat.fromTo(from, to);
    // Should be a valid 180-degree rotation.
    try std.testing.expect(Quat.isNormalized(q, 1.0e-4));
    const rotated = Quat.rotate(q, from);
    try expectApprox(rotated.x, to.x, 1.0e-4);
    try expectApprox(rotated.y, to.y, 1.0e-4);
    try expectApprox(rotated.z, to.z, 1.0e-4);
}

test "Quat slerp endpoints" {
    const a = Quat.fromAxisAngle(
        vec3_mod.Vec3.unit_y,
        0.0,
    );
    const b = Quat.fromAxisAngle(
        vec3_mod.Vec3.unit_y,
        scalar.pi / 2.0,
    );
    const s0 = Quat.slerp(a, b, 0.0);
    const s1 = Quat.slerp(a, b, 1.0);
    try std.testing.expect(Quat.approxEqual(s0, a, 1.0e-5));
    try std.testing.expect(Quat.approxEqual(s1, b, 1.0e-5));
}

test "Quat neg same rotation" {
    const q = Quat.fromAxisAngle(
        vec3_mod.Vec3.unit_z,
        1.2,
    );
    const nq = Quat.neg(q);
    const v = vec3_mod.Vec3.init(1.0, 2.0, 3.0);
    const r1 = Quat.rotate(q, v);
    const r2 = Quat.rotate(nq, v);
    try expectApprox(r1.x, r2.x, 1.0e-5);
    try expectApprox(r1.y, r2.y, 1.0e-5);
    try expectApprox(r1.z, r2.z, 1.0e-5);
}

test "Quat isNormalized" {
    const q = Quat.init(1.0, 2.0, 3.0, 4.0);
    try std.testing.expect(!Quat.isNormalized(q, 1.0e-4));
    const nq = Quat.normalize(q);
    try std.testing.expect(Quat.isNormalized(nq, 1.0e-4));
}

test "Quat approxEqual accounts for double cover" {
    const q = Quat.fromAxisAngle(
        vec3_mod.Vec3.unit_y,
        scalar.pi / 4.0,
    );
    const nq = Quat.neg(q);
    // q and -q are NOT component-equal but represent the same
    // rotation, so approxEqual must return true.
    try std.testing.expect(Quat.approxEqual(q, nq, 1.0e-5));
    // Sanity: they are not component-identical.
    const direct = @abs(q.x - nq.x) + @abs(q.y - nq.y) +
        @abs(q.z - nq.z) + @abs(q.w - nq.w);
    try std.testing.expect(direct > 0.1);
}
