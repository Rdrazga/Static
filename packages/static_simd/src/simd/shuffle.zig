//! Lane reordering — shuffle, reverse, rotate, broadcast, unpack, swizzle.
//!
//! All indices are comptime-validated. Out-of-range indices produce @compileError.
//! Single-source shuffles use one input vector. Two-source shuffles merge two vectors.

const std = @import("std");
const vec4f = @import("vec4f.zig");
const vec8f = @import("vec8f.zig");

// -- 4-lane f32 shuffles --

/// Single-source shuffle. `indices[i]` selects from `v`. Negative index produces 0.0.
pub inline fn shuffle4f(v: vec4f.Vec4f, comptime indices: [4]i32) vec4f.Vec4f {
    const idx = comptime blk: {
        var arr: @Vector(4, i32) = undefined;
        for (0..4) |i| {
            if (indices[i] < 0) {
                arr[i] = ~@as(i32, 0); // Sentinel for zero fill.
            } else {
                if (indices[i] >= 4) @compileError("shuffle4f: index out of range [0,3]");
                arr[i] = indices[i];
            }
        }
        break :blk arr;
    };
    const zero_vec: @Vector(4, f32) = @splat(0.0);
    return .{ .v = @shuffle(f32, v.v, zero_vec, idx) };
}

/// Two-source shuffle. Indices 0-3 from `a`, 4-7 from `b`. Negative produces 0.0.
pub inline fn shuffle2x4f(
    a: vec4f.Vec4f,
    b: vec4f.Vec4f,
    comptime indices: [4]i32,
) vec4f.Vec4f {
    const idx = comptime blk: {
        var arr: @Vector(4, i32) = undefined;
        for (0..4) |i| {
            if (indices[i] < 0) {
                arr[i] = ~@as(i32, 0);
            } else if (indices[i] < 4) {
                arr[i] = indices[i];
            } else if (indices[i] < 8) {
                // Zig @shuffle: second-source indices are encoded as ~index.
                arr[i] = ~(indices[i] - 4);
            } else {
                @compileError("shuffle2x4f: index out of range [0,7]");
            }
        }
        break :blk arr;
    };
    return .{ .v = @shuffle(f32, a.v, b.v, idx) };
}

pub inline fn reverse4f(v: vec4f.Vec4f) vec4f.Vec4f {
    return shuffle4f(v, .{ 3, 2, 1, 0 });
}

pub inline fn rotateLeft4f(v: vec4f.Vec4f, comptime n: u2) vec4f.Vec4f {
    const idx = comptime blk: {
        var arr: [4]i32 = undefined;
        for (0..4) |i| {
            arr[i] = @intCast((i + n) % 4);
        }
        break :blk arr;
    };
    return shuffle4f(v, idx);
}

pub inline fn rotateRight4f(v: vec4f.Vec4f, comptime n: u2) vec4f.Vec4f {
    const idx = comptime blk: {
        var arr: [4]i32 = undefined;
        for (0..4) |i| {
            arr[i] = @intCast((i + 4 - n) % 4);
        }
        break :blk arr;
    };
    return shuffle4f(v, idx);
}

pub inline fn broadcast4f(v: vec4f.Vec4f, comptime lane: u2) vec4f.Vec4f {
    const i: i32 = @intCast(lane);
    return shuffle4f(v, .{ i, i, i, i });
}

pub inline fn unpackLo4f(a: vec4f.Vec4f, b: vec4f.Vec4f) vec4f.Vec4f {
    return shuffle2x4f(a, b, .{ 0, 4, 1, 5 });
}

pub inline fn unpackHi4f(a: vec4f.Vec4f, b: vec4f.Vec4f) vec4f.Vec4f {
    return shuffle2x4f(a, b, .{ 2, 6, 3, 7 });
}

// -- 8-lane f32 shuffles --

pub inline fn shuffle8f(v: vec8f.Vec8f, comptime indices: [8]i32) vec8f.Vec8f {
    const idx = comptime blk: {
        var arr: @Vector(8, i32) = undefined;
        for (0..8) |i| {
            if (indices[i] < 0) {
                arr[i] = ~@as(i32, 0);
            } else {
                if (indices[i] >= 8) @compileError("shuffle8f: index out of range [0,7]");
                arr[i] = indices[i];
            }
        }
        break :blk arr;
    };
    const zero_vec: @Vector(8, f32) = @splat(0.0);
    return .{ .v = @shuffle(f32, v.v, zero_vec, idx) };
}

pub inline fn reverse8f(v: vec8f.Vec8f) vec8f.Vec8f {
    return shuffle8f(v, .{ 7, 6, 5, 4, 3, 2, 1, 0 });
}

pub inline fn rotateLeft8f(v: vec8f.Vec8f, comptime n: u3) vec8f.Vec8f {
    const idx = comptime blk: {
        var arr: [8]i32 = undefined;
        for (0..8) |i| {
            arr[i] = @intCast((i + n) % 8);
        }
        break :blk arr;
    };
    return shuffle8f(v, idx);
}

pub inline fn rotateRight8f(v: vec8f.Vec8f, comptime n: u3) vec8f.Vec8f {
    const idx = comptime blk: {
        var arr: [8]i32 = undefined;
        for (0..8) |i| {
            arr[i] = @intCast((i + 8 - n) % 8);
        }
        break :blk arr;
    };
    return shuffle8f(v, idx);
}

pub inline fn broadcast8f(v: vec8f.Vec8f, comptime lane: u3) vec8f.Vec8f {
    const i: i32 = @intCast(lane);
    return shuffle8f(v, .{ i, i, i, i, i, i, i, i });
}

pub inline fn unpackLo8f(a: vec8f.Vec8f, b: vec8f.Vec8f) vec8f.Vec8f {
    const idx = comptime blk: {
        var arr: @Vector(8, i32) = undefined;
        for (0..4) |i| {
            arr[i * 2] = @intCast(i);
            arr[i * 2 + 1] = ~@as(i32, @intCast(i));
        }
        break :blk arr;
    };
    return .{ .v = @shuffle(f32, a.v, b.v, idx) };
}

pub inline fn unpackHi8f(a: vec8f.Vec8f, b: vec8f.Vec8f) vec8f.Vec8f {
    const idx = comptime blk: {
        var arr: @Vector(8, i32) = undefined;
        for (0..4) |i| {
            arr[i * 2] = @intCast(i + 4);
            arr[i * 2 + 1] = ~@as(i32, @intCast(i + 4));
        }
        break :blk arr;
    };
    return .{ .v = @shuffle(f32, a.v, b.v, idx) };
}

// -- Swizzle4 namespace --

pub const Swizzle4 = struct {
    pub inline fn xxxx(v: vec4f.Vec4f) vec4f.Vec4f {
        return shuffle4f(v, .{ 0, 0, 0, 0 });
    }
    pub inline fn xyzw(v: vec4f.Vec4f) vec4f.Vec4f {
        return v; // Identity swizzle.
    }
    pub inline fn wzyx(v: vec4f.Vec4f) vec4f.Vec4f {
        return shuffle4f(v, .{ 3, 2, 1, 0 });
    }
    pub inline fn xyxy(v: vec4f.Vec4f) vec4f.Vec4f {
        return shuffle4f(v, .{ 0, 1, 0, 1 });
    }
    pub inline fn zwzw(v: vec4f.Vec4f) vec4f.Vec4f {
        return shuffle4f(v, .{ 2, 3, 2, 3 });
    }
};

test "shuffle4f basic reorder" {
    const v = vec4f.Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });
    const result = shuffle4f(v, .{ 3, 2, 1, 0 }).toArray();
    try std.testing.expectEqual(@as(f32, 40.0), result[0]);
    try std.testing.expectEqual(@as(f32, 10.0), result[3]);
}

test "shuffle4f supports zero fill with negative indices" {
    const v = vec4f.Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });
    const result = shuffle4f(v, .{ 2, -1, 0, -1 }).toArray();
    try std.testing.expectEqual(@as(f32, 30.0), result[0]);
    try std.testing.expectEqual(@as(f32, 0.0), result[1]);
    try std.testing.expectEqual(@as(f32, 10.0), result[2]);
    try std.testing.expectEqual(@as(f32, 0.0), result[3]);
}

test "shuffle4f exhaustive lane mappings" {
    @setEvalBranchQuota(10000);
    const src = vec4f.Vec4f.init(.{ 0.0, 1.0, 2.0, 3.0 });

    inline for (0..4) |a| {
        inline for (0..4) |b| {
            inline for (0..4) |c| {
                inline for (0..4) |d| {
                    const result = shuffle4f(src, .{
                        @intCast(a),
                        @intCast(b),
                        @intCast(c),
                        @intCast(d),
                    }).toArray();
                    try std.testing.expectEqual(@as(f32, @floatFromInt(a)), result[0]);
                    try std.testing.expectEqual(@as(f32, @floatFromInt(b)), result[1]);
                    try std.testing.expectEqual(@as(f32, @floatFromInt(c)), result[2]);
                    try std.testing.expectEqual(@as(f32, @floatFromInt(d)), result[3]);
                }
            }
        }
    }
}

test "shuffle2x4f two-source merge" {
    const a = vec4f.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b = vec4f.Vec4f.init(.{ 5.0, 6.0, 7.0, 8.0 });
    // Take lane 0 from a, lane 0 from b, lane 1 from a, lane 1 from b.
    const result = shuffle2x4f(a, b, .{ 0, 4, 1, 5 }).toArray();
    try std.testing.expectEqual(@as(f32, 1.0), result[0]);
    try std.testing.expectEqual(@as(f32, 5.0), result[1]);
    try std.testing.expectEqual(@as(f32, 2.0), result[2]);
    try std.testing.expectEqual(@as(f32, 6.0), result[3]);
}

test "reverse4f" {
    const v = vec4f.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const r = reverse4f(v).toArray();
    try std.testing.expectEqual(@as(f32, 4.0), r[0]);
    try std.testing.expectEqual(@as(f32, 1.0), r[3]);
}

test "unpackLo4f and unpackHi4f interleave lanes" {
    const a = vec4f.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b = vec4f.Vec4f.init(.{ 5.0, 6.0, 7.0, 8.0 });
    const lo = unpackLo4f(a, b).toArray();
    const hi = unpackHi4f(a, b).toArray();
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 5.0, 2.0, 6.0 }, lo[0..]);
    try std.testing.expectEqualSlices(f32, &.{ 3.0, 7.0, 4.0, 8.0 }, hi[0..]);
}

test "rotateLeft4f and rotateRight4f are inverses" {
    const v = vec4f.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const rotated = rotateLeft4f(v, 1);
    const back = rotateRight4f(rotated, 1);
    try std.testing.expectEqual(v.toArray(), back.toArray());
}

test "broadcast4f" {
    const v = vec4f.Vec4f.init(.{ 10.0, 20.0, 30.0, 40.0 });
    const b = broadcast4f(v, 2).toArray();
    try std.testing.expectEqual(@as(f32, 30.0), b[0]);
    try std.testing.expectEqual(@as(f32, 30.0), b[3]);
}

test "Swizzle4 wzyx equals reverse" {
    const v = vec4f.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    try std.testing.expectEqual(
        Swizzle4.wzyx(v).toArray(),
        reverse4f(v).toArray(),
    );
}

test "shuffle8f and helpers" {
    const v = vec8f.Vec8f.fromArray(.{ 10, 20, 30, 40, 50, 60, 70, 80 });
    const shuffled = shuffle8f(v, .{ 7, 6, 5, 4, 3, 2, 1, 0 }).toArray();
    try std.testing.expectEqual(@as(f32, 80.0), shuffled[0]);
    try std.testing.expectEqual(@as(f32, 10.0), shuffled[7]);

    const zero_filled = shuffle8f(v, .{ 0, -1, 1, -1, 2, -1, 3, -1 }).toArray();
    try std.testing.expectEqual(@as(f32, 10.0), zero_filled[0]);
    try std.testing.expectEqual(@as(f32, 0.0), zero_filled[1]);
    try std.testing.expectEqual(@as(f32, 40.0), zero_filled[6]);
    try std.testing.expectEqual(@as(f32, 0.0), zero_filled[7]);

    const reversed = reverse8f(v).toArray();
    try std.testing.expectEqual(@as(f32, 80.0), reversed[0]);
    try std.testing.expectEqual(@as(f32, 10.0), reversed[7]);

    const rotated = rotateLeft8f(v, 3);
    const back = rotateRight8f(rotated, 3);
    try std.testing.expectEqual(v.toArray(), back.toArray());

    const broadcasted = broadcast8f(v, 4).toArray();
    try std.testing.expectEqual(@as(f32, 50.0), broadcasted[0]);
    try std.testing.expectEqual(@as(f32, 50.0), broadcasted[7]);
}

test "unpackLo8f and unpackHi8f interleave halves" {
    const a = vec8f.Vec8f.fromArray(.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const b = vec8f.Vec8f.fromArray(.{ 10, 20, 30, 40, 50, 60, 70, 80 });
    const lo = unpackLo8f(a, b).toArray();
    const hi = unpackHi8f(a, b).toArray();
    try std.testing.expectEqualSlices(f32, &.{ 1, 10, 2, 20, 3, 30, 4, 40 }, lo[0..]);
    try std.testing.expectEqualSlices(f32, &.{ 5, 50, 6, 60, 7, 70, 8, 80 }, hi[0..]);
}

test "Swizzle4 predefined patterns" {
    const v = vec4f.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const xxxx = Swizzle4.xxxx(v).toArray();
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1 }, xxxx[0..]);
    const xyzw = Swizzle4.xyzw(v).toArray();
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, xyzw[0..]);
    const xyxy = Swizzle4.xyxy(v).toArray();
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 1, 2 }, xyxy[0..]);
    const zwzw = Swizzle4.zwzw(v).toArray();
    try std.testing.expectEqualSlices(f32, &.{ 3, 4, 3, 4 }, zwzw[0..]);
}
