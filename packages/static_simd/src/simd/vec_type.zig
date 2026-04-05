//! Generic SIMD vector factory — single source of truth for all vec types.
//!
//! `VecType(N, Element)` produces a fully-featured SIMD vector struct for any
//! supported width (2, 4, 8, 16) and element type (f32, f64, i32, u32).
//! Operations are comptime-gated: float-only ops (div, copySign) and
//! integer-only ops (bitwise, shifts) produce a compile error if called
//! on the wrong element type.
//!
//! Public type aliases at the bottom preserve the existing API:
//! `Vec2f`, `Vec4f`, `Vec8f`, `Vec16f`, `Vec4d`, `Vec2i`, `Vec4i`, `Vec8i`, `Vec4u`.
//!
//! Thread safety: all operations are pure functions with no shared state.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const masked = @import("masked.zig");

// ---------------------------------------------------------------------------
// Compile-time classification helpers
// ---------------------------------------------------------------------------

/// Return the number of bits needed to index any lane in a vector of width N.
/// N must be a power of two in {2, 4, 8, 16}.
fn laneIndexBits(comptime N: comptime_int) comptime_int {
    comptime assert(N == 2 or N == 4 or N == 8 or N == 16);
    return switch (N) {
        2 => 1,
        4 => 2,
        8 => 3,
        16 => 4,
        else => unreachable,
    };
}

/// Return the Mask type corresponding to a lane count.
fn MaskFor(comptime N: comptime_int) type {
    comptime assert(N == 2 or N == 4 or N == 8 or N == 16);
    return switch (N) {
        2 => masked.Mask2,
        4 => masked.Mask4,
        8 => masked.Mask8,
        16 => masked.Mask16,
        else => unreachable,
    };
}

fn isFloat(comptime Element: type) bool {
    return @typeInfo(Element) == .float;
}

fn isSigned(comptime Element: type) bool {
    const info = @typeInfo(Element);
    return info == .int and info.int.signedness == .signed;
}

fn isInt(comptime Element: type) bool {
    return @typeInfo(Element) == .int;
}

fn isUnsigned(comptime Element: type) bool {
    const info = @typeInfo(Element);
    return info == .int and info.int.signedness == .unsigned;
}

// ---------------------------------------------------------------------------
// VecType factory
// ---------------------------------------------------------------------------

/// Produce a SIMD vector struct for `N` lanes of `Element`.
///
/// Supported widths: 2, 4, 8, 16.
/// Element types: f32, f64, i32, u32 (any fixed-size numeric type).
///
/// Universal (all element types):
///   `splat`, `fromArray`, `toArray`, `add`, `sub`, `mul`,
///   `min`, `max`, `select`, `extract`, `insert`.
///
/// Float-only: `div`, `negate`, `abs`, `copySign`.
/// Signed-integer-only: `negate`, `abs` (with minInt overflow assertion).
/// Integer-only: `bitAnd`, `bitOr`, `bitXor`, `bitNot`, `shl`, `shr`.
/// Unsigned `sub`: asserts all lanes satisfy `a >= b` before subtracting.
pub fn VecType(comptime N: comptime_int, comptime Element: type) type {
    comptime {
        assert(N > 0);
        assert(N == 2 or N == 4 or N == 8 or N == 16);
        assert(@sizeOf(Element) > 0);
    }

    const LaneIdx = std.meta.Int(.unsigned, laneIndexBits(N));
    const Mask = MaskFor(N);
    const Vec = @Vector(N, Element);

    return struct {
        v: Vec,

        const Self = @This();

        // -- Construction --

        /// Construct from N individual values packed in an array literal.
        /// Call as `Vec4f.init(.{x, y, z, w})`.
        pub inline fn init(args: [N]Element) Self {
            comptime assert(N > 0);
            return .{ .v = args };
        }

        /// Broadcast a single scalar to all N lanes.
        pub inline fn splat(scalar: Element) Self {
            comptime assert(@sizeOf(Element) > 0);
            return .{ .v = @splat(scalar) };
        }

        /// Construct from a fixed-size array of N elements.
        pub inline fn fromArray(arr: [N]Element) Self {
            comptime assert(N > 0);
            return .{ .v = arr };
        }

        /// Convert to a fixed-size array of N elements.
        pub inline fn toArray(self: Self) [N]Element {
            return self.v;
        }

        // -- Arithmetic (universal) --

        /// Lane-wise addition.
        pub inline fn add(a: Self, b: Self) Self {
            return .{ .v = a.v + b.v };
        }

        /// Lane-wise subtraction.
        /// For unsigned element types, asserts `a >= b` per lane to prevent underflow.
        pub inline fn sub(a: Self, b: Self) Self {
            if (comptime isUnsigned(Element)) {
                assert(@reduce(.And, a.v >= b.v));
            }
            return .{ .v = a.v - b.v };
        }

        /// Lane-wise multiplication.
        pub inline fn mul(a: Self, b: Self) Self {
            return .{ .v = a.v * b.v };
        }

        // -- Comparison (universal) --

        /// Lane-wise minimum.
        pub inline fn min(a: Self, b: Self) Self {
            return .{ .v = @min(a.v, b.v) };
        }

        /// Lane-wise maximum.
        pub inline fn max(a: Self, b: Self) Self {
            return .{ .v = @max(a.v, b.v) };
        }

        // -- Conditional select (universal) --

        /// Select per lane: where mask is true, take `a`; otherwise take `b`.
        pub inline fn select(mask: Mask, a: Self, b: Self) Self {
            return .{ .v = @select(Element, mask.v, a.v, b.v) };
        }

        // -- Lane access (universal) --

        /// Extract the value of a single lane. `i` must be in [0, N).
        pub inline fn extract(self: Self, comptime i: LaneIdx) Element {
            comptime assert(i < N);
            return self.v[i];
        }

        /// Return a copy of `self` with lane `i` replaced by `val`.
        pub inline fn insert(self: Self, comptime i: LaneIdx, val: Element) Self {
            comptime assert(i < N);
            var result = self.v;
            result[i] = val;
            return .{ .v = result };
        }

        // -- Float-only operations (compile error on integer types) --

        /// Lane-wise division. Only valid for floating-point element types.
        pub inline fn div(a: Self, b: Self) Self {
            if (comptime !isFloat(Element)) {
                @compileError("div is only defined for floating-point VecTypes, got " ++ @typeName(Element));
            }
            return .{ .v = a.v / b.v };
        }

        /// Copy sign: result[i] = abs(magnitude_source[i]) with sign of sign_source[i].
        /// Only valid for floating-point element types.
        pub inline fn copySign(magnitude_source: Self, sign_source: Self) Self {
            if (comptime !isFloat(Element)) {
                @compileError("copySign is only defined for floating-point VecTypes, got " ++ @typeName(Element));
            }
            const mag = @abs(magnitude_source.v);
            const zero: Vec = @splat(@as(Element, 0.0));
            const neg_mask = sign_source.v < zero;
            return .{ .v = @select(Element, neg_mask, -mag, mag) };
        }

        // -- Sign operations (float and signed integer only) --

        /// Negate all lanes.
        /// Float: standard IEEE negation.
        /// Signed integer: asserts no lane equals minInt (negating minInt overflows).
        /// Unsigned integer: compile error.
        pub inline fn negate(a: Self) Self {
            if (comptime isUnsigned(Element)) {
                @compileError("negate is not defined for unsigned integer VecTypes, got " ++ @typeName(Element));
            }
            if (comptime isSigned(Element)) {
                const min_int: Vec = @splat(std.math.minInt(Element));
                assert(!@reduce(.Or, a.v == min_int));
            }
            return .{ .v = -a.v };
        }

        /// Absolute value.
        /// Float: IEEE bit-clear.
        /// Signed integer: select-based; asserts no lane equals minInt.
        /// Unsigned integer: compile error.
        pub inline fn abs(a: Self) Self {
            if (comptime isUnsigned(Element)) {
                @compileError("abs is not defined for unsigned integer VecTypes, got " ++ @typeName(Element));
            }
            if (comptime isSigned(Element)) {
                const min_int: Vec = @splat(std.math.minInt(Element));
                assert(!@reduce(.Or, a.v == min_int));
                const zero: Vec = @splat(@as(Element, 0));
                const neg_mask = a.v < zero;
                return .{ .v = @select(Element, neg_mask, -a.v, a.v) };
            }
            return .{ .v = @abs(a.v) };
        }

        // -- Integer-only bitwise operations (compile error on float types) --

        /// Lane-wise bitwise AND. Only valid for integer element types.
        pub inline fn bitAnd(a: Self, b: Self) Self {
            if (comptime !isInt(Element)) {
                @compileError("bitAnd is only defined for integer VecTypes, got " ++ @typeName(Element));
            }
            return .{ .v = a.v & b.v };
        }

        /// Lane-wise bitwise OR. Only valid for integer element types.
        pub inline fn bitOr(a: Self, b: Self) Self {
            if (comptime !isInt(Element)) {
                @compileError("bitOr is only defined for integer VecTypes, got " ++ @typeName(Element));
            }
            return .{ .v = a.v | b.v };
        }

        /// Lane-wise bitwise XOR. Only valid for integer element types.
        pub inline fn bitXor(a: Self, b: Self) Self {
            if (comptime !isInt(Element)) {
                @compileError("bitXor is only defined for integer VecTypes, got " ++ @typeName(Element));
            }
            return .{ .v = a.v ^ b.v };
        }

        /// Lane-wise bitwise NOT. Only valid for integer element types.
        pub inline fn bitNot(a: Self) Self {
            if (comptime !isInt(Element)) {
                @compileError("bitNot is only defined for integer VecTypes, got " ++ @typeName(Element));
            }
            return .{ .v = ~a.v };
        }

        /// Lane-wise left shift by a comptime constant in [0, bitSize).
        /// Only valid for integer element types.
        pub inline fn shl(a: Self, comptime shift: u5) Self {
            if (comptime !isInt(Element)) {
                @compileError("shl is only defined for integer VecTypes, got " ++ @typeName(Element));
            }
            comptime assert(shift < @bitSizeOf(Element));
            return .{ .v = a.v << @as(@Vector(N, u5), @splat(shift)) };
        }

        /// Lane-wise arithmetic right shift by a comptime constant in [0, bitSize).
        /// Only valid for integer element types.
        pub inline fn shr(a: Self, comptime shift: u5) Self {
            if (comptime !isInt(Element)) {
                @compileError("shr is only defined for integer VecTypes, got " ++ @typeName(Element));
            }
            comptime assert(shift < @bitSizeOf(Element));
            return .{ .v = a.v >> @as(@Vector(N, u5), @splat(shift)) };
        }
    };
}

// ---------------------------------------------------------------------------
// Public type aliases — preserve the existing API surface
// ---------------------------------------------------------------------------

pub const Vec2f = VecType(2, f32);
pub const Vec4f = VecType(4, f32);
pub const Vec8f = VecType(8, f32);
pub const Vec16f = VecType(16, f32);
pub const Vec4d = VecType(4, f64);
pub const Vec2i = VecType(2, i32);
pub const Vec4i = VecType(4, i32);
pub const Vec8i = VecType(8, i32);
pub const Vec4u = VecType(4, u32);

// ---------------------------------------------------------------------------
// SI-T1: NaN propagation tests for Vec2f and Vec8f
// ---------------------------------------------------------------------------

test "VecType f32 NaN propagation in min — Vec2f and Vec8f" {
    // IEEE 754: min(NaN, x) and min(x, NaN) are implementation-defined.
    // Zig's @min preserves the behaviour of the underlying hardware instruction.
    // This test documents the actual behaviour so regressions are detectable.

    const nan = std.math.nan(f32);
    const one: f32 = 1.0;

    // Vec2f: NaN in lane 0, normal in lane 1.
    const v2_nan = Vec2f.fromArray(.{ nan, one });
    const v2_one = Vec2f.splat(one);
    const v2_min_result = Vec2f.min(v2_nan, v2_one).toArray();
    const v2_min_rev = Vec2f.min(v2_one, v2_nan).toArray();
    // Both orderings must produce the same lane-0 result (consistent behaviour).
    try testing.expectEqual(std.math.isNan(v2_min_result[0]), std.math.isNan(v2_min_rev[0]));
    // Lane 1 (both normal) must equal one in both orderings.
    try testing.expectEqual(@as(f32, one), v2_min_result[1]);
    try testing.expectEqual(@as(f32, one), v2_min_rev[1]);

    // Vec8f: all-NaN vector vs all-one vector.
    const v8_nan = Vec8f.splat(nan);
    const v8_one = Vec8f.splat(one);
    const v8_min_ab = Vec8f.min(v8_nan, v8_one).toArray();
    const v8_min_ba = Vec8f.min(v8_one, v8_nan).toArray();
    // Document consistent behaviour: both orderings must agree per lane.
    for (0..8) |i| {
        try testing.expectEqual(std.math.isNan(v8_min_ab[i]), std.math.isNan(v8_min_ba[i]));
    }
}

test "VecType f32 NaN propagation in max — Vec2f and Vec8f" {
    const nan = std.math.nan(f32);
    const one: f32 = 1.0;

    // Vec2f: NaN in lane 0, normal in lane 1.
    const v2_nan = Vec2f.fromArray(.{ nan, one });
    const v2_one = Vec2f.splat(one);
    const v2_max_result = Vec2f.max(v2_nan, v2_one).toArray();
    const v2_max_rev = Vec2f.max(v2_one, v2_nan).toArray();
    try testing.expectEqual(std.math.isNan(v2_max_result[0]), std.math.isNan(v2_max_rev[0]));
    try testing.expectEqual(@as(f32, one), v2_max_result[1]);
    try testing.expectEqual(@as(f32, one), v2_max_rev[1]);

    // Vec8f: all-NaN vector vs all-one vector.
    const v8_nan = Vec8f.splat(nan);
    const v8_one = Vec8f.splat(one);
    const v8_max_ab = Vec8f.max(v8_nan, v8_one).toArray();
    const v8_max_ba = Vec8f.max(v8_one, v8_nan).toArray();
    for (0..8) |i| {
        try testing.expectEqual(std.math.isNan(v8_max_ab[i]), std.math.isNan(v8_max_ba[i]));
    }
}

test "VecType Vec2f arithmetic matches scalar reference" {
    const a = Vec2f.fromArray(.{ 1.0, 2.0 });
    const b = Vec2f.fromArray(.{ 10.0, 20.0 });

    const sum = Vec2f.add(a, b).toArray();
    try testing.expectEqual(@as(f32, 11.0), sum[0]);
    try testing.expectEqual(@as(f32, 22.0), sum[1]);

    const prod = Vec2f.mul(a, b).toArray();
    try testing.expectEqual(@as(f32, 10.0), prod[0]);
    try testing.expectEqual(@as(f32, 40.0), prod[1]);
}

test "VecType Vec4f round-trip and sign ops" {
    const arr = [4]f32{ 1.5, -2.5, 3.5, -4.5 };
    const v = Vec4f.fromArray(arr);
    try testing.expectEqual(arr, v.toArray());

    const neg = Vec4f.negate(v).toArray();
    try testing.expectEqual(@as(f32, -1.5), neg[0]);
    try testing.expectEqual(@as(f32, 4.5), neg[3]);

    const a = Vec4f.abs(v).toArray();
    try testing.expectEqual(@as(f32, 1.5), a[0]);
    try testing.expectEqual(@as(f32, 2.5), a[1]);
}

test "VecType Vec4u unsigned sub no underflow" {
    const a = Vec4u.fromArray(.{ 10, 20, 30, 40 });
    const b = Vec4u.fromArray(.{ 1, 2, 3, 4 });
    const diff = Vec4u.sub(a, b).toArray();
    try testing.expectEqual(@as(u32, 9), diff[0]);
    try testing.expectEqual(@as(u32, 36), diff[3]);
}

test "VecType Vec4i bitwise and shift operations" {
    const a = Vec4i.fromArray(.{ 0b1100, 0b1010, 0b0000, 0b1111 });
    const b = Vec4i.fromArray(.{ 0b1010, 0b1100, 0b1111, 0b0000 });

    const and_r = Vec4i.bitAnd(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b1000), and_r[0]);

    const or_r = Vec4i.bitOr(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b1110), or_r[0]);

    const xor_r = Vec4i.bitXor(a, b).toArray();
    try testing.expectEqual(@as(i32, 0b0110), xor_r[0]);

    const left = Vec4i.shl(Vec4i.splat(1), 4).toArray();
    try testing.expectEqual(@as(i32, 16), left[0]);

    const right = Vec4i.shr(Vec4i.splat(64), 2).toArray();
    try testing.expectEqual(@as(i32, 16), right[0]);
}

test "VecType Vec8f splat and select" {
    const a = Vec8f.splat(3.0);
    const b = Vec8f.splat(7.0);
    const mask = masked.Mask8.fromBits(0b01010101);
    const selected = Vec8f.select(mask, a, b).toArray();
    try testing.expectEqual(@as(f32, 3.0), selected[0]);
    try testing.expectEqual(@as(f32, 7.0), selected[1]);
    try testing.expectEqual(@as(f32, 3.0), selected[6]);
    try testing.expectEqual(@as(f32, 7.0), selected[7]);
}

test "VecType Vec16f lane extract and insert" {
    var v = Vec16f.splat(0.0);
    v = v.insert(0, 1.0);
    v = v.insert(15, 16.0);
    try testing.expectEqual(@as(f32, 1.0), v.extract(0));
    try testing.expectEqual(@as(f32, 16.0), v.extract(15));
    try testing.expectEqual(@as(f32, 0.0), v.extract(8));
}

test "VecType Vec4d arithmetic precision" {
    const a = Vec4d.fromArray(.{ 1.0, 2.0, 3.0, 4.0 });
    const b = Vec4d.fromArray(.{ 10.0, 20.0, 30.0, 40.0 });
    const sum = Vec4d.add(a, b).toArray();
    try testing.expectEqual(@as(f64, 11.0), sum[0]);
    try testing.expectEqual(@as(f64, 44.0), sum[3]);
}

test "VecType Vec2i sign and comparison" {
    const a = Vec2i.fromArray(.{ -7, 9 });
    const b = Vec2i.fromArray(.{ 3, -10 });

    const neg = Vec2i.negate(a).toArray();
    try testing.expectEqual(@as(i32, 7), neg[0]);
    try testing.expectEqual(@as(i32, -9), neg[1]);

    const mins = Vec2i.min(a, b).toArray();
    try testing.expectEqual(@as(i32, -7), mins[0]);
    try testing.expectEqual(@as(i32, -10), mins[1]);
}
