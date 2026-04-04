//! Bitfield utilities for extracting and inserting packed bit ranges.
//!
//! Key types: `BitfieldError`, `Pack2`.
//! Bit numbering uses the least-significant bit as bit 0.
//! All ranges are half-open: `[start_bit, start_bit + bit_count)`.
//! Usage pattern: prefer `extractBitsCt`/`insertBitsCt` when widths are known at
//! compile time for range validation at compile time; use the runtime variants when
//! widths are determined at runtime.
//! Thread safety: thread-safe. All functions are pure and stateless.

const std = @import("std");

/// Errors returned by bitfield operations.
pub const BitfieldError = error{
    /// The requested bit range does not fit in the width of the destination type.
    InvalidRange,
    /// The provided field value contains set bits outside the destination range.
    Overflow,
};

fn assertIntType(comptime T: type, comptime fn_name: []const u8) void {
    if (@typeInfo(T) != .int) {
        @compileError(fn_name ++ " expects an integer type");
    }
    if (@typeInfo(T).int.bits == 0) {
        @compileError(fn_name ++ " requires a non-zero-width integer");
    }
}

fn assertUnsignedIntType(comptime T: type, comptime fn_name: []const u8) void {
    if (@typeInfo(T) != .int) {
        @compileError(fn_name ++ " expects an integer type");
    }
    if (@typeInfo(T).int.bits == 0) {
        @compileError(fn_name ++ " requires a non-zero-width integer");
    }
    if (@typeInfo(T).int.signedness != .unsigned) {
        @compileError(fn_name ++ " expects an unsigned integer type");
    }
}

fn IntUnsigned(comptime T: type) type {
    comptime assertIntType(T, "IntUnsigned");
    const info = @typeInfo(T).int;
    return std.meta.Int(.unsigned, info.bits);
}

fn toUnsigned(comptime T: type, value: T) IntUnsigned(T) {
    comptime assertIntType(T, "toUnsigned");
    const info = @typeInfo(T).int;
    // Reinterpret signed integers without changing the underlying bits.
    if (info.signedness == .signed) return @bitCast(value);
    return value;
}

fn fromUnsigned(comptime T: type, value: IntUnsigned(T)) T {
    comptime assertIntType(T, "fromUnsigned");
    const info = @typeInfo(T).int;
    // Restore the original signed representation without changing the underlying bits.
    if (info.signedness == .signed) return @bitCast(value);
    return value;
}

fn validateRange(comptime T: type, start_bit: u8, bit_count: u8) BitfieldError!void {
    comptime assertIntType(T, "validateRange");
    const bit_width: u16 = @intCast(@bitSizeOf(T));
    const start_u16: u16 = @as(u16, start_bit);
    const count_u16: u16 = @as(u16, bit_count);
    const end_u16: u16 = start_u16 + count_u16;
    std.debug.assert(end_u16 >= start_u16);
    if (end_u16 > bit_width) return error.InvalidRange;
}

fn validateRangeComptime(
    comptime T: type,
    comptime start_bit: u8,
    comptime bit_count: u8,
    comptime fn_name: []const u8,
) void {
    comptime assertIntType(T, fn_name);
    const bit_width: u16 = @intCast(@bitSizeOf(T));
    const start_u16: u16 = @as(u16, start_bit);
    const count_u16: u16 = @as(u16, bit_count);
    const end_u16: u16 = start_u16 + count_u16;

    if (end_u16 > bit_width) {
        const message = std.fmt.comptimePrint(
            "{s} range [{d}, {d}) exceeds {d}-bit `{s}`",
            .{ fn_name, start_bit, end_u16, bit_width, @typeName(T) },
        );
        @compileError(message);
    }
}

fn rangeMask(comptime U: type, bit_count: u8) U {
    comptime assertUnsignedIntType(U, "rangeMask");
    if (bit_count == 0) return 0;
    if (bit_count >= @bitSizeOf(U)) return std.math.maxInt(U);

    const shift: std.math.Log2Int(U) = @intCast(bit_count);
    return (@as(U, 1) << shift) - 1;
}

/// Extracts `bit_count` bits from `value`, starting at `start_bit`.
///
/// Bit 0 is the least-significant bit.
pub fn extractBits(
    comptime T: type,
    value: T,
    start_bit: u8,
    bit_count: u8,
) BitfieldError!T {
    comptime assertIntType(T, "extractBits");
    try validateRange(T, start_bit, bit_count);
    // Empty ranges are valid and avoid casting `start_bit == bit_width` into the shift type.
    if (bit_count == 0) return 0;

    const U = IntUnsigned(T);
    const shift: std.math.Log2Int(U) = @intCast(start_bit);
    const mask = rangeMask(U, bit_count);
    const field = (toUnsigned(T, value) >> shift) & mask;

    const int_info = @typeInfo(T).int;
    if (int_info.signedness == .signed and bit_count == int_info.bits) {
        return fromUnsigned(T, field);
    }

    return @intCast(field);
}

/// Extracts `bit_count` bits from `value`, starting at `start_bit`.
///
/// This variant enforces range validity at compile time.
pub fn extractBitsCt(
    comptime T: type,
    value: T,
    comptime start_bit: u8,
    comptime bit_count: u8,
) T {
    comptime validateRangeComptime(T, start_bit, bit_count, "extractBitsCt");
    // Empty ranges are valid and avoid casting `start_bit == bit_width` into the shift type.
    if (bit_count == 0) return 0;

    const U = IntUnsigned(T);
    const shift: std.math.Log2Int(U) = @intCast(start_bit);
    const mask = rangeMask(U, bit_count);
    const field = (toUnsigned(T, value) >> shift) & mask;

    const int_info = @typeInfo(T).int;
    if (int_info.signedness == .signed and bit_count == int_info.bits) {
        return fromUnsigned(T, field);
    }

    return @intCast(field);
}

/// Inserts `field_value` into `base` at `[start_bit, start_bit + bit_count)`.
///
/// Bit 0 is the least-significant bit.
pub fn insertBits(
    comptime T: type,
    base: T,
    field_value: T,
    start_bit: u8,
    bit_count: u8,
) BitfieldError!T {
    comptime assertIntType(T, "insertBits");
    try validateRange(T, start_bit, bit_count);
    // Empty ranges do not modify `base`, but non-zero field input still overflows the range.
    if (bit_count == 0) {
        if (field_value != 0) return error.Overflow;
        return base;
    }

    const U = IntUnsigned(T);
    const shift: std.math.Log2Int(U) = @intCast(start_bit);
    const mask = rangeMask(U, bit_count);
    const field_u = toUnsigned(T, field_value);

    if ((field_u & ~mask) != 0) return error.Overflow;

    const base_u = toUnsigned(T, base);
    const shifted_mask = mask << shift;
    const merged = (base_u & ~shifted_mask) | ((field_u & mask) << shift);
    return fromUnsigned(T, merged);
}

/// Inserts `field_value` into `base` at `[start_bit, start_bit + bit_count)`.
///
/// This variant enforces range validity at compile time while preserving runtime
/// overflow checks for `field_value`.
pub fn insertBitsCt(
    comptime T: type,
    base: T,
    field_value: T,
    comptime start_bit: u8,
    comptime bit_count: u8,
) BitfieldError!T {
    comptime validateRangeComptime(T, start_bit, bit_count, "insertBitsCt");
    // Empty ranges do not modify `base`, but non-zero field input still overflows the range.
    if (bit_count == 0) {
        if (field_value != 0) return error.Overflow;
        return base;
    }

    const U = IntUnsigned(T);
    const shift: std.math.Log2Int(U) = @intCast(start_bit);
    const mask = rangeMask(U, bit_count);
    const field_u = toUnsigned(T, field_value);

    if ((field_u & ~mask) != 0) return error.Overflow;

    const base_u = toUnsigned(T, base);
    const shifted_mask = mask << shift;
    const merged = (base_u & ~shifted_mask) | ((field_u & mask) << shift);
    return fromUnsigned(T, merged);
}

pub fn Pack2(comptime T: type) type {
    return struct {
        low: T,
        high: T,
    };
}

/// Packs two fields into a single `T` value.
///
/// `low_value` occupies `[0, low_bits)`, and `high_value` occupies `[low_bits, low_bits + high_bits)`.
pub fn pack2(
    comptime T: type,
    low_value: T,
    low_bits: u8,
    high_value: T,
    high_bits: u8,
) BitfieldError!T {
    comptime assertIntType(T, "pack2");
    var value = try insertBits(T, 0, low_value, 0, low_bits);
    value = try insertBits(T, value, high_value, low_bits, high_bits);
    return value;
}

/// Packs two fields into a single `T` value.
///
/// This variant enforces field-width contracts at compile time.
pub fn pack2Ct(
    comptime T: type,
    low_value: T,
    comptime low_bits: u8,
    high_value: T,
    comptime high_bits: u8,
) BitfieldError!T {
    var value = try insertBitsCt(T, 0, low_value, 0, low_bits);
    value = try insertBitsCt(T, value, high_value, low_bits, high_bits);
    return value;
}

/// Unpacks two fields from a single `T` value.
///
/// `low` is read from `[0, low_bits)`, and `high` is read from `[low_bits, low_bits + high_bits)`.
pub fn unpack2(
    comptime T: type,
    packed_value: T,
    low_bits: u8,
    high_bits: u8,
) BitfieldError!Pack2(T) {
    comptime assertIntType(T, "unpack2");
    return .{
        .low = try extractBits(T, packed_value, 0, low_bits),
        .high = try extractBits(T, packed_value, low_bits, high_bits),
    };
}

/// Unpacks two fields from a single `T` value.
///
/// This variant enforces field-width contracts at compile time.
pub fn unpack2Ct(
    comptime T: type,
    packed_value: T,
    comptime low_bits: u8,
    comptime high_bits: u8,
) Pack2(T) {
    return .{
        .low = extractBitsCt(T, packed_value, 0, low_bits),
        .high = extractBitsCt(T, packed_value, low_bits, high_bits),
    };
}

fn nextDeterministic(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

test "extract and insert bits preserve outside ranges" {
    const base: u16 = 0b1010_0000_1111_0000;
    const inserted = try insertBits(u16, base, 0b0101, 8, 4);
    try std.testing.expectEqual(@as(u16, 0b1010_0101_1111_0000), inserted);
    try std.testing.expectEqual(@as(u16, 0b0101), try extractBits(u16, inserted, 8, 4));
}

test "bitfield reports invalid ranges and overflow" {
    try std.testing.expectError(error.InvalidRange, extractBits(u8, 0xFF, 7, 2));
    try std.testing.expectError(error.InvalidRange, insertBits(u8, 0, 1, 4, 5));
    try std.testing.expectError(error.Overflow, insertBits(u8, 0, 0b1_0000, 0, 4));
}

test "pack2 and unpack2 use compile-time width contracts" {
    const packed_value = try pack2(u16, 0b1010, 4, 0x12, 8);
    const unpacked = try unpack2(u16, packed_value, 4, 8);
    try std.testing.expectEqual(@as(u16, 0b1010), unpacked.low);
    try std.testing.expectEqual(@as(u16, 0x12), unpacked.high);
}

test "pack2 and unpack2 report overlapping fields as invalid range" {
    try std.testing.expectError(error.InvalidRange, pack2(u8, 0, 5, 0, 5));
    try std.testing.expectError(error.InvalidRange, unpack2(u8, 0, 5, 5));
    try std.testing.expectError(error.InvalidRange, pack2(u16, 0, 12, 0, 8));
    try std.testing.expectError(error.InvalidRange, unpack2(u16, 0, 12, 8));
}

test "comptime bitfield wrappers match runtime wrappers" {
    const base: u16 = 0b1010_0000_1111_0000;
    const runtime_inserted = try insertBits(u16, base, 0b0101, 8, 4);
    const comptime_inserted = try insertBitsCt(u16, base, 0b0101, 8, 4);
    try std.testing.expectEqual(runtime_inserted, comptime_inserted);

    const runtime_extracted = try extractBits(u16, runtime_inserted, 8, 4);
    const comptime_extracted = extractBitsCt(u16, runtime_inserted, 8, 4);
    try std.testing.expectEqual(runtime_extracted, comptime_extracted);

    const packed_runtime = try pack2(u16, 0b1010, 4, 0x12, 8);
    const packed_comptime = try pack2Ct(u16, 0b1010, 4, 0x12, 8);
    try std.testing.expectEqual(packed_runtime, packed_comptime);

    const unpacked_runtime = try unpack2(u16, packed_runtime, 4, 8);
    const unpacked_comptime = unpack2Ct(u16, packed_runtime, 4, 8);
    try std.testing.expectEqual(unpacked_runtime.low, unpacked_comptime.low);
    try std.testing.expectEqual(unpacked_runtime.high, unpacked_comptime.high);
}

test "comptime insert wrappers preserve runtime overflow checks" {
    try std.testing.expectError(error.Overflow, insertBitsCt(u8, 0, 0b1_0000, 0, 4));
}

test "deterministic bitfield roundtrip properties" {
    var state: u64 = 0xA24BAED4963EE407;
    var iter: u16 = 0;
    while (iter < 512) : (iter += 1) {
        const random = nextDeterministic(&state);
        const width: u8 = @intCast((random & 31) + 1);
        const start_limit: u8 = @intCast(32 - width);
        const start: u8 = @intCast((random >> 8) % (@as(u64, start_limit) + 1));
        const base: u32 = @truncate(random >> 16);

        const field_mask: u32 = if (width == 32)
            std.math.maxInt(u32)
        else
            (@as(u32, 1) << @as(u5, @intCast(width))) - 1;
        const field_value: u32 = @intCast((random >> 1) & field_mask);

        const inserted = try insertBits(u32, base, field_value, start, width);
        const extracted = try extractBits(u32, inserted, start, width);
        try std.testing.expectEqual(field_value, extracted);

        const shifted_mask: u32 = if (width == 32)
            std.math.maxInt(u32)
        else
            field_mask << @as(u5, @intCast(start));
        try std.testing.expectEqual(base & ~shifted_mask, inserted & ~shifted_mask);
    }
}

test "zero-width ranges are valid at the type boundary" {
    const bit_width: u8 = @intCast(@bitSizeOf(u8));
    try std.testing.expectEqual(@as(u8, 0), try extractBits(u8, 0xAA, bit_width, 0));
    try std.testing.expectEqual(@as(u8, 0xAA), try insertBits(u8, 0xAA, 0, bit_width, 0));
    try std.testing.expectError(error.Overflow, insertBits(u8, 0xAA, 1, bit_width, 0));
}

test "signed full-width operations preserve two's-complement payloads" {
    const value: i8 = -2;
    try std.testing.expectEqual(value, try extractBits(i8, value, 0, 8));
    try std.testing.expectEqual(value, extractBitsCt(i8, value, 0, 8));

    const inserted = try insertBits(i8, 0, value, 0, 8);
    try std.testing.expectEqual(value, inserted);
    const inserted_ct = try insertBitsCt(i8, 0, value, 0, 8);
    try std.testing.expectEqual(inserted, inserted_ct);
}

test "signed partial-width inserts reject negative values" {
    try std.testing.expectError(error.Overflow, insertBits(i8, 0, -1, 0, 4));
    try std.testing.expectError(error.Overflow, insertBitsCt(i8, 0, -1, 0, 4));
}
