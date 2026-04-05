//! Mask-producing comparisons for SIMD vectors.
//!
//! Each function compares two vectors lane-by-lane and returns a mask
//! indicating which lanes satisfy the comparison. All functions accept any
//! VecType via `anytype`, with comptime validation that rejects unsupported
//! types at compile time. The `horizontal.zig` module uses the same pattern.
//!
//! Supported vector types: Vec4f, Vec8f, Vec4i, Vec8i (and any VecType whose
//! element type supports ordering comparisons).
//!
//! Backward-compatible width-suffixed aliases are provided at the bottom.
//! Keep that alias set stable rather than growing it until a real downstream
//! consumer proves the extra names are worth carrying.
//!
//! Thread safety: all operations are pure functions; no shared state.

const std = @import("std");
const testing = std.testing;
const vec_type = @import("vec_type.zig");
const masked = @import("masked.zig");

// ---------------------------------------------------------------------------
// Comptime type validation and mask resolution
// ---------------------------------------------------------------------------

/// Return the Mask type that corresponds to a given VecType T.
/// Produces a clear compile error for unsupported types.
fn MaskFor(comptime T: type) type {
    if (T == vec_type.Vec4f or T == vec_type.Vec4i or T == vec_type.Vec4u or T == vec_type.Vec4d) {
        return masked.Mask4;
    }
    if (T == vec_type.Vec8f or T == vec_type.Vec8i) {
        return masked.Mask8;
    }
    if (T == vec_type.Vec2f or T == vec_type.Vec2i) {
        return masked.Mask2;
    }
    if (T == vec_type.Vec16f) {
        return masked.Mask16;
    }
    @compileError(
        "compare operations require a supported VecType; got: " ++ @typeName(T),
    );
}

// ---------------------------------------------------------------------------
// Generic comparison operations (anytype, comptime-validated)
// ---------------------------------------------------------------------------

/// Lane-wise equality: result[i] = (a[i] == b[i]).
pub inline fn cmpEq(a: anytype, b: @TypeOf(a)) MaskFor(@TypeOf(a)) {
    return .{ .v = a.v == b.v };
}

/// Lane-wise less-than: result[i] = (a[i] < b[i]).
pub inline fn cmpLt(a: anytype, b: @TypeOf(a)) MaskFor(@TypeOf(a)) {
    return .{ .v = a.v < b.v };
}

/// Lane-wise less-or-equal: result[i] = (a[i] <= b[i]).
pub inline fn cmpLe(a: anytype, b: @TypeOf(a)) MaskFor(@TypeOf(a)) {
    return .{ .v = a.v <= b.v };
}

/// Lane-wise greater-than: result[i] = (a[i] > b[i]).
pub inline fn cmpGt(a: anytype, b: @TypeOf(a)) MaskFor(@TypeOf(a)) {
    return .{ .v = a.v > b.v };
}

/// Lane-wise greater-or-equal: result[i] = (a[i] >= b[i]).
pub inline fn cmpGe(a: anytype, b: @TypeOf(a)) MaskFor(@TypeOf(a)) {
    return .{ .v = a.v >= b.v };
}

// ---------------------------------------------------------------------------
// Backward-compatible width-suffixed aliases
// ---------------------------------------------------------------------------

pub const cmpEq4f = cmpEq;
pub const cmpLt4f = cmpLt;
pub const cmpLe4f = cmpLe;
pub const cmpGt4f = cmpGt;
pub const cmpGe4f = cmpGe;

pub const cmpEq8f = cmpEq;
pub const cmpLt8f = cmpLt;
pub const cmpLe8f = cmpLe;
pub const cmpGt8f = cmpGt;
pub const cmpGe8f = cmpGe;

pub const cmpEq4i = cmpEq;
pub const cmpLt4i = cmpLt;
pub const cmpLe4i = cmpLe;
pub const cmpGt4i = cmpGt;
pub const cmpGe4i = cmpGe;

pub const cmpEq8i = cmpEq;
pub const cmpLt8i = cmpLt;
pub const cmpLe8i = cmpLe;
pub const cmpGt8i = cmpGt;
pub const cmpGe8i = cmpGe;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "4-lane f32 comparisons produce expected mask bits" {
    const a = vec_type.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b = vec_type.Vec4f.init(.{ 1.0, 3.0, 2.0, 4.0 });

    const eq = cmpEq(a, b);
    try testing.expectEqual(@as(u4, 0b1001), eq.toBits());

    const lt = cmpLt(a, b);
    try testing.expectEqual(@as(u4, 0b0010), lt.toBits());

    const le = cmpLe(a, b);
    try testing.expectEqual(@as(u4, 0b1011), le.toBits());

    const gt = cmpGt(a, b);
    try testing.expectEqual(@as(u4, 0b0100), gt.toBits());

    const ge = cmpGe(a, b);
    try testing.expectEqual(@as(u4, 0b1101), ge.toBits());
}

test "8-lane f32 comparisons produce expected mask bits" {
    const a = vec_type.Vec8f.fromArray(.{ 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0 });
    const b = vec_type.Vec8f.fromArray(.{ 0.0, 2.0, 1.0, 3.0, 5.0, 4.0, 6.0, 8.0 });

    try testing.expectEqual(@as(u8, 0b01001001), cmpEq(a, b).toBits());
    try testing.expectEqual(@as(u8, 0b10010010), cmpLt(a, b).toBits());
    try testing.expectEqual(@as(u8, 0b11011011), cmpLe(a, b).toBits());
    try testing.expectEqual(@as(u8, 0b00100100), cmpGt(a, b).toBits());
    try testing.expectEqual(@as(u8, 0b01101101), cmpGe(a, b).toBits());
}

test "4-lane i32 comparisons produce expected mask bits" {
    const a = vec_type.Vec4i.init(.{ 0, -1, 5, 5 });
    const b = vec_type.Vec4i.init(.{ 0, 0, 5, 4 });

    try testing.expectEqual(@as(u4, 0b0101), cmpEq(a, b).toBits());
    try testing.expectEqual(@as(u4, 0b0010), cmpLt(a, b).toBits());
    try testing.expectEqual(@as(u4, 0b0111), cmpLe(a, b).toBits());
    try testing.expectEqual(@as(u4, 0b1000), cmpGt(a, b).toBits());
    try testing.expectEqual(@as(u4, 0b1101), cmpGe(a, b).toBits());
}

test "8-lane i32 comparisons produce expected mask bits" {
    const a = vec_type.Vec8i.fromArray(.{ 0, -1, 5, 7, 9, 11, 13, 15 });
    const b = vec_type.Vec8i.fromArray(.{ 0, 0, 4, 7, 10, 10, 13, 16 });

    try testing.expectEqual(@as(u8, 0b01001001), cmpEq(a, b).toBits());
    try testing.expectEqual(@as(u8, 0b10010010), cmpLt(a, b).toBits());
    try testing.expectEqual(@as(u8, 0b11011011), cmpLe(a, b).toBits());
    try testing.expectEqual(@as(u8, 0b00100100), cmpGt(a, b).toBits());
    try testing.expectEqual(@as(u8, 0b01101101), cmpGe(a, b).toBits());
}

// Backward-compat alias smoke test: ensure the old names still compile.
test "backward-compat aliases cmpEq4f/cmpLt8i still work" {
    const a4 = vec_type.Vec4f.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b4 = vec_type.Vec4f.init(.{ 1.0, 3.0, 2.0, 4.0 });
    const eq4 = cmpEq4f(a4, b4);
    try testing.expectEqual(@as(u4, 0b1001), eq4.toBits());

    const a8i = vec_type.Vec8i.fromArray(.{ 0, -1, 5, 7, 9, 11, 13, 15 });
    const b8i = vec_type.Vec8i.fromArray(.{ 0, 0, 4, 7, 10, 10, 13, 16 });
    const lt8 = cmpLt8i(a8i, b8i);
    try testing.expectEqual(@as(u8, 0b10010010), lt8.toBits());
}
