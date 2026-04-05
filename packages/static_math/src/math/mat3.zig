//! Mat3: 3x3 32-bit float matrix.
//!
//! Key operations: `mul`, `mulVec`, `transpose`, `determinant`, `inverse`,
//! `fromRotation`, `fromRotationX/Y/Z`, `fromScale`, `fromTranslation`,
//! `transformPoint2`, `transformDir2`.
//!
//! Conventions:
//! - Column-major storage: `cols[0]` is the first column.
//! - Column-vector multiplication: `v' = M * v`.
//! - Right-handed coordinate system, consistent with Mat4 and Quat.
//!
//! Dual role: 3D rotation/scale matrix (upper-left 3x3 of a TRS) and
//! 2D homogeneous transform matrix (translation in the third column).
//! All operations are pure functions (no mutation). Thread-safe.
//! Preconditions (axis normalization for `fromRotation`, non-singular input
//! for `inverse`) are enforced via `std.debug.assert`.

const std = @import("std");
const assert = std.debug.assert;
const scalar = @import("scalar.zig");
const vec2_mod = @import("vec2.zig");
const vec3_mod = @import("vec3.zig");

pub const Mat3 = extern struct {
    cols: [3]vec3_mod.Vec3,

    comptime {
        // Compile-time invariant: extern struct must be exactly 3 Vec3 columns.
        assert(@sizeOf(Mat3) == 3 * @sizeOf(vec3_mod.Vec3));
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    inline fn lane(v: vec3_mod.Vec3, idx: usize) f32 {
        return switch (idx) {
            0 => v.x,
            1 => v.y,
            2 => v.z,
            else => unreachable,
        };
    }

    // ── Constants ────────────────────────────────────────────────────────

    pub const identity = Mat3{
        .cols = .{
            vec3_mod.Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 },
            vec3_mod.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 },
            vec3_mod.Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 },
        },
    };

    pub const zero = Mat3{
        .cols = .{ vec3_mod.Vec3.zero, vec3_mod.Vec3.zero, vec3_mod.Vec3.zero },
    };

    // ── Construction ─────────────────────────────────────────────────────

    pub inline fn fromCols(
        c0: vec3_mod.Vec3,
        c1: vec3_mod.Vec3,
        c2: vec3_mod.Vec3,
    ) Mat3 {
        return .{ .cols = .{ c0, c1, c2 } };
    }

    pub inline fn fromRows(
        r0: vec3_mod.Vec3,
        r1: vec3_mod.Vec3,
        r2: vec3_mod.Vec3,
    ) Mat3 {
        return .{
            .cols = .{
                vec3_mod.Vec3.init(r0.x, r1.x, r2.x),
                vec3_mod.Vec3.init(r0.y, r1.y, r2.y),
                vec3_mod.Vec3.init(r0.z, r1.z, r2.z),
            },
        };
    }

    pub inline fn diagonal(d: vec3_mod.Vec3) Mat3 {
        return .{
            .cols = .{
                vec3_mod.Vec3.init(d.x, 0.0, 0.0),
                vec3_mod.Vec3.init(0.0, d.y, 0.0),
                vec3_mod.Vec3.init(0.0, 0.0, d.z),
            },
        };
    }

    // ── 3D Rotation Builders ─────────────────────────────────────────────

    /// Axis-angle rotation (Rodrigues' formula).
    /// Precondition: `axis` must be normalized.
    pub inline fn fromRotation(axis: vec3_mod.Vec3, angle_rad: f32) Mat3 {
        assert(vec3_mod.Vec3.approxEqual(
            vec3_mod.Vec3.splat(axis.lengthSq()),
            vec3_mod.Vec3.one,
            scalar.epsilon * 100.0,
        ));

        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        const t = 1.0 - c;

        const x = axis.x;
        const y = axis.y;
        const z = axis.z;

        return .{ .cols = .{
            vec3_mod.Vec3.init(t * x * x + c, t * x * y + s * z, t * x * z - s * y),
            vec3_mod.Vec3.init(t * x * y - s * z, t * y * y + c, t * y * z + s * x),
            vec3_mod.Vec3.init(t * x * z + s * y, t * y * z - s * x, t * z * z + c),
        } };
    }

    /// Rotation about the X axis.
    pub inline fn fromRotationX(angle_rad: f32) Mat3 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return fromRows(
            vec3_mod.Vec3.init(1.0, 0.0, 0.0),
            vec3_mod.Vec3.init(0.0, c, -s),
            vec3_mod.Vec3.init(0.0, s, c),
        );
    }

    /// Rotation about the Y axis.
    pub inline fn fromRotationY(angle_rad: f32) Mat3 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return fromRows(
            vec3_mod.Vec3.init(c, 0.0, s),
            vec3_mod.Vec3.init(0.0, 1.0, 0.0),
            vec3_mod.Vec3.init(-s, 0.0, c),
        );
    }

    /// Rotation about the Z axis.
    pub inline fn fromRotationZ(angle_rad: f32) Mat3 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return fromRows(
            vec3_mod.Vec3.init(c, -s, 0.0),
            vec3_mod.Vec3.init(s, c, 0.0),
            vec3_mod.Vec3.init(0.0, 0.0, 1.0),
        );
    }

    /// 3D scale diagonal matrix.
    pub inline fn fromScale3(s: vec3_mod.Vec3) Mat3 {
        return diagonal(s);
    }

    // ── 2D Transform Builders (homogeneous coordinates) ──────────────────

    /// 2D scale in homogeneous coordinates.
    pub inline fn fromScale(s: vec2_mod.Vec2) Mat3 {
        return .{
            .cols = .{
                vec3_mod.Vec3.init(s.x, 0.0, 0.0),
                vec3_mod.Vec3.init(0.0, s.y, 0.0),
                vec3_mod.Vec3.init(0.0, 0.0, 1.0),
            },
        };
    }

    /// 2D rotation in homogeneous coordinates.
    pub inline fn fromRotation2D(angle_rad: f32) Mat3 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return .{
            .cols = .{
                vec3_mod.Vec3.init(c, s, 0.0),
                vec3_mod.Vec3.init(-s, c, 0.0),
                vec3_mod.Vec3.init(0.0, 0.0, 1.0),
            },
        };
    }

    /// 2D translation in homogeneous coordinates.
    pub inline fn fromTranslation(t: vec2_mod.Vec2) Mat3 {
        return .{
            .cols = .{
                vec3_mod.Vec3.init(1.0, 0.0, 0.0),
                vec3_mod.Vec3.init(0.0, 1.0, 0.0),
                vec3_mod.Vec3.init(t.x, t.y, 1.0),
            },
        };
    }

    // ── Access ───────────────────────────────────────────────────────────

    pub inline fn col(m: Mat3, i: u2) vec3_mod.Vec3 {
        assert(i < 3);
        return m.cols[@intCast(i)];
    }

    pub inline fn row(m: Mat3, i: u2) vec3_mod.Vec3 {
        assert(i < 3);
        const idx: usize = @intCast(i);
        return .{
            .x = lane(m.cols[0], idx),
            .y = lane(m.cols[1], idx),
            .z = lane(m.cols[2], idx),
        };
    }

    pub inline fn at(m: Mat3, row_idx: u2, col_idx: u2) f32 {
        assert(row_idx < 3);
        assert(col_idx < 3);
        return lane(m.cols[@intCast(col_idx)], @intCast(row_idx));
    }

    // ── Operations ──────────────────────────────────────────────────────

    pub inline fn add(a: Mat3, b: Mat3) Mat3 {
        return .{ .cols = .{
            vec3_mod.Vec3.add(a.cols[0], b.cols[0]),
            vec3_mod.Vec3.add(a.cols[1], b.cols[1]),
            vec3_mod.Vec3.add(a.cols[2], b.cols[2]),
        } };
    }

    pub inline fn sub(a: Mat3, b: Mat3) Mat3 {
        return .{ .cols = .{
            vec3_mod.Vec3.sub(a.cols[0], b.cols[0]),
            vec3_mod.Vec3.sub(a.cols[1], b.cols[1]),
            vec3_mod.Vec3.sub(a.cols[2], b.cols[2]),
        } };
    }

    pub inline fn scale(m: Mat3, s: f32) Mat3 {
        return .{ .cols = .{
            vec3_mod.Vec3.scale(m.cols[0], s),
            vec3_mod.Vec3.scale(m.cols[1], s),
            vec3_mod.Vec3.scale(m.cols[2], s),
        } };
    }

    pub inline fn neg(m: Mat3) Mat3 {
        return scale(m, -1.0);
    }

    pub inline fn mul(a: Mat3, b: Mat3) Mat3 {
        return .{ .cols = .{
            mulVec(a, b.cols[0]),
            mulVec(a, b.cols[1]),
            mulVec(a, b.cols[2]),
        } };
    }

    pub inline fn mulVec(m: Mat3, v: vec3_mod.Vec3) vec3_mod.Vec3 {
        return vec3_mod.Vec3.add(
            vec3_mod.Vec3.add(
                vec3_mod.Vec3.scale(m.cols[0], v.x),
                vec3_mod.Vec3.scale(m.cols[1], v.y),
            ),
            vec3_mod.Vec3.scale(m.cols[2], v.z),
        );
    }

    pub inline fn transpose(m: Mat3) Mat3 {
        return fromCols(row(m, 0), row(m, 1), row(m, 2));
    }

    pub inline fn determinant(m: Mat3) f32 {
        const a00 = at(m, 0, 0);
        const a01 = at(m, 0, 1);
        const a02 = at(m, 0, 2);
        const a10 = at(m, 1, 0);
        const a11 = at(m, 1, 1);
        const a12 = at(m, 1, 2);
        const a20 = at(m, 2, 0);
        const a21 = at(m, 2, 1);
        const a22 = at(m, 2, 2);
        return a00 * (a11 * a22 - a12 * a21) -
            a01 * (a10 * a22 - a12 * a20) +
            a02 * (a10 * a21 - a11 * a20);
    }

    /// Returns null when the matrix is singular (|det| < epsilon).
    pub inline fn inverse(m: Mat3) ?Mat3 {
        const det = determinant(m);
        if (@abs(det) < scalar.epsilon) return null;
        const inv_det = 1.0 / det;

        const a00 = at(m, 0, 0);
        const a01 = at(m, 0, 1);
        const a02 = at(m, 0, 2);
        const a10 = at(m, 1, 0);
        const a11 = at(m, 1, 1);
        const a12 = at(m, 1, 2);
        const a20 = at(m, 2, 0);
        const a21 = at(m, 2, 1);
        const a22 = at(m, 2, 2);

        // Adjugate / determinant.
        const r0 = vec3_mod.Vec3.init(
            (a11 * a22 - a12 * a21) * inv_det,
            (a02 * a21 - a01 * a22) * inv_det,
            (a01 * a12 - a02 * a11) * inv_det,
        );
        const r1 = vec3_mod.Vec3.init(
            (a12 * a20 - a10 * a22) * inv_det,
            (a00 * a22 - a02 * a20) * inv_det,
            (a02 * a10 - a00 * a12) * inv_det,
        );
        const r2 = vec3_mod.Vec3.init(
            (a10 * a21 - a11 * a20) * inv_det,
            (a01 * a20 - a00 * a21) * inv_det,
            (a00 * a11 - a01 * a10) * inv_det,
        );
        return fromRows(r0, r1, r2);
    }

    // ── Comparison ──────────────────────────────────────────────────────

    /// Component-wise approximate equality of all 9 elements.
    pub inline fn approxEqual(a: Mat3, b: Mat3, tolerance: f32) bool {
        assert(tolerance >= 0.0);
        return vec3_mod.Vec3.approxEqual(a.cols[0], b.cols[0], tolerance) and
            vec3_mod.Vec3.approxEqual(a.cols[1], b.cols[1], tolerance) and
            vec3_mod.Vec3.approxEqual(a.cols[2], b.cols[2], tolerance);
    }

    // ── 2D Transform Application ────────────────────────────────────────

    /// Transform a 2D point (w = 1) through the 3x3 homogeneous matrix.
    pub inline fn transformPoint2(m: Mat3, p: vec2_mod.Vec2) vec2_mod.Vec2 {
        const v = mulVec(m, vec3_mod.Vec3.init(p.x, p.y, 1.0));
        return .{ .x = v.x, .y = v.y };
    }

    /// Transform a 2D direction (w = 0) through the 3x3 homogeneous matrix.
    pub inline fn transformDir2(m: Mat3, d: vec2_mod.Vec2) vec2_mod.Vec2 {
        const v = mulVec(m, vec3_mod.Vec3.init(d.x, d.y, 0.0));
        return .{ .x = v.x, .y = v.y };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const eps = scalar.epsilon;
const Vec2 = vec2_mod.Vec2;
const Vec3 = vec3_mod.Vec3;

test "Mat3 identity multiply" {
    const v = Vec3.init(1.0, 2.0, 3.0);
    const result = Mat3.mulVec(Mat3.identity, v);
    try testing.expect(Vec3.approxEqual(result, v, eps));
}

test "Mat3 2D transforms" {
    const p = Vec2.init(1.0, 2.0);

    // Translation.
    const t = Mat3.fromTranslation(Vec2.init(5.0, -3.0));
    const tp = Mat3.transformPoint2(t, p);
    try testing.expectApproxEqAbs(@as(f32, 6.0), tp.x, eps);
    try testing.expectApproxEqAbs(@as(f32, -1.0), tp.y, eps);

    // Translation should not affect directions.
    const td = Mat3.transformDir2(t, p);
    try testing.expectApproxEqAbs(@as(f32, 1.0), td.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 2.0), td.y, eps);

    // Scale.
    const s = Mat3.fromScale(Vec2.init(2.0, 3.0));
    const sp = Mat3.transformPoint2(s, p);
    try testing.expectApproxEqAbs(@as(f32, 2.0), sp.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 6.0), sp.y, eps);

    // 2D Rotation (90 degrees CCW).
    const r = Mat3.fromRotation2D(scalar.pi / 2.0);
    const rp = Mat3.transformPoint2(r, Vec2.unit_x);
    try testing.expectApproxEqAbs(@as(f32, 0.0), rp.x, 1.0e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), rp.y, 1.0e-5);
}

test "Mat3 inverse round-trip" {
    const m = Mat3.mul(
        Mat3.fromTranslation(Vec2.init(3.0, 4.0)),
        Mat3.fromScale(Vec2.init(2.0, 5.0)),
    );
    const inv = Mat3.inverse(m) orelse return error.TestUnexpectedResult;
    const round = Mat3.mul(inv, m);
    try testing.expect(Mat3.approxEqual(round, Mat3.identity, 1.0e-4));
}

test "Mat3 singular inverse" {
    // All-zero matrix is singular.
    try testing.expect(Mat3.inverse(Mat3.zero) == null);

    // Matrix with two identical columns is singular.
    const singular = Mat3.fromCols(
        Vec3.init(1.0, 2.0, 3.0),
        Vec3.init(1.0, 2.0, 3.0),
        Vec3.init(4.0, 5.0, 6.0),
    );
    try testing.expect(Mat3.inverse(singular) == null);
}

test "Mat3 transpose" {
    const m = Mat3.fromCols(
        Vec3.init(1.0, 2.0, 3.0),
        Vec3.init(4.0, 5.0, 6.0),
        Vec3.init(7.0, 8.0, 9.0),
    );
    const tt = Mat3.transpose(Mat3.transpose(m));
    try testing.expect(Mat3.approxEqual(tt, m, eps));
}

test "Mat3 determinant" {
    // det of identity = 1.
    try testing.expectApproxEqAbs(@as(f32, 1.0), Mat3.determinant(Mat3.identity), eps);

    // Known matrix: [[1,2,3],[0,1,4],[5,6,0]]
    const m = Mat3.fromRows(
        Vec3.init(1.0, 2.0, 3.0),
        Vec3.init(0.0, 1.0, 4.0),
        Vec3.init(5.0, 6.0, 0.0),
    );
    // det = 1*(0-24) - 2*(0-20) + 3*(0-5) = -24 + 40 - 15 = 1
    try testing.expectApproxEqAbs(@as(f32, 1.0), Mat3.determinant(m), eps);
}

test "Mat3 fromRows/fromCols consistency" {
    const r0 = Vec3.init(1.0, 2.0, 3.0);
    const r1 = Vec3.init(4.0, 5.0, 6.0);
    const r2 = Vec3.init(7.0, 8.0, 9.0);

    const from_rows = Mat3.fromRows(r0, r1, r2);
    const from_cols = Mat3.fromCols(r0, r1, r2);

    // fromRows(v0,v1,v2) == transpose(fromCols(v0,v1,v2))
    try testing.expect(Mat3.approxEqual(from_rows, Mat3.transpose(from_cols), eps));
}

test "Mat3 approxEqual" {
    const a = Mat3.identity;
    const b = Mat3.identity;
    try testing.expect(Mat3.approxEqual(a, b, eps));

    // Slightly perturbed.
    var c = Mat3.identity;
    c.cols[0].x = 1.0 + eps * 0.5;
    try testing.expect(Mat3.approxEqual(a, c, eps));

    // Outside tolerance.
    var d = Mat3.identity;
    d.cols[0].x = 1.0 + 0.01;
    try testing.expect(!Mat3.approxEqual(a, d, eps));
}

test "Mat3 3D rotation builders" {
    const tol: f32 = 1.0e-5;
    const half_pi = scalar.pi / 2.0;

    // fromRotationX: rotates Y towards Z.
    {
        const rx = Mat3.fromRotationX(half_pi);
        const v = Mat3.mulVec(rx, Vec3.unit_y);
        try testing.expectApproxEqAbs(@as(f32, 0.0), v.x, tol);
        try testing.expectApproxEqAbs(@as(f32, 0.0), v.y, tol);
        try testing.expectApproxEqAbs(@as(f32, 1.0), v.z, tol);
    }

    // fromRotationY: rotates Z towards X.
    {
        const ry = Mat3.fromRotationY(half_pi);
        const v = Mat3.mulVec(ry, Vec3.unit_z);
        try testing.expectApproxEqAbs(@as(f32, 1.0), v.x, tol);
        try testing.expectApproxEqAbs(@as(f32, 0.0), v.y, tol);
        try testing.expectApproxEqAbs(@as(f32, 0.0), v.z, tol);
    }

    // fromRotationZ: rotates X towards Y.
    {
        const rz = Mat3.fromRotationZ(half_pi);
        const v = Mat3.mulVec(rz, Vec3.unit_x);
        try testing.expectApproxEqAbs(@as(f32, 0.0), v.x, tol);
        try testing.expectApproxEqAbs(@as(f32, 1.0), v.y, tol);
        try testing.expectApproxEqAbs(@as(f32, 0.0), v.z, tol);
    }

    // fromRotation (axis-angle): rotating around Z by 90 should match fromRotationZ.
    {
        const rz_axis = Mat3.fromRotation(Vec3.unit_z, half_pi);
        const rz_direct = Mat3.fromRotationZ(half_pi);
        try testing.expect(Mat3.approxEqual(rz_axis, rz_direct, tol));
    }

    // fromRotation around an arbitrary axis: 360 degrees returns identity.
    {
        const axis = Vec3.normalize(Vec3.init(1.0, 1.0, 1.0));
        const full = Mat3.fromRotation(axis, scalar.tau);
        try testing.expect(Mat3.approxEqual(full, Mat3.identity, tol));
    }

    // fromScale3: diagonal scaling.
    {
        const s = Mat3.fromScale3(Vec3.init(2.0, 3.0, 4.0));
        const v = Mat3.mulVec(s, Vec3.init(1.0, 1.0, 1.0));
        try testing.expectApproxEqAbs(@as(f32, 2.0), v.x, tol);
        try testing.expectApproxEqAbs(@as(f32, 3.0), v.y, tol);
        try testing.expectApproxEqAbs(@as(f32, 4.0), v.z, tol);
    }
}
