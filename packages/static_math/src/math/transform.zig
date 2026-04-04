//! Transform - Decomposed 3D transform (Translation, Rotation, Scale)
//!
//! Conventions (RFC-0053):
//! - Right-handed coordinate system.
//! - Application order: Scale -> Rotate -> Translate (SRT).
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
const scalar = @import("scalar.zig");
const vec3_mod = @import("vec3.zig");
const mat3_mod = @import("mat3.zig");
const mat4_mod = @import("mat4.zig");
const quat_mod = @import("quat.zig");

fn normalizeColumnOrFallback(column: vec3_mod.Vec3, fallback: vec3_mod.Vec3) vec3_mod.Vec3 {
    std.debug.assert(vec3_mod.Vec3.lengthSq(fallback) > 0.0);
    const column_len_sq = vec3_mod.Vec3.lengthSq(column);
    if (column_len_sq > 0.0) {
        return vec3_mod.Vec3.scale(column, 1.0 / @sqrt(column_len_sq));
    } else {
        return vec3_mod.Vec3.normalize(fallback);
    }
}

fn perpendicularUnit(dir: vec3_mod.Vec3) vec3_mod.Vec3 {
    std.debug.assert(vec3_mod.Vec3.lengthSq(dir) > 0.0);

    const axis_x = vec3_mod.Vec3.cross(dir, vec3_mod.Vec3.unit_x);
    if (vec3_mod.Vec3.lengthSq(axis_x) > scalar.epsilon) {
        return vec3_mod.Vec3.normalize(axis_x);
    }

    const axis_y = vec3_mod.Vec3.cross(dir, vec3_mod.Vec3.unit_y);
    std.debug.assert(vec3_mod.Vec3.lengthSq(axis_y) > 0.0);
    return vec3_mod.Vec3.normalize(axis_y);
}

pub const Transform = extern struct {
    translation: vec3_mod.Vec3,
    rotation: quat_mod.Quat,
    scale: vec3_mod.Vec3,

    // ── Constants ──────────────────────────────────────────────────────

    pub const identity = Transform{
        .translation = vec3_mod.Vec3.zero,
        .rotation = quat_mod.Quat.identity,
        .scale = vec3_mod.Vec3.one,
    };

    // ── Construction ──────────────────────────────────────────────────

    pub inline fn init(
        translation: vec3_mod.Vec3,
        rotation: quat_mod.Quat,
        s: vec3_mod.Vec3,
    ) Transform {
        return .{ .translation = translation, .rotation = rotation, .scale = s };
    }

    pub inline fn fromTranslation(t: vec3_mod.Vec3) Transform {
        return .{
            .translation = t,
            .rotation = quat_mod.Quat.identity,
            .scale = vec3_mod.Vec3.one,
        };
    }

    pub inline fn fromRotation(r: quat_mod.Quat) Transform {
        return .{
            .translation = vec3_mod.Vec3.zero,
            .rotation = r,
            .scale = vec3_mod.Vec3.one,
        };
    }

    pub inline fn fromScale(s: vec3_mod.Vec3) Transform {
        return .{
            .translation = vec3_mod.Vec3.zero,
            .rotation = quat_mod.Quat.identity,
            .scale = s,
        };
    }

    pub inline fn fromUniformScale(s: f32) Transform {
        return fromScale(vec3_mod.Vec3.splat(s));
    }

    /// Create from Mat4 via decomposition.
    ///
    /// Returns null if matrix contains shear or is non-invertible
    /// for TRS decomposition.
    pub inline fn fromMat4(m: mat4_mod.Mat4) ?Transform {
        const d = mat4_mod.Mat4.decompose(m) orelse return null;
        const r = quat_mod.Quat.normalize(
            quat_mod.Quat.fromMat3(d.rotation),
        );
        return .{ .translation = d.translation, .rotation = r, .scale = d.scale };
    }

    // ── Conversion ────────────────────────────────────────────────────

    pub inline fn toMat4(t: Transform) mat4_mod.Mat4 {
        const tr = mat4_mod.Mat4.fromTranslation(t.translation);
        const r = mat4_mod.Mat4.fromQuat(t.rotation);
        const s = mat4_mod.Mat4.fromScale(t.scale);
        return mat4_mod.Mat4.mul(tr, mat4_mod.Mat4.mul(r, s));
    }

    pub inline fn toMat3(t: Transform) mat3_mod.Mat3 {
        const r = quat_mod.Quat.toMat3(t.rotation);
        const s = mat3_mod.Mat3.diagonal(t.scale);
        return mat3_mod.Mat3.mul(r, s);
    }

    // ── Application ───────────────────────────────────────────────────

    pub inline fn transformPoint(
        t: Transform,
        p: vec3_mod.Vec3,
    ) vec3_mod.Vec3 {
        const scaled = vec3_mod.Vec3.mul(p, t.scale);
        const rotated = quat_mod.Quat.rotate(t.rotation, scaled);
        return vec3_mod.Vec3.add(rotated, t.translation);
    }

    /// Transform a direction (affected by rotation only).
    pub inline fn transformDirection(
        t: Transform,
        d: vec3_mod.Vec3,
    ) vec3_mod.Vec3 {
        return quat_mod.Quat.rotate(t.rotation, d);
    }

    /// Transform a vector (affected by rotation and scale, not translation).
    pub inline fn transformVector(
        t: Transform,
        v: vec3_mod.Vec3,
    ) vec3_mod.Vec3 {
        const scaled = vec3_mod.Vec3.mul(v, t.scale);
        return quat_mod.Quat.rotate(t.rotation, scaled);
    }

    /// Apply the inverse transform to a point.
    ///
    /// Precondition: uniform scale (exact TRS inverse requires it).
    pub inline fn inverseTransformPoint(
        t: Transform,
        p: vec3_mod.Vec3,
    ) vec3_mod.Vec3 {
        // Precondition: uniform scale for exact TRS inverse.
        std.debug.assert(t.scale.x != 0.0);
        // Precondition: scale must be uniform — non-uniform scale requires different
        // handling (the function only uses t.scale.x for the inverse).
        std.debug.assert(t.scale.x == t.scale.y and t.scale.x == t.scale.z);
        const inv_rot = quat_mod.Quat.conjugate(t.rotation);
        const translated = vec3_mod.Vec3.sub(p, t.translation);
        const rotated = quat_mod.Quat.rotate(inv_rot, translated);
        const inv_s = 1.0 / t.scale.x;
        return vec3_mod.Vec3.scale(rotated, inv_s);
    }

    // ── Combination ───────────────────────────────────────────────────

    /// Combine two transforms: result applies `a` then `b`.
    ///
    /// Note: non-uniform scale + rotation can introduce shear; this
    /// returns the best-effort TRS approximation.
    pub fn mul(a: Transform, b: Transform) Transform {
        const m = mat4_mod.Mat4.mul(toMat4(b), toMat4(a));
        const d = mat4_mod.Mat4.decompose(m);
        if (d) |ok| return .{
            .translation = ok.translation,
            .rotation = quat_mod.Quat.normalize(
                quat_mod.Quat.fromMat3(ok.rotation),
            ),
            .scale = ok.scale,
        };

        // §0 escape hatch: decompose rejected the matrix (likely shear from
        // non-uniform scale + rotation composition). We extract the best TRS
        // approximation by dividing each column by its own length, producing
        // a closest-rotation matrix. This loses shear information — callers
        // combining non-uniform scales with rotations should use Mat4 directly
        // when exact results are required.
        const translation = mat4_mod.Mat4.getTranslation(m);
        const scale_v = mat4_mod.Mat4.getScale(m);

        const col0 = vec3_mod.Vec3.init(m.cols[0].x, m.cols[0].y, m.cols[0].z);
        const col1 = vec3_mod.Vec3.init(m.cols[1].x, m.cols[1].y, m.cols[1].z);
        const col2 = vec3_mod.Vec3.init(m.cols[2].x, m.cols[2].y, m.cols[2].z);

        // Divide each column by its own length first, then re-orthogonalize the
        // basis. Per-column normalization preserves axis magnitudes, while
        // Gram-Schmidt strips the shear that `Transform` cannot represent.
        const col0_unit = normalizeColumnOrFallback(col0, vec3_mod.Vec3.unit_x);
        const col1_unit = normalizeColumnOrFallback(col1, vec3_mod.Vec3.unit_y);
        const col2_unit = normalizeColumnOrFallback(col2, vec3_mod.Vec3.unit_z);

        const r0 = col0_unit;
        var r1_candidate = vec3_mod.Vec3.sub(
            col1_unit,
            vec3_mod.Vec3.scale(r0, vec3_mod.Vec3.dot(col1_unit, r0)),
        );
        if (vec3_mod.Vec3.lengthSq(r1_candidate) <= scalar.epsilon) {
            r1_candidate = vec3_mod.Vec3.sub(
                col2_unit,
                vec3_mod.Vec3.scale(r0, vec3_mod.Vec3.dot(col2_unit, r0)),
            );
        }
        const r1 = if (vec3_mod.Vec3.lengthSq(r1_candidate) > scalar.epsilon)
            vec3_mod.Vec3.normalize(r1_candidate)
        else
            perpendicularUnit(r0);
        var r2 = vec3_mod.Vec3.cross(r0, r1);
        std.debug.assert(vec3_mod.Vec3.lengthSq(r2) > 0.0);
        r2 = vec3_mod.Vec3.normalize(r2);
        const aligned_r1 = if (vec3_mod.Vec3.dot(r2, col2_unit) >= 0.0) r1 else vec3_mod.Vec3.neg(r1);
        const aligned_r2 = if (vec3_mod.Vec3.dot(r2, col2_unit) >= 0.0) r2 else vec3_mod.Vec3.neg(r2);

        const rot = quat_mod.Quat.normalize(
            quat_mod.Quat.fromMat3(mat3_mod.Mat3.fromCols(r0, aligned_r1, aligned_r2)),
        );
        return .{ .translation = translation, .rotation = rot, .scale = scale_v };
    }

    // ── Inverse ───────────────────────────────────────────────────────

    /// Exact inverse as a matrix.
    ///
    /// Precondition: all scale components are non-zero (otherwise the
    /// TRS matrix is singular and has no inverse).
    pub fn inverseMat4(t: Transform) mat4_mod.Mat4 {
        std.debug.assert(t.scale.x != 0.0);
        std.debug.assert(t.scale.y != 0.0);
        std.debug.assert(t.scale.z != 0.0);
        const m = toMat4(t);
        // A TRS matrix with non-zero scale is always invertible: the
        // determinant is scale.x * scale.y * scale.z (rotation contributes
        // det=1, translation does not affect the 3x3 block). The assertions
        // above guarantee this.
        return mat4_mod.Mat4.inverse(m) orelse unreachable;
    }

    /// Inverse as a Transform.
    ///
    /// Precondition: uniform, non-zero scale.
    pub fn inverse(t: Transform) Transform {
        std.debug.assert(t.scale.x != 0.0);
        std.debug.assert(t.scale.y != 0.0);
        std.debug.assert(t.scale.z != 0.0);

        // Inverse of a TRS transform is not generally representable as
        // TRS without shear unless the scale is uniform (or rotation is
        // identity). Require uniform scale.
        std.debug.assert(t.scale.x == t.scale.y and t.scale.x == t.scale.z);

        const inv_s: f32 = 1.0 / t.scale.x;
        const inv_scale = vec3_mod.Vec3.splat(inv_s);
        const inv_rot = quat_mod.Quat.inverse(t.rotation);
        const inv_trans = vec3_mod.Vec3.scale(
            quat_mod.Quat.rotate(inv_rot, vec3_mod.Vec3.neg(t.translation)),
            inv_s,
        );
        return .{
            .translation = inv_trans,
            .rotation = inv_rot,
            .scale = inv_scale,
        };
    }

    // ── Interpolation ─────────────────────────────────────────────────

    pub fn lerp(a: Transform, b: Transform, t: f32) Transform {
        return .{
            .translation = vec3_mod.Vec3.lerp(
                a.translation,
                b.translation,
                t,
            ),
            .rotation = quat_mod.Quat.slerp(a.rotation, b.rotation, t),
            .scale = vec3_mod.Vec3.lerp(a.scale, b.scale, t),
        };
    }

    // ── Queries ───────────────────────────────────────────────────────

    pub fn isIdentity(t: Transform, tolerance: f32) bool {
        const dt = vec3_mod.Vec3.length(t.translation);
        if (dt > tolerance) return false;
        if (@abs(t.scale.x - 1.0) > tolerance) return false;
        if (@abs(t.scale.y - 1.0) > tolerance) return false;
        if (@abs(t.scale.z - 1.0) > tolerance) return false;
        return quat_mod.Quat.approxEqual(
            t.rotation,
            quat_mod.Quat.identity,
            tolerance,
        );
    }

    pub fn hasUniformScale(t: Transform, tolerance: f32) bool {
        if (@abs(t.scale.x - t.scale.y) > tolerance) return false;
        if (@abs(t.scale.x - t.scale.z) > tolerance) return false;
        return true;
    }

    // ── Mutation ──────────────────────────────────────────────────────

    pub inline fn translate(t: Transform, delta: vec3_mod.Vec3) Transform {
        return .{
            .translation = vec3_mod.Vec3.add(t.translation, delta),
            .rotation = t.rotation,
            .scale = t.scale,
        };
    }

    pub inline fn translateLocal(
        t: Transform,
        delta: vec3_mod.Vec3,
    ) Transform {
        const world_delta = quat_mod.Quat.rotate(t.rotation, delta);
        return translate(t, world_delta);
    }

    pub inline fn rotate(t: Transform, q: quat_mod.Quat) Transform {
        return .{
            .translation = t.translation,
            .rotation = quat_mod.Quat.mul(q, t.rotation),
            .scale = t.scale,
        };
    }

    pub inline fn rotateLocal(t: Transform, q: quat_mod.Quat) Transform {
        return .{
            .translation = t.translation,
            .rotation = quat_mod.Quat.mul(t.rotation, q),
            .scale = t.scale,
        };
    }

    pub fn lookAt(
        t: Transform,
        target: vec3_mod.Vec3,
        up_dir: vec3_mod.Vec3,
    ) Transform {
        const dir = vec3_mod.Vec3.normalize(
            vec3_mod.Vec3.sub(target, t.translation),
        );
        const r = quat_mod.Quat.lookRotation(dir, up_dir);
        return .{ .translation = t.translation, .rotation = r, .scale = t.scale };
    }

    // ── Basis ─────────────────────────────────────────────────────────

    pub inline fn forward(t: Transform) vec3_mod.Vec3 {
        return quat_mod.Quat.forward(t.rotation);
    }

    pub inline fn right(t: Transform) vec3_mod.Vec3 {
        return quat_mod.Quat.right(t.rotation);
    }

    pub inline fn up(t: Transform) vec3_mod.Vec3 {
        return quat_mod.Quat.up(t.rotation);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;
const Vec3 = vec3_mod.Vec3;
const Quat = quat_mod.Quat;
const Mat4 = mat4_mod.Mat4;
const tol: f32 = 1.0e-4;

fn expectVec3Approx(a: Vec3, b: Vec3, tolerance: f32) !void {
    try testing.expectApproxEqAbs(a.x, b.x, tolerance);
    try testing.expectApproxEqAbs(a.y, b.y, tolerance);
    try testing.expectApproxEqAbs(a.z, b.z, tolerance);
}

fn expectMat4Approx(a: Mat4, b: Mat4, tolerance: f32) !void {
    try testing.expect(Mat4.approxEqual(a, b, tolerance));
}

test "Transform SRT and inverse round-trip" {
    const t = Transform.init(
        Vec3.init(1.0, 2.0, 3.0),
        Quat.fromAxisAngle(Vec3.unit_y, 0.7),
        Vec3.splat(2.0),
    );
    const inv = Transform.inverse(t);

    const p = Vec3.init(-1.0, 0.5, 7.0);
    const out = Transform.transformPoint(inv, Transform.transformPoint(t, p));
    try expectVec3Approx(p, out, tol);
}

test "Transform inverseMat4 round-trip" {
    const t = Transform.init(
        Vec3.init(1.0, 2.0, 3.0),
        Quat.fromAxisAngle(Vec3.unit_y, 0.7),
        Vec3.init(2.0, 3.0, 4.0),
    );
    const inv = Transform.inverseMat4(t);

    const p = Vec3.init(-1.0, 0.5, 7.0);
    const out = Mat4.transformPoint(inv, Transform.transformPoint(t, p));
    try expectVec3Approx(p, out, tol);
}

test "Transform inverseTransformPoint roundtrip" {
    const t = Transform.init(
        Vec3.init(5.0, -3.0, 1.0),
        Quat.fromAxisAngle(Vec3.unit_z, 1.2),
        Vec3.splat(3.0),
    );

    const p = Vec3.init(2.0, -1.0, 4.0);
    const fwd = Transform.transformPoint(t, p);
    const back = Transform.inverseTransformPoint(t, fwd);
    try expectVec3Approx(p, back, tol);
}

test "Transform isIdentity" {
    try testing.expect(Transform.isIdentity(Transform.identity, tol));

    const moved = Transform.init(
        Vec3.init(0.1, 0.0, 0.0),
        Quat.identity,
        Vec3.one,
    );
    try testing.expect(!Transform.isIdentity(moved, tol));
}

test "Transform hasUniformScale" {
    const uniform = Transform.init(
        Vec3.zero,
        Quat.identity,
        Vec3.splat(2.5),
    );
    try testing.expect(Transform.hasUniformScale(uniform, tol));

    const non_uniform = Transform.init(
        Vec3.zero,
        Quat.identity,
        Vec3.init(1.0, 2.0, 3.0),
    );
    try testing.expect(!Transform.hasUniformScale(non_uniform, tol));
}

test "Transform lerp endpoints" {
    const a = Transform.init(
        Vec3.init(0.0, 0.0, 0.0),
        Quat.identity,
        Vec3.splat(1.0),
    );
    const b = Transform.init(
        Vec3.init(10.0, 20.0, 30.0),
        Quat.fromAxisAngle(Vec3.unit_y, 1.0),
        Vec3.splat(5.0),
    );

    const at0 = Transform.lerp(a, b, 0.0);
    try expectVec3Approx(a.translation, at0.translation, tol);
    try expectVec3Approx(a.scale, at0.scale, tol);

    const at1 = Transform.lerp(a, b, 1.0);
    try expectVec3Approx(b.translation, at1.translation, tol);
    try expectVec3Approx(b.scale, at1.scale, tol);
}

test "Transform fromMat4 roundtrip" {
    const t = Transform.init(
        Vec3.init(1.0, 2.0, 3.0),
        Quat.fromAxisAngle(Vec3.unit_y, 0.5),
        Vec3.init(2.0, 2.0, 2.0),
    );
    const m = Transform.toMat4(t);
    const recovered = Transform.fromMat4(m) orelse unreachable;

    try expectVec3Approx(t.translation, recovered.translation, tol);
    try expectVec3Approx(t.scale, recovered.scale, tol);
    try testing.expect(
        Quat.approxEqual(t.rotation, recovered.rotation, tol),
    );
}

test "Transform mul stays exact when composition remains decomposable" {
    const a = Transform.init(
        Vec3.init(1.0, 2.0, 3.0),
        Quat.fromAxisAngle(Vec3.unit_y, 0.4),
        Vec3.splat(2.0),
    );
    const b = Transform.init(
        Vec3.init(-4.0, 1.0, 0.5),
        Quat.fromAxisAngle(Vec3.unit_x, -0.25),
        Vec3.splat(0.5),
    );

    const exact_matrix = Mat4.mul(Transform.toMat4(b), Transform.toMat4(a));
    try testing.expect(Mat4.decompose(exact_matrix) != null);

    const combined = Transform.mul(a, b);
    const combined_matrix = Transform.toMat4(combined);
    try expectMat4Approx(exact_matrix, combined_matrix, tol);

    const p = Vec3.init(0.5, -1.5, 2.0);
    try expectVec3Approx(
        Mat4.transformPoint(exact_matrix, p),
        Transform.transformPoint(combined, p),
        tol,
    );
}

test "Transform mul drops shear when exact composition is not representable" {
    const a = Transform.init(
        Vec3.init(1.0, 2.0, 3.0),
        Quat.fromAxisAngle(Vec3.unit_z, 0.5),
        Vec3.init(2.0, 1.0, 1.0),
    );
    const b = Transform.init(
        Vec3.init(-4.0, 5.0, 1.0),
        Quat.identity,
        Vec3.init(1.0, 3.0, 1.0),
    );

    const exact_matrix = Mat4.mul(Transform.toMat4(b), Transform.toMat4(a));
    try testing.expect(Mat4.decompose(exact_matrix) == null);

    const combined = Transform.mul(a, b);
    const combined_matrix = Transform.toMat4(combined);
    try testing.expect(Mat4.decompose(combined_matrix) != null);
    try testing.expect(!Mat4.approxEqual(exact_matrix, combined_matrix, tol));
    try expectVec3Approx(Mat4.getTranslation(exact_matrix), combined.translation, tol);

    const p = Vec3.init(1.0, -2.0, 0.5);
    const exact_point = Mat4.transformPoint(exact_matrix, p);
    const approx_point = Transform.transformPoint(combined, p);
    try testing.expect(Vec3.distance(exact_point, approx_point) > 1.0e-3);
}

test "Transform translate and translateLocal" {
    const t = Transform.init(
        Vec3.init(1.0, 0.0, 0.0),
        Quat.fromAxisAngle(Vec3.unit_y, scalar.pi * 0.5),
        Vec3.one,
    );

    // World-space translate: just adds the delta directly.
    const moved = Transform.translate(t, Vec3.init(0.0, 0.0, 1.0));
    try expectVec3Approx(
        Vec3.init(1.0, 0.0, 1.0),
        moved.translation,
        tol,
    );

    // Local-space translate: delta is rotated by the transform's rotation
    // first. A +90° Y rotation maps local +Z to world +X.
    const moved_local = Transform.translateLocal(
        t,
        Vec3.init(0.0, 0.0, 1.0),
    );
    try expectVec3Approx(
        Vec3.init(2.0, 0.0, 0.0),
        moved_local.translation,
        tol,
    );
}
