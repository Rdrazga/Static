//! Spatial primitive types: AABB2, AABB3, Sphere, Ray3, Ray3Precomputed, Plane, Frustum,
//! GridConfig, and GridConfig3D.
//!
//! All types are `extern struct` (except Frustum) to guarantee predictable field layout
//! for FFI and SIMD use. Constructors assert geometric validity in debug builds;
//! `tryInit` / `tryFromCenterExtent` variants return `null` for invalid inputs and
//! reject NaN via negated IEEE comparisons.
//!
//! AABB2 and AABB3 each expose an `empty` constant — an inverted AABB suitable as the
//! identity element for merge-grow accumulation patterns.
//!
//! Thread safety: all types are value types with no shared state.
const std = @import("std");

const epsilon: f32 = 1.0e-6;

// ---------------------------------------------------------------------------
// AABB2
// ---------------------------------------------------------------------------

pub const Point2 = struct { x: f32, y: f32 };
pub const Point3 = struct { x: f32, y: f32, z: f32 };

pub const AABB2 = extern struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub inline fn init(min_x: f32, min_y: f32, max_x: f32, max_y: f32) AABB2 {
        std.debug.assert(min_x <= max_x);
        std.debug.assert(min_y <= max_y);
        return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
    }

    /// Non-asserting constructor for boundary-facing code. Returns `null`
    /// when the invariant `min <= max` is violated.
    pub inline fn tryInit(min_x: f32, min_y: f32, max_x: f32, max_y: f32) ?AABB2 {
        // Negated <= rejects NaN (IEEE 754: NaN comparisons are false).
        if (!(min_x <= max_x) or !(min_y <= max_y)) return null;
        return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
    }

    pub inline fn fromCenterExtent(cx: f32, cy: f32, half_w: f32, half_h: f32) AABB2 {
        std.debug.assert(half_w >= 0.0);
        std.debug.assert(half_h >= 0.0);
        return .{
            .min_x = cx - half_w,
            .min_y = cy - half_h,
            .max_x = cx + half_w,
            .max_y = cy + half_h,
        };
    }

    /// Non-asserting `fromCenterExtent` for boundary-facing code.
    pub inline fn tryFromCenterExtent(cx: f32, cy: f32, half_w: f32, half_h: f32) ?AABB2 {
        // Negated >= rejects NaN.
        if (!(half_w >= 0.0) or !(half_h >= 0.0)) return null;
        return .{
            .min_x = cx - half_w,
            .min_y = cy - half_h,
            .max_x = cx + half_w,
            .max_y = cy + half_h,
        };
    }

    /// Compute the minimal enclosing AABB for a set of points.
    /// Precondition: `points` must be non-empty.
    pub inline fn fromPoints(points: []const Point2) AABB2 {
        std.debug.assert(points.len > 0);
        var result = AABB2{
            .min_x = points[0].x,
            .min_y = points[0].y,
            .max_x = points[0].x,
            .max_y = points[0].y,
        };
        for (points[1..]) |p| {
            result.min_x = @min(result.min_x, p.x);
            result.min_y = @min(result.min_y, p.y);
            result.max_x = @max(result.max_x, p.x);
            result.max_y = @max(result.max_y, p.y);
        }
        std.debug.assert(result.min_x <= result.max_x);
        std.debug.assert(result.min_y <= result.max_y);
        return result;
    }

    pub inline fn contains(self: AABB2, x: f32, y: f32) bool {
        return x >= self.min_x and x <= self.max_x and
            y >= self.min_y and y <= self.max_y;
    }

    pub inline fn intersects(self: AABB2, other: AABB2) bool {
        return self.min_x <= other.max_x and self.max_x >= other.min_x and
            self.min_y <= other.max_y and self.max_y >= other.min_y;
    }

    pub inline fn containsAABB(self: AABB2, other: AABB2) bool {
        return other.min_x >= self.min_x and other.max_x <= self.max_x and
            other.min_y >= self.min_y and other.max_y <= self.max_y;
    }

    pub inline fn width(self: AABB2) f32 {
        return self.max_x - self.min_x;
    }

    pub inline fn height(self: AABB2) f32 {
        return self.max_y - self.min_y;
    }

    pub inline fn area(self: AABB2) f32 {
        return self.width() * self.height();
    }

    pub inline fn center(self: AABB2) struct { x: f32, y: f32 } {
        return .{
            .x = (self.min_x + self.max_x) * 0.5,
            .y = (self.min_y + self.max_y) * 0.5,
        };
    }

    pub inline fn extents(self: AABB2) struct { half_w: f32, half_h: f32 } {
        return .{
            .half_w = (self.max_x - self.min_x) * 0.5,
            .half_h = (self.max_y - self.min_y) * 0.5,
        };
    }

    pub inline fn merge(a: AABB2, b: AABB2) AABB2 {
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
        };
    }

    pub inline fn expand(self: AABB2, x: f32, y: f32) AABB2 {
        return .{
            .min_x = @min(self.min_x, x),
            .min_y = @min(self.min_y, y),
            .max_x = @max(self.max_x, x),
            .max_y = @max(self.max_y, y),
        };
    }

    pub inline fn pad(self: AABB2, margin: f32) AABB2 {
        return .{
            .min_x = self.min_x - margin,
            .min_y = self.min_y - margin,
            .max_x = self.max_x + margin,
            .max_y = self.max_y + margin,
        };
    }

    /// Identity element for merge-grow patterns: an inverted AABB where min > max.
    ///
    /// Merging any valid AABB with `empty` produces the valid AABB unchanged.
    /// Uses `floatMax` rather than infinity to avoid IEEE edge cases in
    /// arithmetic (e.g. `inf - inf = NaN`).
    pub const empty: AABB2 = .{
        .min_x = std.math.floatMax(f32),
        .min_y = std.math.floatMax(f32),
        .max_x = -std.math.floatMax(f32),
        .max_y = -std.math.floatMax(f32),
    };
};

// ---------------------------------------------------------------------------
// AABB3
// ---------------------------------------------------------------------------

pub const AABB3 = extern struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,

    pub inline fn init(
        min_x: f32,
        min_y: f32,
        min_z: f32,
        max_x: f32,
        max_y: f32,
        max_z: f32,
    ) AABB3 {
        std.debug.assert(min_x <= max_x);
        std.debug.assert(min_y <= max_y);
        std.debug.assert(min_z <= max_z);
        return .{
            .min_x = min_x, .min_y = min_y, .min_z = min_z,
            .max_x = max_x, .max_y = max_y, .max_z = max_z,
        };
    }

    /// Non-asserting constructor for boundary-facing code.
    pub inline fn tryInit(
        min_x: f32,
        min_y: f32,
        min_z: f32,
        max_x: f32,
        max_y: f32,
        max_z: f32,
    ) ?AABB3 {
        // Negated <= rejects NaN (IEEE 754: NaN comparisons are false).
        if (!(min_x <= max_x) or !(min_y <= max_y) or !(min_z <= max_z)) return null;
        return .{
            .min_x = min_x, .min_y = min_y, .min_z = min_z,
            .max_x = max_x, .max_y = max_y, .max_z = max_z,
        };
    }

    pub inline fn fromCenterExtent(
        cx: f32,
        cy: f32,
        cz: f32,
        hx: f32,
        hy: f32,
        hz: f32,
    ) AABB3 {
        std.debug.assert(hx >= 0.0);
        std.debug.assert(hy >= 0.0);
        std.debug.assert(hz >= 0.0);
        return .{
            .min_x = cx - hx, .min_y = cy - hy, .min_z = cz - hz,
            .max_x = cx + hx, .max_y = cy + hy, .max_z = cz + hz,
        };
    }

    /// Non-asserting `fromCenterExtent` for boundary-facing code.
    pub inline fn tryFromCenterExtent(
        cx: f32,
        cy: f32,
        cz: f32,
        hx: f32,
        hy: f32,
        hz: f32,
    ) ?AABB3 {
        // Negated >= rejects NaN.
        if (!(hx >= 0.0) or !(hy >= 0.0) or !(hz >= 0.0)) return null;
        return .{
            .min_x = cx - hx, .min_y = cy - hy, .min_z = cz - hz,
            .max_x = cx + hx, .max_y = cy + hy, .max_z = cz + hz,
        };
    }

    /// Compute the minimal enclosing AABB for a set of points.
    /// Precondition: `points` must be non-empty.
    pub inline fn fromPoints(points: []const Point3) AABB3 {
        std.debug.assert(points.len > 0);
        var result = AABB3{
            .min_x = points[0].x, .min_y = points[0].y, .min_z = points[0].z,
            .max_x = points[0].x, .max_y = points[0].y, .max_z = points[0].z,
        };
        for (points[1..]) |p| {
            result.min_x = @min(result.min_x, p.x);
            result.min_y = @min(result.min_y, p.y);
            result.min_z = @min(result.min_z, p.z);
            result.max_x = @max(result.max_x, p.x);
            result.max_y = @max(result.max_y, p.y);
            result.max_z = @max(result.max_z, p.z);
        }
        std.debug.assert(result.min_x <= result.max_x);
        std.debug.assert(result.min_y <= result.max_y);
        std.debug.assert(result.min_z <= result.max_z);
        return result;
    }

    /// Construct an AABB enclosing a sphere.
    pub inline fn fromSphere(s: Sphere) AABB3 {
        std.debug.assert(s.radius >= 0.0);
        return .{
            .min_x = s.center_x - s.radius,
            .min_y = s.center_y - s.radius,
            .min_z = s.center_z - s.radius,
            .max_x = s.center_x + s.radius,
            .max_y = s.center_y + s.radius,
            .max_z = s.center_z + s.radius,
        };
    }

    /// Construct from min/max as 3-element arrays (Vec3 convenience).
    pub inline fn fromMinMax(min_v: [3]f32, max_v: [3]f32) AABB3 {
        std.debug.assert(min_v[0] <= max_v[0]);
        std.debug.assert(min_v[1] <= max_v[1]);
        std.debug.assert(min_v[2] <= max_v[2]);
        return .{
            .min_x = min_v[0], .min_y = min_v[1], .min_z = min_v[2],
            .max_x = max_v[0], .max_y = max_v[1], .max_z = max_v[2],
        };
    }

    /// Compute a world-space AABB that encloses this AABB after
    /// transformation by a 4x4 matrix (Arvo's method).
    ///
    /// The matrix is column-major: `m[col][row]` where each column
    /// is an array of 4 floats.
    pub inline fn transform(self: AABB3, m: [4][4]f32) AABB3 {
        // Start with the translation column.
        var new_min = [3]f32{ m[3][0], m[3][1], m[3][2] };
        var new_max = [3]f32{ m[3][0], m[3][1], m[3][2] };

        const self_min = [3]f32{ self.min_x, self.min_y, self.min_z };
        const self_max = [3]f32{ self.max_x, self.max_y, self.max_z };

        // For each matrix column (0..2) and each output row (0..2),
        // accumulate the min/max contribution.
        inline for (0..3) |col| {
            inline for (0..3) |row| {
                const a = m[col][row] * self_min[col];
                const b = m[col][row] * self_max[col];
                new_min[row] += @min(a, b);
                new_max[row] += @max(a, b);
            }
        }

        const result = AABB3{
            .min_x = new_min[0], .min_y = new_min[1], .min_z = new_min[2],
            .max_x = new_max[0], .max_y = new_max[1], .max_z = new_max[2],
        };
        std.debug.assert(result.min_x <= result.max_x);
        std.debug.assert(result.min_y <= result.max_y);
        std.debug.assert(result.min_z <= result.max_z);
        return result;
    }

    pub inline fn contains(self: AABB3, x: f32, y: f32, z: f32) bool {
        return x >= self.min_x and x <= self.max_x and
            y >= self.min_y and y <= self.max_y and
            z >= self.min_z and z <= self.max_z;
    }

    pub inline fn intersects(self: AABB3, other: AABB3) bool {
        return self.min_x <= other.max_x and self.max_x >= other.min_x and
            self.min_y <= other.max_y and self.max_y >= other.min_y and
            self.min_z <= other.max_z and self.max_z >= other.min_z;
    }

    pub inline fn containsAABB(self: AABB3, other: AABB3) bool {
        return other.min_x >= self.min_x and other.max_x <= self.max_x and
            other.min_y >= self.min_y and other.max_y <= self.max_y and
            other.min_z >= self.min_z and other.max_z <= self.max_z;
    }

    pub inline fn closestPoint(
        self: AABB3,
        x: f32,
        y: f32,
        z: f32,
    ) struct { x: f32, y: f32, z: f32 } {
        return .{
            .x = @max(self.min_x, @min(x, self.max_x)),
            .y = @max(self.min_y, @min(y, self.max_y)),
            .z = @max(self.min_z, @min(z, self.max_z)),
        };
    }

    pub inline fn width(self: AABB3) f32 {
        return self.max_x - self.min_x;
    }

    pub inline fn height(self: AABB3) f32 {
        return self.max_y - self.min_y;
    }

    pub inline fn depth(self: AABB3) f32 {
        return self.max_z - self.min_z;
    }

    pub inline fn volume(self: AABB3) f32 {
        return self.width() * self.height() * self.depth();
    }

    pub inline fn surfaceArea(self: AABB3) f32 {
        const w = self.width();
        const h = self.height();
        const d = self.depth();
        return 2.0 * (w * h + w * d + h * d);
    }

    pub inline fn center(self: AABB3) struct { x: f32, y: f32, z: f32 } {
        return .{
            .x = (self.min_x + self.max_x) * 0.5,
            .y = (self.min_y + self.max_y) * 0.5,
            .z = (self.min_z + self.max_z) * 0.5,
        };
    }

    pub inline fn extents(self: AABB3) struct { hx: f32, hy: f32, hz: f32 } {
        return .{
            .hx = (self.max_x - self.min_x) * 0.5,
            .hy = (self.max_y - self.min_y) * 0.5,
            .hz = (self.max_z - self.min_z) * 0.5,
        };
    }

    pub inline fn merge(a: AABB3, b: AABB3) AABB3 {
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .min_z = @min(a.min_z, b.min_z),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
            .max_z = @max(a.max_z, b.max_z),
        };
    }

    pub inline fn expand(self: AABB3, x: f32, y: f32, z: f32) AABB3 {
        return .{
            .min_x = @min(self.min_x, x),
            .min_y = @min(self.min_y, y),
            .min_z = @min(self.min_z, z),
            .max_x = @max(self.max_x, x),
            .max_y = @max(self.max_y, y),
            .max_z = @max(self.max_z, z),
        };
    }

    pub inline fn pad(self: AABB3, margin: f32) AABB3 {
        return .{
            .min_x = self.min_x - margin,
            .min_y = self.min_y - margin,
            .min_z = self.min_z - margin,
            .max_x = self.max_x + margin,
            .max_y = self.max_y + margin,
            .max_z = self.max_z + margin,
        };
    }

    /// Identity element for merge-grow patterns: an inverted AABB where min > max.
    ///
    /// Merging any valid AABB with `empty` produces the valid AABB unchanged.
    /// Uses `floatMax` rather than infinity to avoid IEEE edge cases in
    /// arithmetic (e.g. `inf - inf = NaN`).
    pub const empty: AABB3 = .{
        .min_x = std.math.floatMax(f32),
        .min_y = std.math.floatMax(f32),
        .min_z = std.math.floatMax(f32),
        .max_x = -std.math.floatMax(f32),
        .max_y = -std.math.floatMax(f32),
        .max_z = -std.math.floatMax(f32),
    };
};

// ---------------------------------------------------------------------------
// Sphere
// ---------------------------------------------------------------------------

pub const Sphere = extern struct {
    center_x: f32,
    center_y: f32,
    center_z: f32,
    radius: f32,

    pub inline fn init(cx: f32, cy: f32, cz: f32, r: f32) Sphere {
        std.debug.assert(r >= 0.0);
        return .{ .center_x = cx, .center_y = cy, .center_z = cz, .radius = r };
    }

    /// Non-asserting constructor for boundary-facing code.
    pub inline fn tryInit(cx: f32, cy: f32, cz: f32, r: f32) ?Sphere {
        // Negated >= rejects NaN.
        if (!(r >= 0.0)) return null;
        return .{ .center_x = cx, .center_y = cy, .center_z = cz, .radius = r };
    }

    pub inline fn contains(self: Sphere, x: f32, y: f32, z: f32) bool {
        const dx = x - self.center_x;
        const dy = y - self.center_y;
        const dz = z - self.center_z;
        return (dx * dx + dy * dy + dz * dz) <= (self.radius * self.radius);
    }

    pub inline fn intersects(self: Sphere, other: Sphere) bool {
        const dx = other.center_x - self.center_x;
        const dy = other.center_y - self.center_y;
        const dz = other.center_z - self.center_z;
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const r_sum = self.radius + other.radius;
        return dist_sq <= (r_sum * r_sum);
    }

    pub inline fn intersectsAABB(self: Sphere, aabb: AABB3) bool {
        const cp = aabb.closestPoint(self.center_x, self.center_y, self.center_z);
        const dx = cp.x - self.center_x;
        const dy = cp.y - self.center_y;
        const dz = cp.z - self.center_z;
        return (dx * dx + dy * dy + dz * dz) <= (self.radius * self.radius);
    }

    pub inline fn toAABB3(self: Sphere) AABB3 {
        return .{
            .min_x = self.center_x - self.radius,
            .min_y = self.center_y - self.radius,
            .min_z = self.center_z - self.radius,
            .max_x = self.center_x + self.radius,
            .max_y = self.center_y + self.radius,
            .max_z = self.center_z + self.radius,
        };
    }
};

// ---------------------------------------------------------------------------
// Ray3
// ---------------------------------------------------------------------------

pub const Ray3 = extern struct {
    origin_x: f32,
    origin_y: f32,
    origin_z: f32,
    dir_x: f32,
    dir_y: f32,
    dir_z: f32,

    pub inline fn init(
        ox: f32,
        oy: f32,
        oz: f32,
        dx: f32,
        dy: f32,
        dz: f32,
    ) Ray3 {
        const len_sq = dx * dx + dy * dy + dz * dz;
        std.debug.assert(@abs(len_sq - 1.0) < 1.0e-3);
        return .{
            .origin_x = ox, .origin_y = oy, .origin_z = oz,
            .dir_x = dx, .dir_y = dy, .dir_z = dz,
        };
    }

    /// Non-asserting constructor for boundary-facing code. Returns `null`
    /// if the direction is not approximately unit-length.
    pub inline fn tryInit(
        ox: f32,
        oy: f32,
        oz: f32,
        dx: f32,
        dy: f32,
        dz: f32,
    ) ?Ray3 {
        const len_sq = dx * dx + dy * dy + dz * dz;
        // Negated < rejects NaN.
        if (!(@abs(len_sq - 1.0) < 1.0e-3)) return null;
        return .{
            .origin_x = ox, .origin_y = oy, .origin_z = oz,
            .dir_x = dx, .dir_y = dy, .dir_z = dz,
        };
    }

    /// Construct from 3-element arrays (Vec3 convenience).
    /// Direction must be normalized (asserted in debug).
    pub inline fn fromVecs(origin: [3]f32, dir: [3]f32) Ray3 {
        return init(origin[0], origin[1], origin[2], dir[0], dir[1], dir[2]);
    }

    pub inline fn pointAt(self: Ray3, t: f32) struct { x: f32, y: f32, z: f32 } {
        return .{
            .x = self.origin_x + self.dir_x * t,
            .y = self.origin_y + self.dir_y * t,
            .z = self.origin_z + self.dir_z * t,
        };
    }

    pub inline fn intersectsAABB(
        self: Ray3,
        aabb: AABB3,
    ) ?struct { t_min: f32, t_max: f32 } {
        const inv_x: f32 = 1.0 / self.dir_x;
        const inv_y: f32 = 1.0 / self.dir_y;
        const inv_z: f32 = 1.0 / self.dir_z;

        const tx1 = (aabb.min_x - self.origin_x) * inv_x;
        const tx2 = (aabb.max_x - self.origin_x) * inv_x;
        var t_min = @min(tx1, tx2);
        var t_max = @max(tx1, tx2);

        const ty1 = (aabb.min_y - self.origin_y) * inv_y;
        const ty2 = (aabb.max_y - self.origin_y) * inv_y;
        t_min = @max(t_min, @min(ty1, ty2));
        t_max = @min(t_max, @max(ty1, ty2));

        const tz1 = (aabb.min_z - self.origin_z) * inv_z;
        const tz2 = (aabb.max_z - self.origin_z) * inv_z;
        t_min = @max(t_min, @min(tz1, tz2));
        t_max = @min(t_max, @max(tz1, tz2));

        if (t_max >= @max(t_min, @as(f32, 0.0))) {
            return .{ .t_min = t_min, .t_max = t_max };
        }
        return null;
    }

    pub inline fn intersectsSphere(
        self: Ray3,
        sphere: Sphere,
    ) ?struct { t_min: f32, t_max: f32 } {
        const oc_x = self.origin_x - sphere.center_x;
        const oc_y = self.origin_y - sphere.center_y;
        const oc_z = self.origin_z - sphere.center_z;

        // a = dot(dir, dir) which is 1.0 for normalized rays, but compute for safety.
        const a = self.dir_x * self.dir_x + self.dir_y * self.dir_y +
            self.dir_z * self.dir_z;
        const b = 2.0 * (oc_x * self.dir_x + oc_y * self.dir_y + oc_z * self.dir_z);
        const c = (oc_x * oc_x + oc_y * oc_y + oc_z * oc_z) -
            sphere.radius * sphere.radius;

        const discriminant = b * b - 4.0 * a * c;
        if (discriminant < 0.0) return null;

        const sqrt_disc = @sqrt(discriminant);
        const inv_2a = 1.0 / (2.0 * a);
        const t0 = (-b - sqrt_disc) * inv_2a;
        const t1 = (-b + sqrt_disc) * inv_2a;

        if (t1 < 0.0) return null;

        return .{ .t_min = t0, .t_max = t1 };
    }
};

// ---------------------------------------------------------------------------
// Ray3Precomputed
// ---------------------------------------------------------------------------

pub const Ray3Precomputed = extern struct {
    origin_x: f32,
    origin_y: f32,
    origin_z: f32,
    inv_dir_x: f32,
    inv_dir_y: f32,
    inv_dir_z: f32,
    sign_x: u32,
    sign_y: u32,
    sign_z: u32,

    pub inline fn fromRay(ray: Ray3) Ray3Precomputed {
        const inv_x: f32 = 1.0 / ray.dir_x;
        const inv_y: f32 = 1.0 / ray.dir_y;
        const inv_z: f32 = 1.0 / ray.dir_z;
        return .{
            .origin_x = ray.origin_x,
            .origin_y = ray.origin_y,
            .origin_z = ray.origin_z,
            .inv_dir_x = inv_x,
            .inv_dir_y = inv_y,
            .inv_dir_z = inv_z,
            .sign_x = if (inv_x < 0.0) @as(u32, 1) else @as(u32, 0),
            .sign_y = if (inv_y < 0.0) @as(u32, 1) else @as(u32, 0),
            .sign_z = if (inv_z < 0.0) @as(u32, 1) else @as(u32, 0),
        };
    }

    pub inline fn intersectsAABB(
        self: Ray3Precomputed,
        aabb: AABB3,
    ) ?struct { t_min: f32, t_max: f32 } {
        const bounds = [2][3]f32{
            .{ aabb.min_x, aabb.min_y, aabb.min_z },
            .{ aabb.max_x, aabb.max_y, aabb.max_z },
        };

        const tx_lo = (bounds[self.sign_x][0] - self.origin_x) * self.inv_dir_x;
        const tx_hi = (bounds[1 - self.sign_x][0] - self.origin_x) * self.inv_dir_x;
        const ty_lo = (bounds[self.sign_y][1] - self.origin_y) * self.inv_dir_y;
        const ty_hi = (bounds[1 - self.sign_y][1] - self.origin_y) * self.inv_dir_y;

        var t_min = tx_lo;
        var t_max = tx_hi;

        if (t_min > ty_hi or ty_lo > t_max) return null;
        t_min = @max(t_min, ty_lo);
        t_max = @min(t_max, ty_hi);

        const tz_lo = (bounds[self.sign_z][2] - self.origin_z) * self.inv_dir_z;
        const tz_hi = (bounds[1 - self.sign_z][2] - self.origin_z) * self.inv_dir_z;

        if (t_min > tz_hi or tz_lo > t_max) return null;
        t_min = @max(t_min, tz_lo);
        t_max = @min(t_max, tz_hi);

        if (t_max >= @max(t_min, @as(f32, 0.0))) {
            return .{ .t_min = t_min, .t_max = t_max };
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Plane
// ---------------------------------------------------------------------------

pub const Plane = extern struct {
    normal_x: f32,
    normal_y: f32,
    normal_z: f32,
    d: f32,

    pub inline fn fromPointNormal(
        px: f32,
        py: f32,
        pz: f32,
        nx: f32,
        ny: f32,
        nz: f32,
    ) Plane {
        const len_sq = nx * nx + ny * ny + nz * nz;
        std.debug.assert(@abs(len_sq - 1.0) < 1.0e-3);
        return .{
            .normal_x = nx,
            .normal_y = ny,
            .normal_z = nz,
            .d = -(nx * px + ny * py + nz * pz),
        };
    }

    /// Construct from three non-collinear points (CCW winding determines
    /// normal direction). Precondition: triangle is non-degenerate.
    pub inline fn fromPoints(
        p0x: f32,
        p0y: f32,
        p0z: f32,
        p1x: f32,
        p1y: f32,
        p1z: f32,
        p2x: f32,
        p2y: f32,
        p2z: f32,
    ) Plane {
        // edge vectors
        const e1x = p1x - p0x;
        const e1y = p1y - p0y;
        const e1z = p1z - p0z;
        const e2x = p2x - p0x;
        const e2y = p2y - p0y;
        const e2z = p2z - p0z;
        // cross product
        const nx = e1y * e2z - e1z * e2y;
        const ny = e1z * e2x - e1x * e2z;
        const nz = e1x * e2y - e1y * e2x;
        const len = @sqrt(nx * nx + ny * ny + nz * nz);
        std.debug.assert(len > epsilon);
        const inv = 1.0 / len;
        const nnx = nx * inv;
        const nny = ny * inv;
        const nnz = nz * inv;
        const result = Plane{
            .normal_x = nnx,
            .normal_y = nny,
            .normal_z = nnz,
            .d = -(nnx * p0x + nny * p0y + nnz * p0z),
        };
        const n_len = nnx * nnx + nny * nny + nnz * nnz;
        std.debug.assert(@abs(n_len - 1.0) < 1.0e-3);
        return result;
    }

    pub inline fn signedDistance(self: Plane, x: f32, y: f32, z: f32) f32 {
        return self.normal_x * x + self.normal_y * y + self.normal_z * z + self.d;
    }

    pub inline fn project(
        self: Plane,
        x: f32,
        y: f32,
        z: f32,
    ) struct { x: f32, y: f32, z: f32 } {
        const dist = self.signedDistance(x, y, z);
        return .{
            .x = x - dist * self.normal_x,
            .y = y - dist * self.normal_y,
            .z = z - dist * self.normal_z,
        };
    }

    pub const PointClassification = enum { front, back, on_plane };

    pub inline fn classifyPoint(self: Plane, x: f32, y: f32, z: f32) PointClassification {
        const dist = self.signedDistance(x, y, z);
        if (dist > epsilon) return .front;
        if (dist < -epsilon) return .back;
        return .on_plane;
    }

    pub inline fn intersectsAABB(self: Plane, aabb: AABB3) bool {
        // Compute the projection interval radius of the AABB onto the plane normal.
        const cx = (aabb.min_x + aabb.max_x) * 0.5;
        const cy = (aabb.min_y + aabb.max_y) * 0.5;
        const cz = (aabb.min_z + aabb.max_z) * 0.5;
        const ex = (aabb.max_x - aabb.min_x) * 0.5;
        const ey = (aabb.max_y - aabb.min_y) * 0.5;
        const ez = (aabb.max_z - aabb.min_z) * 0.5;

        const r = ex * @abs(self.normal_x) + ey * @abs(self.normal_y) +
            ez * @abs(self.normal_z);
        const dist = self.signedDistance(cx, cy, cz);
        return @abs(dist) <= r;
    }

    pub inline fn intersectsSphere(self: Plane, sphere: Sphere) bool {
        const dist = self.signedDistance(sphere.center_x, sphere.center_y, sphere.center_z);
        return @abs(dist) <= sphere.radius;
    }
};

// ---------------------------------------------------------------------------
// Frustum
// ---------------------------------------------------------------------------

/// Frustum defined by six planes (left, right, bottom, top, near, far).
///
/// §0 deviation: not `extern struct`. Zig does not guarantee `extern`
/// layout for structs containing arrays of other structs (`[6]Plane`).
/// Using plain `struct` avoids undefined layout behavior. Callers needing
/// FFI compatibility should pass the six planes individually or use a
/// flat `[6 * 4]f32` representation at the boundary.
pub const Frustum = struct {
    planes: [6]Plane,

    pub const Classification = enum { outside, inside, intersecting };

    /// Extract frustum planes from a row-major 4x4 view-projection matrix
    /// using the Gribb-Hartmann method.
    pub inline fn fromViewProjection(mat: [4][4]f32) Frustum {
        var planes: [6]Plane = undefined;

        // left = row3 + row0
        planes[0] = normalizePlane(.{
            .normal_x = mat[3][0] + mat[0][0],
            .normal_y = mat[3][1] + mat[0][1],
            .normal_z = mat[3][2] + mat[0][2],
            .d = mat[3][3] + mat[0][3],
        });
        // right = row3 - row0
        planes[1] = normalizePlane(.{
            .normal_x = mat[3][0] - mat[0][0],
            .normal_y = mat[3][1] - mat[0][1],
            .normal_z = mat[3][2] - mat[0][2],
            .d = mat[3][3] - mat[0][3],
        });
        // bottom = row3 + row1
        planes[2] = normalizePlane(.{
            .normal_x = mat[3][0] + mat[1][0],
            .normal_y = mat[3][1] + mat[1][1],
            .normal_z = mat[3][2] + mat[1][2],
            .d = mat[3][3] + mat[1][3],
        });
        // top = row3 - row1
        planes[3] = normalizePlane(.{
            .normal_x = mat[3][0] - mat[1][0],
            .normal_y = mat[3][1] - mat[1][1],
            .normal_z = mat[3][2] - mat[1][2],
            .d = mat[3][3] - mat[1][3],
        });
        // near = row2
        planes[4] = normalizePlane(.{
            .normal_x = mat[2][0],
            .normal_y = mat[2][1],
            .normal_z = mat[2][2],
            .d = mat[2][3],
        });
        // far = row3 - row2
        planes[5] = normalizePlane(.{
            .normal_x = mat[3][0] - mat[2][0],
            .normal_y = mat[3][1] - mat[2][1],
            .normal_z = mat[3][2] - mat[2][2],
            .d = mat[3][3] - mat[2][3],
        });

        return .{ .planes = planes };
    }

    fn normalizePlane(p: Plane) Plane {
        const len = @sqrt(p.normal_x * p.normal_x + p.normal_y * p.normal_y +
            p.normal_z * p.normal_z);
        std.debug.assert(len > epsilon);
        const inv = 1.0 / len;
        return .{
            .normal_x = p.normal_x * inv,
            .normal_y = p.normal_y * inv,
            .normal_z = p.normal_z * inv,
            .d = p.d * inv,
        };
    }

    pub inline fn containsPoint(self: Frustum, x: f32, y: f32, z: f32) bool {
        for (self.planes) |plane| {
            if (plane.signedDistance(x, y, z) < -epsilon) return false;
        }
        return true;
    }

    pub inline fn containsAABB(self: Frustum, aabb: AABB3) bool {
        // Returns true if the AABB is not fully outside (conservative).
        for (self.planes) |plane| {
            // Find the p-vertex (vertex most aligned with normal).
            const px = if (plane.normal_x >= 0.0) aabb.max_x else aabb.min_x;
            const py = if (plane.normal_y >= 0.0) aabb.max_y else aabb.min_y;
            const pz = if (plane.normal_z >= 0.0) aabb.max_z else aabb.min_z;
            if (plane.signedDistance(px, py, pz) < -epsilon) return false;
        }
        return true;
    }

    pub inline fn intersectsAABB(self: Frustum, aabb: AABB3) Classification {
        var all_inside = true;
        for (self.planes) |plane| {
            // p-vertex: most in direction of normal
            const px = if (plane.normal_x >= 0.0) aabb.max_x else aabb.min_x;
            const py = if (plane.normal_y >= 0.0) aabb.max_y else aabb.min_y;
            const pz = if (plane.normal_z >= 0.0) aabb.max_z else aabb.min_z;

            if (plane.signedDistance(px, py, pz) < -epsilon) return .outside;

            // n-vertex: least in direction of normal
            const nx = if (plane.normal_x >= 0.0) aabb.min_x else aabb.max_x;
            const ny = if (plane.normal_y >= 0.0) aabb.min_y else aabb.max_y;
            const nz = if (plane.normal_z >= 0.0) aabb.min_z else aabb.max_z;

            if (plane.signedDistance(nx, ny, nz) < -epsilon) all_inside = false;
        }
        return if (all_inside) .inside else .intersecting;
    }

    pub inline fn intersectsSphere(self: Frustum, sphere: Sphere) Classification {
        var all_inside = true;
        for (self.planes) |plane| {
            const dist = plane.signedDistance(
                sphere.center_x,
                sphere.center_y,
                sphere.center_z,
            );
            if (dist < -sphere.radius) return .outside;
            if (dist < sphere.radius) all_inside = false;
        }
        return if (all_inside) .inside else .intersecting;
    }
};

// ---------------------------------------------------------------------------
// GridConfig
// ---------------------------------------------------------------------------

pub const GridConfig = extern struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    cells_x: u32,
    cells_y: u32,

    pub inline fn cellWidth(self: GridConfig) f32 {
        return (self.max_x - self.min_x) / @as(f32, @floatFromInt(self.cells_x));
    }

    pub inline fn cellHeight(self: GridConfig) f32 {
        return (self.max_y - self.min_y) / @as(f32, @floatFromInt(self.cells_y));
    }

    pub inline fn totalCells(self: GridConfig) u32 {
        return self.cells_x * self.cells_y;
    }

    pub inline fn cellIndex(
        self: GridConfig,
        x: f32,
        y: f32,
    ) ?struct { cx: u32, cy: u32 } {
        if (x < self.min_x or x > self.max_x or y < self.min_y or y > self.max_y)
            return null;

        const fx = @as(f32, @floatFromInt(self.cells_x));
        const fy = @as(f32, @floatFromInt(self.cells_y));
        const nx = (x - self.min_x) / (self.max_x - self.min_x) * fx;
        const ny = (y - self.min_y) / (self.max_y - self.min_y) * fy;

        var cx: u32 = @intFromFloat(@floor(nx));
        var cy: u32 = @intFromFloat(@floor(ny));

        // Clamp edge cases where point is exactly on max boundary.
        if (cx >= self.cells_x) cx = self.cells_x - 1;
        if (cy >= self.cells_y) cy = self.cells_y - 1;

        return .{ .cx = cx, .cy = cy };
    }

    pub inline fn linearIndex(self: GridConfig, cx: u32, cy: u32) u32 {
        std.debug.assert(cx < self.cells_x);
        std.debug.assert(cy < self.cells_y);
        return cy * self.cells_x + cx;
    }
};

// ---------------------------------------------------------------------------
// GridConfig3D
// ---------------------------------------------------------------------------

pub const GridConfig3D = extern struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,
    cells_x: u32,
    cells_y: u32,
    cells_z: u32,

    pub inline fn cellWidth(self: GridConfig3D) f32 {
        return (self.max_x - self.min_x) / @as(f32, @floatFromInt(self.cells_x));
    }

    pub inline fn cellHeight(self: GridConfig3D) f32 {
        return (self.max_y - self.min_y) / @as(f32, @floatFromInt(self.cells_y));
    }

    pub inline fn cellDepth(self: GridConfig3D) f32 {
        return (self.max_z - self.min_z) / @as(f32, @floatFromInt(self.cells_z));
    }

    pub inline fn totalCells(self: GridConfig3D) u32 {
        return self.cells_x * self.cells_y * self.cells_z;
    }

    pub inline fn cellIndex(
        self: GridConfig3D,
        x: f32,
        y: f32,
        z: f32,
    ) ?struct { cx: u32, cy: u32, cz: u32 } {
        if (x < self.min_x or x > self.max_x or
            y < self.min_y or y > self.max_y or
            z < self.min_z or z > self.max_z)
            return null;

        const fx = @as(f32, @floatFromInt(self.cells_x));
        const fy = @as(f32, @floatFromInt(self.cells_y));
        const fz = @as(f32, @floatFromInt(self.cells_z));
        const nx = (x - self.min_x) / (self.max_x - self.min_x) * fx;
        const ny = (y - self.min_y) / (self.max_y - self.min_y) * fy;
        const nz = (z - self.min_z) / (self.max_z - self.min_z) * fz;

        var cx: u32 = @intFromFloat(@floor(nx));
        var cy: u32 = @intFromFloat(@floor(ny));
        var cz: u32 = @intFromFloat(@floor(nz));

        if (cx >= self.cells_x) cx = self.cells_x - 1;
        if (cy >= self.cells_y) cy = self.cells_y - 1;
        if (cz >= self.cells_z) cz = self.cells_z - 1;

        return .{ .cx = cx, .cy = cy, .cz = cz };
    }

    pub inline fn linearIndex(self: GridConfig3D, cx: u32, cy: u32, cz: u32) u32 {
        std.debug.assert(cx < self.cells_x);
        std.debug.assert(cy < self.cells_y);
        std.debug.assert(cz < self.cells_z);
        return (cz * self.cells_y + cy) * self.cells_x + cx;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const expectApprox = std.math.approxEqAbs;

fn approxEq(a: f32, b: f32) bool {
    return expectApprox(f32, a, b, 1.0e-5);
}

test "AABB2 construction and metrics" {
    const box = AABB2.init(-1.0, -2.0, 3.0, 4.0);
    try testing.expectEqual(@as(f32, 4.0), box.width());
    try testing.expectEqual(@as(f32, 6.0), box.height());
    try testing.expectEqual(@as(f32, 24.0), box.area());

    const c = box.center();
    try testing.expect(approxEq(c.x, 1.0));
    try testing.expect(approxEq(c.y, 1.0));

    const e = box.extents();
    try testing.expect(approxEq(e.half_w, 2.0));
    try testing.expect(approxEq(e.half_h, 3.0));

    const box2 = AABB2.fromCenterExtent(1.0, 1.0, 2.0, 3.0);
    try testing.expect(approxEq(box2.min_x, -1.0));
    try testing.expect(approxEq(box2.max_y, 4.0));
}

test "AABB2 contains and intersects" {
    const a = AABB2.init(0.0, 0.0, 10.0, 10.0);
    try testing.expect(a.contains(5.0, 5.0));
    try testing.expect(a.contains(0.0, 0.0));
    try testing.expect(!a.contains(-1.0, 5.0));

    const b = AABB2.init(5.0, 5.0, 15.0, 15.0);
    try testing.expect(a.intersects(b));
    try testing.expect(!a.containsAABB(b));

    const c = AABB2.init(1.0, 1.0, 9.0, 9.0);
    try testing.expect(a.containsAABB(c));

    const d = AABB2.init(20.0, 20.0, 30.0, 30.0);
    try testing.expect(!a.intersects(d));
}

test "AABB2 merge and expand" {
    const a = AABB2.init(0.0, 0.0, 5.0, 5.0);
    const b = AABB2.init(3.0, 3.0, 10.0, 10.0);
    const m = AABB2.merge(a, b);
    try testing.expect(approxEq(m.min_x, 0.0));
    try testing.expect(approxEq(m.max_x, 10.0));
    try testing.expect(approxEq(m.max_y, 10.0));

    const e = a.expand(-2.0, 7.0);
    try testing.expect(approxEq(e.min_x, -2.0));
    try testing.expect(approxEq(e.max_y, 7.0));

    const p = a.pad(1.0);
    try testing.expect(approxEq(p.min_x, -1.0));
    try testing.expect(approxEq(p.max_x, 6.0));
}

test "AABB3 construction and metrics" {
    const box = AABB3.init(-1.0, -2.0, -3.0, 1.0, 2.0, 3.0);
    try testing.expect(approxEq(box.width(), 2.0));
    try testing.expect(approxEq(box.height(), 4.0));
    try testing.expect(approxEq(box.depth(), 6.0));
    try testing.expect(approxEq(box.volume(), 48.0));
    // Surface area: 2*(2*4 + 2*6 + 4*6) = 2*(8+12+24) = 88
    try testing.expect(approxEq(box.surfaceArea(), 88.0));

    const c = box.center();
    try testing.expect(approxEq(c.x, 0.0));
    try testing.expect(approxEq(c.y, 0.0));
    try testing.expect(approxEq(c.z, 0.0));

    const e = box.extents();
    try testing.expect(approxEq(e.hx, 1.0));
    try testing.expect(approxEq(e.hy, 2.0));
    try testing.expect(approxEq(e.hz, 3.0));

    const box2 = AABB3.fromCenterExtent(0.0, 0.0, 0.0, 1.0, 2.0, 3.0);
    try testing.expect(approxEq(box2.min_x, -1.0));
    try testing.expect(approxEq(box2.max_z, 3.0));
}

test "AABB3 contains and intersects" {
    const a = AABB3.init(0.0, 0.0, 0.0, 10.0, 10.0, 10.0);
    try testing.expect(a.contains(5.0, 5.0, 5.0));
    try testing.expect(!a.contains(-1.0, 5.0, 5.0));

    const b = AABB3.init(5.0, 5.0, 5.0, 15.0, 15.0, 15.0);
    try testing.expect(a.intersects(b));
    try testing.expect(!a.containsAABB(b));

    const c = AABB3.init(1.0, 1.0, 1.0, 9.0, 9.0, 9.0);
    try testing.expect(a.containsAABB(c));

    const d = AABB3.init(20.0, 20.0, 20.0, 30.0, 30.0, 30.0);
    try testing.expect(!a.intersects(d));
}

test "AABB3 closestPoint" {
    const box = AABB3.init(0.0, 0.0, 0.0, 10.0, 10.0, 10.0);

    // Point inside returns itself.
    const p1 = box.closestPoint(5.0, 5.0, 5.0);
    try testing.expect(approxEq(p1.x, 5.0));
    try testing.expect(approxEq(p1.y, 5.0));
    try testing.expect(approxEq(p1.z, 5.0));

    // Point outside is clamped.
    const p2 = box.closestPoint(-5.0, 15.0, 5.0);
    try testing.expect(approxEq(p2.x, 0.0));
    try testing.expect(approxEq(p2.y, 10.0));
    try testing.expect(approxEq(p2.z, 5.0));
}

test "AABB3 pad" {
    const box = AABB3.init(0.0, 0.0, 0.0, 10.0, 10.0, 10.0);
    const padded = box.pad(2.0);
    try testing.expect(approxEq(padded.min_x, -2.0));
    try testing.expect(approxEq(padded.min_y, -2.0));
    try testing.expect(approxEq(padded.min_z, -2.0));
    try testing.expect(approxEq(padded.max_x, 12.0));
    try testing.expect(approxEq(padded.max_y, 12.0));
    try testing.expect(approxEq(padded.max_z, 12.0));
}

test "Sphere init and contains" {
    const s = Sphere.init(0.0, 0.0, 0.0, 5.0);
    try testing.expect(s.contains(0.0, 0.0, 0.0));
    try testing.expect(s.contains(3.0, 4.0, 0.0)); // distance = 5
    try testing.expect(!s.contains(3.0, 4.0, 1.0)); // distance > 5
}

test "Sphere intersects sphere and AABB" {
    const a = Sphere.init(0.0, 0.0, 0.0, 5.0);
    const b = Sphere.init(8.0, 0.0, 0.0, 5.0);
    try testing.expect(a.intersects(b)); // distance 8, sum radii 10

    const c = Sphere.init(20.0, 0.0, 0.0, 2.0);
    try testing.expect(!a.intersects(c));

    const box = AABB3.init(3.0, 3.0, 3.0, 10.0, 10.0, 10.0);
    // Closest point on box to origin is (3,3,3), distance = sqrt(27) ~ 5.196 > 5
    try testing.expect(!a.intersectsAABB(box));

    const box2 = AABB3.init(2.0, 2.0, 0.0, 10.0, 10.0, 10.0);
    // Closest point to origin is (2,2,0), distance = sqrt(8) ~ 2.83 < 5
    try testing.expect(a.intersectsAABB(box2));
}

test "Sphere toAABB3" {
    const s = Sphere.init(1.0, 2.0, 3.0, 4.0);
    const box = s.toAABB3();
    try testing.expect(approxEq(box.min_x, -3.0));
    try testing.expect(approxEq(box.min_y, -2.0));
    try testing.expect(approxEq(box.min_z, -1.0));
    try testing.expect(approxEq(box.max_x, 5.0));
    try testing.expect(approxEq(box.max_y, 6.0));
    try testing.expect(approxEq(box.max_z, 7.0));
}

test "Ray3 pointAt and intersectsAABB" {
    const ray = Ray3.init(0.0, 0.0, -10.0, 0.0, 0.0, 1.0);
    const pt = ray.pointAt(5.0);
    try testing.expect(approxEq(pt.x, 0.0));
    try testing.expect(approxEq(pt.y, 0.0));
    try testing.expect(approxEq(pt.z, -5.0));

    const box = AABB3.init(-1.0, -1.0, -1.0, 1.0, 1.0, 1.0);
    const hit = ray.intersectsAABB(box);
    try testing.expect(hit != null);
    const h = hit.?;
    try testing.expect(approxEq(h.t_min, 9.0)); // z goes from -10 to -1
    try testing.expect(approxEq(h.t_max, 11.0)); // z goes from -10 to 1

    // Miss case: ray pointing away.
    const ray2 = Ray3.init(0.0, 0.0, -10.0, 0.0, 0.0, -1.0);
    try testing.expect(ray2.intersectsAABB(box) == null);
}

test "Ray3 intersectsSphere" {
    const ray = Ray3.init(0.0, 0.0, -10.0, 0.0, 0.0, 1.0);
    const sphere = Sphere.init(0.0, 0.0, 0.0, 2.0);
    const hit = ray.intersectsSphere(sphere);
    try testing.expect(hit != null);
    const h = hit.?;
    try testing.expect(approxEq(h.t_min, 8.0));
    try testing.expect(approxEq(h.t_max, 12.0));

    // Miss case.
    const ray2 = Ray3.init(0.0, 10.0, -10.0, 0.0, 0.0, 1.0);
    try testing.expect(ray2.intersectsSphere(sphere) == null);
}

test "Ray3Precomputed matches Ray3" {
    const ray = Ray3.init(0.0, 0.0, -10.0, 0.0, 0.0, 1.0);
    const pre = Ray3Precomputed.fromRay(ray);
    const box = AABB3.init(-1.0, -1.0, -1.0, 1.0, 1.0, 1.0);

    const hit_ray = ray.intersectsAABB(box);
    const hit_pre = pre.intersectsAABB(box);
    try testing.expect(hit_ray != null);
    try testing.expect(hit_pre != null);

    const hr = hit_ray.?;
    const hp = hit_pre.?;
    try testing.expect(approxEq(hr.t_min, hp.t_min));
    try testing.expect(approxEq(hr.t_max, hp.t_max));

    // Also test miss.
    const ray2 = Ray3.init(0.0, 0.0, -10.0, 0.0, 0.0, -1.0);
    const pre2 = Ray3Precomputed.fromRay(ray2);
    try testing.expect(ray2.intersectsAABB(box) == null);
    try testing.expect(pre2.intersectsAABB(box) == null);
}

test "Plane signedDistance and classify" {
    // XY plane with normal pointing +Z, passing through origin.
    const plane = Plane.fromPointNormal(0.0, 0.0, 0.0, 0.0, 0.0, 1.0);
    try testing.expect(approxEq(plane.d, 0.0));

    try testing.expect(approxEq(plane.signedDistance(0.0, 0.0, 5.0), 5.0));
    try testing.expect(approxEq(plane.signedDistance(0.0, 0.0, -3.0), -3.0));

    try testing.expect(plane.classifyPoint(0.0, 0.0, 1.0) == .front);
    try testing.expect(plane.classifyPoint(0.0, 0.0, -1.0) == .back);
    try testing.expect(plane.classifyPoint(5.0, 5.0, 0.0) == .on_plane);
}

test "Plane project" {
    const plane = Plane.fromPointNormal(0.0, 0.0, 0.0, 0.0, 0.0, 1.0);
    const proj = plane.project(3.0, 4.0, 7.0);
    try testing.expect(approxEq(proj.x, 3.0));
    try testing.expect(approxEq(proj.y, 4.0));
    try testing.expect(approxEq(proj.z, 0.0));
}

test "Plane intersectsAABB and intersectsSphere" {
    const plane = Plane.fromPointNormal(0.0, 0.0, 0.0, 0.0, 0.0, 1.0);

    // AABB straddling the plane.
    const box1 = AABB3.init(-1.0, -1.0, -1.0, 1.0, 1.0, 1.0);
    try testing.expect(plane.intersectsAABB(box1));

    // AABB entirely above the plane.
    const box2 = AABB3.init(-1.0, -1.0, 2.0, 1.0, 1.0, 4.0);
    try testing.expect(!plane.intersectsAABB(box2));

    // Sphere touching the plane.
    const s1 = Sphere.init(0.0, 0.0, 2.0, 3.0);
    try testing.expect(plane.intersectsSphere(s1));

    // Sphere not touching.
    const s2 = Sphere.init(0.0, 0.0, 10.0, 1.0);
    try testing.expect(!plane.intersectsSphere(s2));
}

test "AABB2 tryInit rejects invalid bounds" {
    try testing.expect(AABB2.tryInit(5.0, 0.0, 3.0, 10.0) == null); // min_x > max_x
    try testing.expect(AABB2.tryInit(0.0, 5.0, 10.0, 3.0) == null); // min_y > max_y
    const valid = AABB2.tryInit(0.0, 0.0, 10.0, 10.0);
    try testing.expect(valid != null);
    try testing.expect(approxEq(valid.?.width(), 10.0));
}

test "AABB2 tryFromCenterExtent rejects negative extents" {
    try testing.expect(AABB2.tryFromCenterExtent(0.0, 0.0, -1.0, 1.0) == null);
    try testing.expect(AABB2.tryFromCenterExtent(0.0, 0.0, 1.0, -1.0) == null);
    try testing.expect(AABB2.tryFromCenterExtent(0.0, 0.0, 1.0, 1.0) != null);
}

test "AABB3 tryInit rejects invalid bounds" {
    try testing.expect(AABB3.tryInit(5.0, 0.0, 0.0, 3.0, 10.0, 10.0) == null);
    try testing.expect(AABB3.tryInit(0.0, 5.0, 0.0, 10.0, 3.0, 10.0) == null);
    try testing.expect(AABB3.tryInit(0.0, 0.0, 5.0, 10.0, 10.0, 3.0) == null);
    const valid = AABB3.tryInit(0.0, 0.0, 0.0, 10.0, 10.0, 10.0);
    try testing.expect(valid != null);
    try testing.expect(approxEq(valid.?.volume(), 1000.0));
}

test "AABB3 tryFromCenterExtent rejects negative extents" {
    try testing.expect(AABB3.tryFromCenterExtent(0.0, 0.0, 0.0, -1.0, 1.0, 1.0) == null);
    try testing.expect(AABB3.tryFromCenterExtent(0.0, 0.0, 0.0, 1.0, -1.0, 1.0) == null);
    try testing.expect(AABB3.tryFromCenterExtent(0.0, 0.0, 0.0, 1.0, 1.0, -1.0) == null);
    try testing.expect(AABB3.tryFromCenterExtent(0.0, 0.0, 0.0, 1.0, 2.0, 3.0) != null);
}

test "Sphere tryInit rejects negative radius" {
    try testing.expect(Sphere.tryInit(0.0, 0.0, 0.0, -1.0) == null);
    const valid = Sphere.tryInit(1.0, 2.0, 3.0, 4.0);
    try testing.expect(valid != null);
    try testing.expect(approxEq(valid.?.radius, 4.0));
}

test "Ray3 tryInit rejects non-unit direction" {
    // Non-normalized direction.
    try testing.expect(Ray3.tryInit(0.0, 0.0, 0.0, 1.0, 1.0, 0.0) == null);
    // Zero direction.
    try testing.expect(Ray3.tryInit(0.0, 0.0, 0.0, 0.0, 0.0, 0.0) == null);
    // Valid unit direction.
    const valid = Ray3.tryInit(0.0, 0.0, 0.0, 0.0, 0.0, 1.0);
    try testing.expect(valid != null);
    try testing.expect(approxEq(valid.?.dir_z, 1.0));
}

test "tryInit rejects NaN" {
    const nan = std.math.nan(f32);
    try testing.expect(AABB2.tryInit(nan, 0.0, 1.0, 1.0) == null);
    try testing.expect(AABB2.tryInit(0.0, 0.0, nan, 1.0) == null);
    try testing.expect(AABB2.tryFromCenterExtent(0.0, 0.0, nan, 1.0) == null);
    try testing.expect(AABB3.tryInit(nan, 0.0, 0.0, 1.0, 1.0, 1.0) == null);
    try testing.expect(AABB3.tryFromCenterExtent(0.0, 0.0, 0.0, nan, 1.0, 1.0) == null);
    try testing.expect(Sphere.tryInit(0.0, 0.0, 0.0, nan) == null);
    try testing.expect(Ray3.tryInit(0.0, 0.0, 0.0, nan, 0.0, 0.0) == null);
}

test "AABB2 fromPoints" {
    const points = [_]Point2{
        .{ .x = 3.0, .y = -1.0 },
        .{ .x = -2.0, .y = 5.0 },
        .{ .x = 1.0, .y = 2.0 },
    };
    const box = AABB2.fromPoints(&points);
    try testing.expect(approxEq(box.min_x, -2.0));
    try testing.expect(approxEq(box.min_y, -1.0));
    try testing.expect(approxEq(box.max_x, 3.0));
    try testing.expect(approxEq(box.max_y, 5.0));
}

test "AABB3 fromPoints" {
    const points = [_]Point3{
        .{ .x = 1.0, .y = -2.0, .z = 3.0 },
        .{ .x = -1.0, .y = 4.0, .z = 0.0 },
        .{ .x = 0.0, .y = 0.0, .z = 5.0 },
    };
    const box = AABB3.fromPoints(&points);
    try testing.expect(approxEq(box.min_x, -1.0));
    try testing.expect(approxEq(box.min_y, -2.0));
    try testing.expect(approxEq(box.min_z, 0.0));
    try testing.expect(approxEq(box.max_x, 1.0));
    try testing.expect(approxEq(box.max_y, 4.0));
    try testing.expect(approxEq(box.max_z, 5.0));
}

test "AABB3 fromSphere" {
    const s = Sphere.init(1.0, 2.0, 3.0, 4.0);
    const box = AABB3.fromSphere(s);
    try testing.expect(approxEq(box.min_x, -3.0));
    try testing.expect(approxEq(box.min_y, -2.0));
    try testing.expect(approxEq(box.min_z, -1.0));
    try testing.expect(approxEq(box.max_x, 5.0));
    try testing.expect(approxEq(box.max_y, 6.0));
    try testing.expect(approxEq(box.max_z, 7.0));
    // Should match Sphere.toAABB3.
    const box2 = s.toAABB3();
    try testing.expect(approxEq(box.min_x, box2.min_x));
    try testing.expect(approxEq(box.max_z, box2.max_z));
}

test "AABB3 fromMinMax" {
    const box = AABB3.fromMinMax(
        .{ -1.0, -2.0, -3.0 },
        .{ 1.0, 2.0, 3.0 },
    );
    try testing.expect(approxEq(box.width(), 2.0));
    try testing.expect(approxEq(box.height(), 4.0));
    try testing.expect(approxEq(box.depth(), 6.0));
}

test "AABB3 transform identity" {
    const box = AABB3.init(-1.0, -1.0, -1.0, 1.0, 1.0, 1.0);
    // Identity matrix (column-major).
    const identity = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    const result = box.transform(identity);
    try testing.expect(approxEq(result.min_x, -1.0));
    try testing.expect(approxEq(result.max_x, 1.0));
    try testing.expect(approxEq(result.min_y, -1.0));
    try testing.expect(approxEq(result.max_y, 1.0));
    try testing.expect(approxEq(result.min_z, -1.0));
    try testing.expect(approxEq(result.max_z, 1.0));
}

test "AABB3 transform translation" {
    const box = AABB3.init(0.0, 0.0, 0.0, 1.0, 1.0, 1.0);
    // Translation by (10, 20, 30) in column-major.
    const mat = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 10, 20, 30, 1 },
    };
    const result = box.transform(mat);
    try testing.expect(approxEq(result.min_x, 10.0));
    try testing.expect(approxEq(result.max_x, 11.0));
    try testing.expect(approxEq(result.min_y, 20.0));
    try testing.expect(approxEq(result.max_y, 21.0));
    try testing.expect(approxEq(result.min_z, 30.0));
    try testing.expect(approxEq(result.max_z, 31.0));
}

test "Ray3 fromVecs" {
    const ray = Ray3.fromVecs(.{ 1.0, 2.0, 3.0 }, .{ 0.0, 0.0, 1.0 });
    try testing.expect(approxEq(ray.origin_x, 1.0));
    try testing.expect(approxEq(ray.origin_y, 2.0));
    try testing.expect(approxEq(ray.origin_z, 3.0));
    try testing.expect(approxEq(ray.dir_z, 1.0));
}

test "Plane fromPoints" {
    // Triangle in the XY plane (z=0), CCW winding when viewed from +Z.
    const plane = Plane.fromPoints(
        0.0, 0.0, 0.0,
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
    );
    // Normal should point in +Z.
    try testing.expect(approxEq(plane.normal_z, 1.0));
    try testing.expect(approxEq(plane.normal_x, 0.0));
    try testing.expect(approxEq(plane.normal_y, 0.0));
    try testing.expect(approxEq(plane.d, 0.0));

    // Point above the plane should have positive signed distance.
    try testing.expect(plane.signedDistance(0.0, 0.0, 5.0) > 0.0);
}

test "AABB2 empty constant has min > max on all axes" {
    // Goal: verify the empty sentinel correctly represents an inverted AABB.
    // Method: assert all min components exceed their corresponding max components.
    try testing.expect(AABB2.empty.min_x > AABB2.empty.max_x);
    try testing.expect(AABB2.empty.min_y > AABB2.empty.max_y);
    // Pair assertion: merging empty with a real box produces the real box unchanged.
    const box = AABB2.init(1.0, 2.0, 3.0, 4.0);
    const merged = AABB2.merge(AABB2.empty, box);
    try testing.expect(approxEq(merged.min_x, box.min_x));
    try testing.expect(approxEq(merged.max_x, box.max_x));
    try testing.expect(approxEq(merged.min_y, box.min_y));
    try testing.expect(approxEq(merged.max_y, box.max_y));
}

test "AABB3 empty constant has min > max on all axes" {
    // Goal: verify the empty sentinel correctly represents an inverted AABB.
    // Method: assert all min components exceed their corresponding max components.
    try testing.expect(AABB3.empty.min_x > AABB3.empty.max_x);
    try testing.expect(AABB3.empty.min_y > AABB3.empty.max_y);
    try testing.expect(AABB3.empty.min_z > AABB3.empty.max_z);
    // Pair assertion: merging empty with a real box produces the real box unchanged.
    const box = AABB3.init(1.0, 2.0, 3.0, 4.0, 5.0, 6.0);
    const merged = AABB3.merge(AABB3.empty, box);
    try testing.expect(approxEq(merged.min_x, box.min_x));
    try testing.expect(approxEq(merged.max_z, box.max_z));
}

test "GridConfig cellIndex and linearIndex" {
    const grid = GridConfig{
        .min_x = 0.0,
        .min_y = 0.0,
        .max_x = 10.0,
        .max_y = 10.0,
        .cells_x = 5,
        .cells_y = 5,
    };

    try testing.expect(approxEq(grid.cellWidth(), 2.0));
    try testing.expect(approxEq(grid.cellHeight(), 2.0));
    try testing.expectEqual(@as(u32, 25), grid.totalCells());

    const idx = grid.cellIndex(3.0, 7.0);
    try testing.expect(idx != null);
    const i = idx.?;
    try testing.expectEqual(@as(u32, 1), i.cx); // 3.0 / 2.0 = 1.5 -> cell 1
    try testing.expectEqual(@as(u32, 3), i.cy); // 7.0 / 2.0 = 3.5 -> cell 3

    try testing.expectEqual(@as(u32, 16), grid.linearIndex(i.cx, i.cy)); // 3*5 + 1

    // Outside returns null.
    try testing.expect(grid.cellIndex(-1.0, 5.0) == null);

    // Exact max boundary should clamp to last cell.
    const edge = grid.cellIndex(10.0, 10.0);
    try testing.expect(edge != null);
    const e = edge.?;
    try testing.expectEqual(@as(u32, 4), e.cx);
    try testing.expectEqual(@as(u32, 4), e.cy);
}
