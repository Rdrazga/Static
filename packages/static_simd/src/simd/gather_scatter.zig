//! Indexed gather/scatter — load/store at non-contiguous offsets.
//!
//! All operations are bounds-checked. On failure, no partial write occurs.

const std = @import("std");
const testing = std.testing;
const vec4f = @import("vec4f.zig");
const vec4i = @import("vec4i.zig");
const masked = @import("masked.zig");
const memory = @import("memory.zig");

/// Gather 4 floats from `base` at indices given by `indices`.
pub fn gather4f(base: []const f32, indices: vec4i.Vec4i) memory.SimdError!vec4f.Vec4f {
    const idx = indices.toArray();
    var result: [4]f32 = undefined;
    inline for (0..4) |i| {
        const j = idx[i];
        if (j < 0) return error.IndexOutOfBounds;
        const uj: usize = @intCast(j);
        if (uj >= base.len) return error.IndexOutOfBounds;
        result[i] = base[uj];
    }
    return vec4f.Vec4f.fromArray(result);
}

/// Scatter 4 floats to `base` at indices given by `indices`.
/// On error, no element is written (all-or-nothing).
pub fn scatter4f(
    base: []f32,
    indices: vec4i.Vec4i,
    values: vec4f.Vec4f,
) memory.SimdError!void {
    const idx = indices.toArray();
    // Validate all indices before writing anything.
    inline for (0..4) |i| {
        const j = idx[i];
        if (j < 0) return error.IndexOutOfBounds;
        if (@as(usize, @intCast(j)) >= base.len) return error.IndexOutOfBounds;
    }
    // All indices valid; perform the writes.
    const vals = values.toArray();
    inline for (0..4) |i| {
        base[@intCast(idx[i])] = vals[i];
    }
}

/// Masked gather: only lanes where mask is true are loaded.
/// Masked-out lanes receive the corresponding value from `passthrough`.
pub fn gatherMasked4f(
    base: []const f32,
    indices: vec4i.Vec4i,
    mask: masked.Mask4,
    passthrough: vec4f.Vec4f,
) memory.SimdError!vec4f.Vec4f {
    const idx = indices.toArray();
    const pass = passthrough.toArray();
    var result: [4]f32 = undefined;
    inline for (0..4) |i| {
        if (mask.v[i]) {
            const j = idx[i];
            if (j < 0) return error.IndexOutOfBounds;
            const uj: usize = @intCast(j);
            if (uj >= base.len) return error.IndexOutOfBounds;
            result[i] = base[uj];
        } else {
            result[i] = pass[i];
        }
    }
    return vec4f.Vec4f.fromArray(result);
}

/// Masked scatter: only lanes where mask is true are stored.
/// On error from a masked lane, no element is written.
pub fn scatterMasked4f(
    base: []f32,
    indices: vec4i.Vec4i,
    values: vec4f.Vec4f,
    mask: masked.Mask4,
) memory.SimdError!void {
    const idx = indices.toArray();
    // Validate masked indices before writing.
    inline for (0..4) |i| {
        if (mask.v[i]) {
            const j = idx[i];
            if (j < 0) return error.IndexOutOfBounds;
            if (@as(usize, @intCast(j)) >= base.len) return error.IndexOutOfBounds;
        }
    }
    const vals = values.toArray();
    inline for (0..4) |i| {
        if (mask.v[i]) {
            base[@intCast(idx[i])] = vals[i];
        }
    }
}

test "gather4f valid indices" {
    const data = [_]f32{ 10.0, 20.0, 30.0, 40.0, 50.0 };
    const indices = vec4i.Vec4i.init(.{ 4, 2, 0, 3 });
    const result = try gather4f(&data, indices);
    const arr = result.toArray();
    try testing.expectEqual(@as(f32, 50.0), arr[0]);
    try testing.expectEqual(@as(f32, 30.0), arr[1]);
    try testing.expectEqual(@as(f32, 10.0), arr[2]);
    try testing.expectEqual(@as(f32, 40.0), arr[3]);
}

test "gather4f out-of-bounds returns error" {
    const data = [_]f32{ 1.0, 2.0, 3.0 };
    const indices = vec4i.Vec4i.init(.{ 0, 1, 2, 3 });
    try testing.expectError(error.IndexOutOfBounds, gather4f(&data, indices));
}

test "scatter4f valid indices" {
    var data = [_]f32{ 0.0, 0.0, 0.0, 0.0, 0.0 };
    const indices = vec4i.Vec4i.init(.{ 1, 3, 0, 4 });
    const values = vec4f.Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });
    try scatter4f(&data, indices, values);
    try testing.expectEqual(@as(f32, 30.0), data[0]);
    try testing.expectEqual(@as(f32, 10.0), data[1]);
    try testing.expectEqual(@as(f32, 20.0), data[3]);
    try testing.expectEqual(@as(f32, 40.0), data[4]);
}

test "scatter4f out-of-bounds: no partial write" {
    var data = [_]f32{ 99.0, 99.0, 99.0 };
    const indices = vec4i.Vec4i.init(.{ 0, 1, 2, 3 });
    const values = vec4f.Vec4f.splat(1.0);
    try testing.expectError(error.IndexOutOfBounds, scatter4f(&data, indices, values));
    // No element should have been modified.
    try testing.expectEqual(@as(f32, 99.0), data[0]);
    try testing.expectEqual(@as(f32, 99.0), data[1]);
    try testing.expectEqual(@as(f32, 99.0), data[2]);
}

test "gatherMasked4f respects mask" {
    const data = [_]f32{ 10.0, 20.0, 30.0, 40.0 };
    const indices = vec4i.Vec4i.init(.{ 0, 1, 2, 3 });
    const mask = masked.Mask4.fromBits(0b0101); // Lanes 0 and 2 active.
    const pass = vec4f.Vec4f.splat(-1.0);

    const result = try gatherMasked4f(&data, indices, mask, pass);
    const arr = result.toArray();
    try testing.expectEqual(@as(f32, 10.0), arr[0]);
    try testing.expectEqual(@as(f32, -1.0), arr[1]);
    try testing.expectEqual(@as(f32, 30.0), arr[2]);
    try testing.expectEqual(@as(f32, -1.0), arr[3]);
}

test "gatherMasked4f ignores invalid indices in masked-out lanes" {
    const data = [_]f32{ 10.0, 20.0, 30.0, 40.0 };
    const indices = vec4i.Vec4i.init(.{ 0, -1, 2, 99 });
    const mask = masked.Mask4.fromBits(0b0101);
    const pass = vec4f.Vec4f.splat(-7.0);

    const result = try gatherMasked4f(&data, indices, mask, pass);
    const arr = result.toArray();
    try testing.expectEqualSlices(f32, &.{ 10.0, -7.0, 30.0, -7.0 }, arr[0..]);
}

test "gatherMasked4f active invalid index returns error" {
    const data = [_]f32{ 10.0, 20.0, 30.0, 40.0 };
    const indices = vec4i.Vec4i.init(.{ 0, -1, 2, 3 });
    const mask = masked.Mask4.fromBits(0b0010);
    const pass = vec4f.Vec4f.splat(0.0);

    try testing.expectError(error.IndexOutOfBounds, gatherMasked4f(&data, indices, mask, pass));
}

test "scatterMasked4f writes active lanes only" {
    var data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const indices = vec4i.Vec4i.init(.{ 0, 1, 2, 3 });
    const values = vec4f.Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });
    const mask = masked.Mask4.fromBits(0b0101);

    try scatterMasked4f(&data, indices, values, mask);
    try testing.expectEqualSlices(f32, &.{ 10.0, 2.0, 30.0, 4.0 }, data[0..]);
}

test "scatterMasked4f no partial write on active out-of-bounds lane" {
    var data = [_]f32{ 5.0, 6.0, 7.0, 8.0 };
    const before = data;
    const indices = vec4i.Vec4i.init(.{ 0, 1, 2, 4 });
    const values = vec4f.Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });
    const mask = masked.Mask4.fromBits(0b1001);

    try testing.expectError(error.IndexOutOfBounds, scatterMasked4f(&data, indices, values, mask));
    try testing.expectEqualSlices(f32, before[0..], data[0..]);
}

test "scatterMasked4f ignores invalid indices in masked-out lanes" {
    var data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const indices = vec4i.Vec4i.init(.{ 0, -1, 2, 99 });
    const values = vec4f.Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });
    const mask = masked.Mask4.fromBits(0b0101);

    try scatterMasked4f(&data, indices, values, mask);
    try testing.expectEqualSlices(f32, &.{ 10.0, 2.0, 30.0, 4.0 }, data[0..]);
}
