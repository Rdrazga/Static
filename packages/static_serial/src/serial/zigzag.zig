//! ZigZag integer encoding for efficient varint representation of signed values.
//!
//! Key types: `Error`.
//! Usage pattern: call `zigZagEncode(value)` before writing a signed integer as a
//! varint; call `zigZagDecode(Signed, raw)` after reading the unsigned varint.
//! Thread safety: not thread-safe — all functions are pure and stateless.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const Error = error{
    InvalidInput,
};

pub fn zigZagEncode(value: anytype) signedToUnsigned(@TypeOf(value)) {
    const S = @TypeOf(value);
    const info = @typeInfo(S);
    if (info != .int or info.int.signedness != .signed) {
        @compileError("zigZagEncode expects a signed integer type");
    }
    // Comptime: bit width must be positive (zero-width signed ints are unusable).
    comptime assert(info.int.bits > 0);

    const U = signedToUnsigned(S);
    const shift_amt: std.math.Log2Int(U) = @intCast(info.int.bits - 1);
    const sign: U = @bitCast(value >> shift_amt);
    const encoded = (@as(U, @bitCast(value)) << 1) ^ sign;
    // Postcondition: zigzag roundtrip -- decode(encode(x)) == x.
    assert(zigZagDecode(S, encoded) == value);
    return encoded;
}

pub fn zigZagDecode(comptime Signed: type, value: anytype) Signed {
    const signed_info = @typeInfo(Signed);
    if (signed_info != .int or signed_info.int.signedness != .signed) {
        @compileError("zigZagDecode expects a signed integer type");
    }
    // Comptime: signed bit width must be positive.
    comptime assert(signed_info.int.bits > 0);

    const U = @TypeOf(value);
    const u_info = @typeInfo(U);
    if (u_info != .int) {
        @compileError("zigZagDecode value type must be an unsigned integer");
    }
    if (u_info.int.signedness != .unsigned) {
        @compileError("zigZagDecode value type must be an unsigned integer");
    }
    if (u_info.int.bits != signed_info.int.bits) {
        @compileError(
            "zigZagDecode value type must be an unsigned integer with matching bit width",
        );
    }

    const decoded: U = (value >> 1) ^ (0 -% (value & 1));
    return @as(Signed, @bitCast(decoded));
}

/// SE-R1: Renamed from `unsignedOf` to `signedToUnsigned`.
/// Converts a signed integer type to its unsigned equivalent with the same bit
/// width. Requires a signed input -- contrast with varint.toUnsigned which
/// accepts any integer type.
pub fn signedToUnsigned(comptime Signed: type) type {
    const info = @typeInfo(Signed);
    if (info != .int or info.int.signedness != .signed) {
        @compileError("signedToUnsigned expects a signed integer type");
    }
    return std.meta.Int(.unsigned, info.int.bits);
}

test "zigzag roundtrip signed values" {
    const values = [_]i64{ std.math.minInt(i64), -1, 0, 1, std.math.maxInt(i64) };
    for (values) |v| {
        const enc = zigZagEncode(v);
        const dec = zigZagDecode(i64, enc);
        try testing.expectEqual(v, dec);
    }
}

test "SE-T3: zigzag i8 boundary values roundtrip" {
    // Goal: verify zigzag encoding is correct for 8-bit signed boundaries.
    // Method: test min, -1, 0, 1, max for i8.
    const values = [_]i8{ std.math.minInt(i8), -1, 0, 1, std.math.maxInt(i8) };
    for (values) |v| {
        const enc = zigZagEncode(v);
        const dec = zigZagDecode(i8, enc);
        try testing.expectEqual(v, dec);
    }
}

test "SE-T3: zigzag i16 boundary values roundtrip" {
    // Goal: verify zigzag encoding is correct for 16-bit signed boundaries.
    // Method: test min, -1, 0, 1, max for i16.
    const values = [_]i16{ std.math.minInt(i16), -1, 0, 1, std.math.maxInt(i16) };
    for (values) |v| {
        const enc = zigZagEncode(v);
        const dec = zigZagDecode(i16, enc);
        try testing.expectEqual(v, dec);
    }
}

test "SE-T3: zigzag i32 boundary values roundtrip" {
    // Goal: verify zigzag encoding is correct for 32-bit signed boundaries.
    // Method: test min, -1, 0, 1, max for i32.
    const values = [_]i32{ std.math.minInt(i32), -1, 0, 1, std.math.maxInt(i32) };
    for (values) |v| {
        const enc = zigZagEncode(v);
        const dec = zigZagDecode(i32, enc);
        try testing.expectEqual(v, dec);
    }
}
