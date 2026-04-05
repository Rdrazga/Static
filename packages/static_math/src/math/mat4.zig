//! Mat4 - 4x4 matrix type
//!
//! Conventions (RFC-0053):
//! - Column-major storage.
//! - Column-vector multiplication: `v' = M * v`.
//! - Right-handed coordinate system, -Z forward.
//! - Projection depth range: [0, 1].
//!
//! ## Spec items
//! - `identity`, `zero` constants
//! - Construction: `fromCols`, `fromRows`, `diagonal`, `fromMat3`, `fromQuat`
//! - Transform builders: `fromTranslation`, `fromScale`, `fromRotationX/Y/Z`,
//!   `fromAxisAngle`
//! - Projection: `perspective` (depth [0,1]), `orthographic`, `lookAt`
//! - Arithmetic: `mul`, `mulVec`, `add`, `sub`, `scale`, `neg`, `transpose`,
//!   `determinant`, `inverse`
//! - Comparison: `approxEqual`
//! - Extraction: `toMat3`, `getTranslation`, `getScale`
//! - Transform application: `transformPoint`, `transformPointAffine`,
//!   `transformDir`
//! - Decomposition: `decompose`
//! - Access: `at`, `row`, `col`
//!
//! ## Status
//! Implemented
//!
//! ## Thread Safety
//! Unrestricted - all operations are pure
//!
//! ## Allocation Profile
//! No allocation (stack/register only)

const std = @import("std");
const assert = std.debug.assert;
const scalar = @import("scalar.zig");
const vec3_mod = @import("vec3.zig");
const vec4_mod = @import("vec4.zig");
const mat3_mod = @import("mat3.zig");

const Vec3 = vec3_mod.Vec3;
const Vec4 = vec4_mod.Vec4;
const Mat3 = mat3_mod.Mat3;

pub const Mat4 = extern struct {
    cols: [4]Vec4,

    comptime {
        // Compile-time invariant: extern struct must be exactly 4 Vec4 columns.
        assert(@sizeOf(Mat4) == 4 * @sizeOf(Vec4));
    }

    // ── Helpers (private) ───────────────────────────────────────────────

    inline fn lane(v: Vec4, idx: usize) f32 {
        return switch (idx) {
            0 => v.x,
            1 => v.y,
            2 => v.z,
            3 => v.w,
            else => unreachable,
        };
    }

    // ── Constants ───────────────────────────────────────────────────────

    pub const identity = Mat4{
        .cols = .{
            Vec4.init(1.0, 0.0, 0.0, 0.0),
            Vec4.init(0.0, 1.0, 0.0, 0.0),
            Vec4.init(0.0, 0.0, 1.0, 0.0),
            Vec4.init(0.0, 0.0, 0.0, 1.0),
        },
    };

    pub const zero = Mat4{
        .cols = .{ Vec4.zero, Vec4.zero, Vec4.zero, Vec4.zero },
    };

    // ── Construction ────────────────────────────────────────────────────

    pub inline fn fromCols(
        c0: Vec4,
        c1: Vec4,
        c2: Vec4,
        c3: Vec4,
    ) Mat4 {
        return .{ .cols = .{ c0, c1, c2, c3 } };
    }

    pub inline fn fromRows(
        r0: Vec4,
        r1: Vec4,
        r2: Vec4,
        r3: Vec4,
    ) Mat4 {
        return .{
            .cols = .{
                Vec4.init(r0.x, r1.x, r2.x, r3.x),
                Vec4.init(r0.y, r1.y, r2.y, r3.y),
                Vec4.init(r0.z, r1.z, r2.z, r3.z),
                Vec4.init(r0.w, r1.w, r2.w, r3.w),
            },
        };
    }

    pub inline fn diagonal(d: Vec4) Mat4 {
        return .{
            .cols = .{
                Vec4.init(d.x, 0.0, 0.0, 0.0),
                Vec4.init(0.0, d.y, 0.0, 0.0),
                Vec4.init(0.0, 0.0, d.z, 0.0),
                Vec4.init(0.0, 0.0, 0.0, d.w),
            },
        };
    }

    pub inline fn fromMat3(m: Mat3) Mat4 {
        return .{
            .cols = .{
                Vec4.init(m.cols[0].x, m.cols[0].y, m.cols[0].z, 0.0),
                Vec4.init(m.cols[1].x, m.cols[1].y, m.cols[1].z, 0.0),
                Vec4.init(m.cols[2].x, m.cols[2].y, m.cols[2].z, 0.0),
                Vec4.init(0.0, 0.0, 0.0, 1.0),
            },
        };
    }

    /// Create rotation matrix from a quaternion-like value with fields
    /// `x`, `y`, `z`, `w`.  Uses `anytype` to avoid an import cycle
    /// with the quaternion module.
    pub inline fn fromQuat(q: anytype) Mat4 {
        const x: f32 = q.x;
        const y: f32 = q.y;
        const z: f32 = q.z;
        const w: f32 = q.w;

        const xx = x * x;
        const yy = y * y;
        const zz = z * z;
        const xy = x * y;
        const xz = x * z;
        const yz = y * z;
        const wx = w * x;
        const wy = w * y;
        const wz = w * z;

        const c0 = Vec3.init(
            1.0 - 2.0 * (yy + zz),
            2.0 * (xy + wz),
            2.0 * (xz - wy),
        );
        const c1 = Vec3.init(
            2.0 * (xy - wz),
            1.0 - 2.0 * (xx + zz),
            2.0 * (yz + wx),
        );
        const c2 = Vec3.init(
            2.0 * (xz + wy),
            2.0 * (yz - wx),
            1.0 - 2.0 * (xx + yy),
        );
        return fromMat3(Mat3.fromCols(c0, c1, c2));
    }

    // ── Transform builders ──────────────────────────────────────────────

    pub inline fn fromTranslation(t: Vec3) Mat4 {
        return .{
            .cols = .{
                Vec4.init(1.0, 0.0, 0.0, 0.0),
                Vec4.init(0.0, 1.0, 0.0, 0.0),
                Vec4.init(0.0, 0.0, 1.0, 0.0),
                Vec4.init(t.x, t.y, t.z, 1.0),
            },
        };
    }

    pub inline fn fromScale(s: Vec3) Mat4 {
        return .{
            .cols = .{
                Vec4.init(s.x, 0.0, 0.0, 0.0),
                Vec4.init(0.0, s.y, 0.0, 0.0),
                Vec4.init(0.0, 0.0, s.z, 0.0),
                Vec4.init(0.0, 0.0, 0.0, 1.0),
            },
        };
    }

    pub inline fn fromRotationX(angle_rad: f32) Mat4 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return fromRows(
            Vec4.init(1.0, 0.0, 0.0, 0.0),
            Vec4.init(0.0, c, -s, 0.0),
            Vec4.init(0.0, s, c, 0.0),
            Vec4.init(0.0, 0.0, 0.0, 1.0),
        );
    }

    pub inline fn fromRotationY(angle_rad: f32) Mat4 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return fromRows(
            Vec4.init(c, 0.0, s, 0.0),
            Vec4.init(0.0, 1.0, 0.0, 0.0),
            Vec4.init(-s, 0.0, c, 0.0),
            Vec4.init(0.0, 0.0, 0.0, 1.0),
        );
    }

    pub inline fn fromRotationZ(angle_rad: f32) Mat4 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return fromRows(
            Vec4.init(c, -s, 0.0, 0.0),
            Vec4.init(s, c, 0.0, 0.0),
            Vec4.init(0.0, 0.0, 1.0, 0.0),
            Vec4.init(0.0, 0.0, 0.0, 1.0),
        );
    }

    /// Create rotation matrix from normalized axis and angle (radians).
    ///
    /// Precondition: `axis` should be normalized.
    pub inline fn fromAxisAngle(axis: Vec3, angle_rad: f32) Mat4 {
        // Precondition: axis must be unit length (mirrors Mat3.fromRotation pattern).
        assert(Vec3.approxEqual(
            Vec3.splat(Vec3.lengthSq(axis)),
            Vec3.one,
            scalar.epsilon * 100.0,
        ));
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        const t = 1.0 - c;

        const x = axis.x;
        const y = axis.y;
        const z = axis.z;

        return fromRows(
            Vec4.init(
                t * x * x + c,
                t * x * y - s * z,
                t * x * z + s * y,
                0.0,
            ),
            Vec4.init(
                t * x * y + s * z,
                t * y * y + c,
                t * y * z - s * x,
                0.0,
            ),
            Vec4.init(
                t * x * z - s * y,
                t * y * z + s * x,
                t * z * z + c,
                0.0,
            ),
            Vec4.init(0.0, 0.0, 0.0, 1.0),
        );
    }

    // ── Projection ──────────────────────────────────────────────────────

    /// Right-handed perspective projection, depth mapped to [0, 1].
    pub fn perspective(
        fov_y_rad: f32,
        aspect: f32,
        near: f32,
        far: f32,
    ) Mat4 {
        assert(near > 0.0);
        assert(far > near);
        assert(aspect > 0.0);

        const f = 1.0 / @tan(fov_y_rad * 0.5);
        const m00 = f / aspect;
        const m11 = f;
        const m22 = far / (near - far);
        const m32 = (far * near) / (near - far);

        return fromCols(
            Vec4.init(m00, 0.0, 0.0, 0.0),
            Vec4.init(0.0, m11, 0.0, 0.0),
            Vec4.init(0.0, 0.0, m22, -1.0),
            Vec4.init(0.0, 0.0, m32, 0.0),
        );
    }

    /// Right-handed orthographic projection, depth mapped to [0, 1].
    pub fn orthographic(
        left: f32,
        right_v: f32,
        bottom: f32,
        top_v: f32,
        near: f32,
        far: f32,
    ) Mat4 {
        assert(right_v != left);
        assert(top_v != bottom);
        assert(far > near);

        const m00 = 2.0 / (right_v - left);
        const m11 = 2.0 / (top_v - bottom);
        const m22 = 1.0 / (near - far);
        const m30 = -(right_v + left) / (right_v - left);
        const m31 = -(top_v + bottom) / (top_v - bottom);
        const m32 = near / (near - far);

        return fromRows(
            Vec4.init(m00, 0.0, 0.0, m30),
            Vec4.init(0.0, m11, 0.0, m31),
            Vec4.init(0.0, 0.0, m22, m32),
            Vec4.init(0.0, 0.0, 0.0, 1.0),
        );
    }

    /// Right-handed look-at view matrix.
    pub fn lookAt(eye: Vec3, target: Vec3, up_dir: Vec3) Mat4 {
        const eye_to_target = Vec3.sub(eye, target);
        // eye == target produces a zero vector; normalize would give NaN.
        assert(Vec3.lengthSq(eye_to_target) > 0.0);
        const z_axis = Vec3.normalize(eye_to_target);
        const cross_up_z = Vec3.cross(up_dir, z_axis);
        // up_dir parallel to z_axis produces a zero cross product; normalize would give NaN.
        assert(Vec3.lengthSq(cross_up_z) > 0.0);
        const x_axis = Vec3.normalize(cross_up_z);
        const y_axis = Vec3.cross(z_axis, x_axis);

        return fromCols(
            Vec4.fromVec3(x_axis, 0.0),
            Vec4.fromVec3(y_axis, 0.0),
            Vec4.fromVec3(z_axis, 0.0),
            Vec4.init(
                -Vec3.dot(x_axis, eye),
                -Vec3.dot(y_axis, eye),
                -Vec3.dot(z_axis, eye),
                1.0,
            ),
        );
    }

    // ── Arithmetic ──────────────────────────────────────────────────────

    pub inline fn add(a: Mat4, b: Mat4) Mat4 {
        return .{ .cols = .{
            Vec4.add(a.cols[0], b.cols[0]),
            Vec4.add(a.cols[1], b.cols[1]),
            Vec4.add(a.cols[2], b.cols[2]),
            Vec4.add(a.cols[3], b.cols[3]),
        } };
    }

    pub inline fn sub(a: Mat4, b: Mat4) Mat4 {
        return .{ .cols = .{
            Vec4.sub(a.cols[0], b.cols[0]),
            Vec4.sub(a.cols[1], b.cols[1]),
            Vec4.sub(a.cols[2], b.cols[2]),
            Vec4.sub(a.cols[3], b.cols[3]),
        } };
    }

    pub inline fn scale(m: Mat4, s: f32) Mat4 {
        return .{ .cols = .{
            Vec4.scale(m.cols[0], s),
            Vec4.scale(m.cols[1], s),
            Vec4.scale(m.cols[2], s),
            Vec4.scale(m.cols[3], s),
        } };
    }

    pub inline fn neg(m: Mat4) Mat4 {
        return scale(m, -1.0);
    }

    pub inline fn mul(a: Mat4, b: Mat4) Mat4 {
        return .{ .cols = .{
            mulVec(a, b.cols[0]),
            mulVec(a, b.cols[1]),
            mulVec(a, b.cols[2]),
            mulVec(a, b.cols[3]),
        } };
    }

    pub inline fn mulVec(m: Mat4, v: Vec4) Vec4 {
        return Vec4.add(
            Vec4.add(
                Vec4.add(
                    Vec4.scale(m.cols[0], v.x),
                    Vec4.scale(m.cols[1], v.y),
                ),
                Vec4.scale(m.cols[2], v.z),
            ),
            Vec4.scale(m.cols[3], v.w),
        );
    }

    pub inline fn transpose(m: Mat4) Mat4 {
        return fromCols(row(m, 0), row(m, 1), row(m, 2), row(m, 3));
    }

    /// Determinant via Gaussian elimination with partial pivoting.
    ///
    /// `pivot_product` accumulates the product of diagonal pivots during
    /// elimination. `swap_sign` tracks the parity of row swaps (+1 or -1).
    /// The true determinant is `pivot_product * swap_sign`.
    pub fn determinant(m: Mat4) f32 {
        var a: [4][4]f32 = undefined;
        for (0..4) |r| {
            for (0..4) |c| {
                a[r][c] = at(m, @intCast(r), @intCast(c));
            }
        }

        var pivot_product: f32 = 1.0;
        var swap_sign: f32 = 1.0;

        for (0..4) |i| {
            var pivot_row: usize = i;
            var pivot_abs: f32 = @abs(a[i][i]);
            for (i + 1..4) |r| {
                const v = @abs(a[r][i]);
                if (v > pivot_abs) {
                    pivot_abs = v;
                    pivot_row = r;
                }
            }

            if (pivot_abs == 0.0) return 0.0;

            if (pivot_row != i) {
                const tmp = a[i];
                a[i] = a[pivot_row];
                a[pivot_row] = tmp;
                swap_sign = -swap_sign;
            }

            const pivot = a[i][i];
            pivot_product *= pivot;

            const inv_pivot = 1.0 / pivot;
            for (i + 1..4) |r| {
                const f = a[r][i] * inv_pivot;
                a[r][i] = 0.0;
                for (i + 1..4) |c| {
                    a[r][c] -= f * a[i][c];
                }
            }
        }

        return pivot_product * swap_sign;
    }

    /// Inverse via Gauss-Jordan elimination with partial pivoting.
    /// Returns `null` for singular matrices.
    pub fn inverse(m: Mat4) ?Mat4 {
        // Augmented matrix [M | I].
        var a: [4][8]f32 = undefined;

        for (0..4) |r| {
            for (0..4) |c| {
                a[r][c] = at(m, @intCast(r), @intCast(c));
            }
            for (0..4) |c| {
                a[r][c + 4] = if (c == r) 1.0 else 0.0;
            }
        }

        for (0..4) |i| {
            // Partial pivoting.
            var pivot_row: usize = i;
            var pivot_abs: f32 = @abs(a[i][i]);
            for (i + 1..4) |r| {
                const v = @abs(a[r][i]);
                if (v > pivot_abs) {
                    pivot_abs = v;
                    pivot_row = r;
                }
            }
            if (pivot_abs < scalar.epsilon) return null;

            if (pivot_row != i) {
                const tmp = a[i];
                a[i] = a[pivot_row];
                a[pivot_row] = tmp;
            }

            // Scale pivot row.
            const pivot = a[i][i];
            const inv_pivot = 1.0 / pivot;
            for (0..8) |c| a[i][c] *= inv_pivot;

            // Eliminate column in all other rows.
            for (0..4) |r| {
                if (r == i) continue;
                const f = a[r][i];
                if (f == 0.0) continue;
                for (0..8) |c| {
                    a[r][c] -= f * a[i][c];
                }
            }
        }

        const r0 = Vec4.init(a[0][4], a[0][5], a[0][6], a[0][7]);
        const r1 = Vec4.init(a[1][4], a[1][5], a[1][6], a[1][7]);
        const r2 = Vec4.init(a[2][4], a[2][5], a[2][6], a[2][7]);
        const r3 = Vec4.init(a[3][4], a[3][5], a[3][6], a[3][7]);
        return fromRows(r0, r1, r2, r3);
    }

    // ── Comparison ──────────────────────────────────────────────────────

    /// Compare all 16 elements within `tolerance`.
    pub inline fn approxEqual(a: Mat4, b: Mat4, tolerance: f32) bool {
        assert(tolerance >= 0.0);
        return Vec4.approxEqual(a.cols[0], b.cols[0], tolerance) and
            Vec4.approxEqual(a.cols[1], b.cols[1], tolerance) and
            Vec4.approxEqual(a.cols[2], b.cols[2], tolerance) and
            Vec4.approxEqual(a.cols[3], b.cols[3], tolerance);
    }

    // ── Extraction / conversion ─────────────────────────────────────────

    /// Extract the upper-left 3x3 sub-matrix.
    pub inline fn toMat3(m: Mat4) Mat3 {
        return Mat3.fromCols(
            Vec3.init(m.cols[0].x, m.cols[0].y, m.cols[0].z),
            Vec3.init(m.cols[1].x, m.cols[1].y, m.cols[1].z),
            Vec3.init(m.cols[2].x, m.cols[2].y, m.cols[2].z),
        );
    }

    pub inline fn getTranslation(m: Mat4) Vec3 {
        return Vec3.init(m.cols[3].x, m.cols[3].y, m.cols[3].z);
    }

    pub inline fn getScale(m: Mat4) Vec3 {
        return Vec3.init(
            Vec3.length(Vec3.init(m.cols[0].x, m.cols[0].y, m.cols[0].z)),
            Vec3.length(Vec3.init(m.cols[1].x, m.cols[1].y, m.cols[1].z)),
            Vec3.length(Vec3.init(m.cols[2].x, m.cols[2].y, m.cols[2].z)),
        );
    }

    // ── Transform application ───────────────────────────────────────────

    /// Projective point transform: applies M * (p, 1) then divides by w.
    pub fn transformPoint(m: Mat4, p: Vec3) Vec3 {
        const v = mulVec(m, Vec4.fromVec3(p, 1.0));
        assert(v.w != 0.0);
        const inv_w = 1.0 / v.w;
        return Vec3.init(v.x * inv_w, v.y * inv_w, v.z * inv_w);
    }

    /// Affine point transform: applies M * (p, 1) and takes xyz (no
    /// perspective divide).  Faster than `transformPoint` when the
    /// matrix is known to be affine (bottom row is [0 0 0 1]).
    pub inline fn transformPointAffine(m: Mat4, p: Vec3) Vec3 {
        const v = mulVec(m, Vec4.fromVec3(p, 1.0));
        return Vec3.init(v.x, v.y, v.z);
    }

    /// Direction transform: applies M * (d, 0) -- ignores translation.
    pub inline fn transformDir(m: Mat4, d: Vec3) Vec3 {
        const v = mulVec(m, Vec4.fromVec3(d, 0.0));
        return Vec3.init(v.x, v.y, v.z);
    }

    // ── Decomposition ───────────────────────────────────────────────────

    /// Decompose an affine TRS matrix into translation, rotation, and
    /// scale.  Returns `null` if any scale component is zero or the
    /// upper-left 3x3 contains shear.
    ///
    /// §0 deviation: scale is returned as column lengths, which are always
    /// positive. Negative scale (reflection) is indistinguishable from a
    /// 180-degree rotation and is absorbed into the rotation matrix. Callers
    /// needing sign-preserving decomposition should use the determinant sign
    /// of the 3x3 block to detect reflection and negate one scale axis.
    pub fn decompose(m: Mat4) ?struct {
        translation: Vec3,
        rotation: Mat3,
        scale: Vec3,
    } {
        const translation = getTranslation(m);
        const sc = getScale(m);
        if (sc.x == 0.0 or sc.y == 0.0 or sc.z == 0.0) return null;

        const r0 = Vec3.init(m.cols[0].x, m.cols[0].y, m.cols[0].z)
            .scale(1.0 / sc.x);
        const r1 = Vec3.init(m.cols[1].x, m.cols[1].y, m.cols[1].z)
            .scale(1.0 / sc.y);
        const r2 = Vec3.init(m.cols[2].x, m.cols[2].y, m.cols[2].z)
            .scale(1.0 / sc.z);

        // Reject obvious shear: basis vectors should be orthonormal.
        const tol: f32 = 1.0e-3;
        if (@abs(Vec3.dot(r0, r1)) > tol) return null;
        if (@abs(Vec3.dot(r0, r2)) > tol) return null;
        if (@abs(Vec3.dot(r1, r2)) > tol) return null;

        const rot_m = Mat3.fromCols(r0, r1, r2);
        return .{
            .translation = translation,
            .rotation = rot_m,
            .scale = sc,
        };
    }

    // ── Access ──────────────────────────────────────────────────────────

    pub inline fn at(m: Mat4, row_idx: u2, col_idx: u2) f32 {
        assert(row_idx < 4);
        assert(col_idx < 4);
        return lane(m.cols[@intCast(col_idx)], @intCast(row_idx));
    }

    pub inline fn row(m: Mat4, i: u2) Vec4 {
        assert(i < 4);
        const idx: usize = @intCast(i);
        return .{
            .x = lane(m.cols[0], idx),
            .y = lane(m.cols[1], idx),
            .z = lane(m.cols[2], idx),
            .w = lane(m.cols[3], idx),
        };
    }

    pub inline fn col(m: Mat4, i: u2) Vec4 {
        assert(i < 4);
        return m.cols[@intCast(i)];
    }
};

// ═════════════════════════════════════════════════════════════════════════
// Tests
// ═════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const eps: f32 = 1.0e-5;
const Vec3T = Vec3;
const Vec4T = Vec4;

test "Mat4 identity multiply" {
    const m = Mat4.fromTranslation(Vec3T.init(1.0, 2.0, 3.0));
    const result = Mat4.mul(Mat4.identity, m);
    try testing.expect(Mat4.approxEqual(result, m, eps));

    const result2 = Mat4.mul(m, Mat4.identity);
    try testing.expect(Mat4.approxEqual(result2, m, eps));
}

test "Mat4 perspective depth [0,1]" {
    const near: f32 = 1.0;
    const far: f32 = 11.0;
    const p = Mat4.perspective(scalar.pi / 2.0, 1.0, near, far);

    // Near plane maps to depth 0.
    const v_near = Mat4.mulVec(p, Vec4T.init(0.0, 0.0, -near, 1.0));
    const ndc_near = v_near.z / v_near.w;
    try testing.expectApproxEqAbs(@as(f32, 0.0), ndc_near, eps);

    // Far plane maps to depth 1.
    const v_far = Mat4.mulVec(p, Vec4T.init(0.0, 0.0, -far, 1.0));
    const ndc_far = v_far.z / v_far.w;
    try testing.expectApproxEqAbs(@as(f32, 1.0), ndc_far, eps);
}

test "Mat4 inverse round-trip" {
    const m = Mat4.mul(
        Mat4.fromTranslation(Vec3T.init(1.0, 2.0, 3.0)),
        Mat4.fromRotationZ(0.3),
    );
    const inv = Mat4.inverse(m) orelse
        return error.TestUnexpectedResult;
    const id = Mat4.mul(inv, m);
    try testing.expect(Mat4.approxEqual(id, Mat4.identity, 1.0e-4));
}

test "Mat4 transform builders" {
    // Translation.
    const t = Mat4.fromTranslation(Vec3T.init(5.0, 6.0, 7.0));
    const pt = Mat4.transformPoint(t, Vec3T.zero);
    try testing.expect(Vec3T.approxEqual(pt, Vec3T.init(5.0, 6.0, 7.0), eps));

    // Scale.
    const s = Mat4.fromScale(Vec3T.init(2.0, 3.0, 4.0));
    const ps = Mat4.transformPoint(s, Vec3T.init(1.0, 1.0, 1.0));
    try testing.expect(Vec3T.approxEqual(ps, Vec3T.init(2.0, 3.0, 4.0), eps));

    // Rotation X: rotate unit_y by 90 deg -> unit_z.
    const rx = Mat4.fromRotationX(scalar.pi / 2.0);
    const prx = Mat4.transformDir(rx, Vec3T.unit_y);
    try testing.expect(Vec3T.approxEqual(prx, Vec3T.unit_z, eps));

    // Rotation Y: rotate unit_z by 90 deg -> unit_x.
    const ry = Mat4.fromRotationY(scalar.pi / 2.0);
    const pry = Mat4.transformDir(ry, Vec3T.unit_z);
    try testing.expect(Vec3T.approxEqual(pry, Vec3T.unit_x, eps));

    // Rotation Z: rotate unit_x by 90 deg -> unit_y.
    const rz = Mat4.fromRotationZ(scalar.pi / 2.0);
    const prz = Mat4.transformDir(rz, Vec3T.unit_x);
    try testing.expect(Vec3T.approxEqual(prz, Vec3T.unit_y, eps));
}

test "Mat4 approxEqual" {
    const a = Mat4.identity;
    const b = Mat4.identity;
    try testing.expect(Mat4.approxEqual(a, b, eps));

    // Perturb a single element beyond tolerance.
    var c = Mat4.identity;
    c.cols[1].y = 1.0 + 0.01;
    try testing.expect(!Mat4.approxEqual(a, c, eps));

    // Within tolerance.
    var d = Mat4.identity;
    d.cols[1].y = 1.0 + eps * 0.5;
    try testing.expect(Mat4.approxEqual(a, d, eps));
}

test "Mat4 transformPoint vs transformPointAffine" {
    // For affine matrices (bottom row = [0 0 0 1]) both should agree.
    const m = Mat4.mul(
        Mat4.fromTranslation(Vec3T.init(10.0, 20.0, 30.0)),
        Mat4.fromRotationY(0.7),
    );
    const p = Vec3T.init(1.0, 2.0, 3.0);

    const r1 = Mat4.transformPoint(m, p);
    const r2 = Mat4.transformPointAffine(m, p);
    try testing.expect(Vec3T.approxEqual(r1, r2, eps));
}

test "Mat4 toMat3" {
    const m = Mat4.fromRotationZ(scalar.pi / 4.0);
    const m3 = Mat4.toMat3(m);

    // The upper-left 3x3 of a Z-rotation should match Mat3 values.
    const c = @cos(scalar.pi / 4.0);
    const s = @sin(scalar.pi / 4.0);

    try testing.expectApproxEqAbs(c, m3.cols[0].x, eps);
    try testing.expectApproxEqAbs(s, m3.cols[0].y, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.0), m3.cols[0].z, eps);

    try testing.expectApproxEqAbs(-s, m3.cols[1].x, eps);
    try testing.expectApproxEqAbs(c, m3.cols[1].y, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.0), m3.cols[1].z, eps);

    try testing.expectApproxEqAbs(@as(f32, 0.0), m3.cols[2].x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.0), m3.cols[2].y, eps);
    try testing.expectApproxEqAbs(@as(f32, 1.0), m3.cols[2].z, eps);
}

test "Mat4 decompose" {
    const t = Vec3T.init(3.0, -1.0, 7.0);
    const s = Vec3T.init(2.0, 3.0, 0.5);
    const rot = Mat4.fromRotationY(0.4);

    // Build TRS: T * R * S.
    const m = Mat4.mul(
        Mat4.fromTranslation(t),
        Mat4.mul(rot, Mat4.fromScale(s)),
    );

    const d = Mat4.decompose(m) orelse
        return error.TestUnexpectedResult;

    try testing.expect(Vec3T.approxEqual(d.translation, t, 1.0e-4));
    try testing.expect(Vec3T.approxEqual(d.scale, s, 1.0e-4));

    // Reconstructed rotation should match the original.
    const rot3 = Mat4.toMat3(rot);
    for (0..3) |ci| {
        try testing.expect(Vec3T.approxEqual(
            d.rotation.cols[ci],
            rot3.cols[ci],
            1.0e-4,
        ));
    }
}

test "Mat4 singular inverse returns null" {
    // All-zero matrix is singular.
    try testing.expect(Mat4.inverse(Mat4.zero) == null);

    // Matrix with duplicate rows is singular.
    const singular = Mat4.fromRows(
        Vec4T.init(1.0, 2.0, 3.0, 4.0),
        Vec4T.init(1.0, 2.0, 3.0, 4.0),
        Vec4T.init(5.0, 6.0, 7.0, 8.0),
        Vec4T.init(9.0, 10.0, 11.0, 12.0),
    );
    try testing.expect(Mat4.inverse(singular) == null);
}

test "Mat4 lookAt basic" {
    const eye = Vec3T.init(0.0, 0.0, 5.0);
    const target = Vec3T.zero;
    const up_dir = Vec3T.unit_y;

    const view = Mat4.lookAt(eye, target, up_dir);

    // Eye should map to the origin in view space.
    const origin = Mat4.transformPoint(view, eye);
    try testing.expect(Vec3T.approxEqual(origin, Vec3T.zero, eps));

    // The view matrix should be orthonormal in the upper-left 3x3.
    const m3 = Mat4.toMat3(view);
    const det = mat3_mod.Mat3.determinant(m3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), @abs(det), 1.0e-4);
}
