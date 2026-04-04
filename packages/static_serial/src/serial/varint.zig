//! Variable-length integer encoding for the serial wire format.
//!
//! Key types: `Error`.
//! Usage pattern: call `writeVarint(writer, value)` to encode; call
//! `readVarint(reader, T)` to decode; both roll back the cursor on failure.
//! Thread safety: not thread-safe — cursors are single-owner values.
//!
//! Boundary note:
//! - `static_bits.varint` owns raw canonical LEB128 helpers.
//! - This module owns the serial-layer error contract and rollback behavior used by
//!   structured wire-format readers and writers.

const std = @import("std");
const bits = @import("static_bits");

pub const Error = error{
    EndOfStream,
    NoSpaceLeft,
    InvalidInput,
    Overflow,
    Underflow,
};

pub fn varintLen(value: anytype) usize {
    // SE-R1: toUnsigned handles any integer type (unlike zigzag.signedToUnsigned
    // which requires a signed type). The semantics differ: toUnsigned is a
    // bit-width-preserving cast to unsigned; signedToUnsigned asserts signedness.
    const U = toUnsigned(@TypeOf(value));
    comptime {
        // varintLen requires an unsigned integer so that @intCast never panics.
        // Signed types must be handled by the caller (e.g. via zigzag encoding).
        if (@typeInfo(@TypeOf(value)).int.signedness == .signed) {
            @compileError("varintLen requires an unsigned integer type");
        }
        // Comptime: max_bytes for any U is between 1 and 10 (u64 = 10 bytes max).
        const max_bytes_check = (@typeInfo(U).int.bits + 6) / 7;
        std.debug.assert(max_bytes_check >= 1 and max_bytes_check <= 10);
    }
    var x: U = @intCast(value);
    const max_bytes = (@typeInfo(U).int.bits + 6) / 7;
    var len: usize = 1;
    while (len < max_bytes and x >= 0x80) : (len += 1) {
        x >>= 7;
    }
    // Postcondition: encoded length is at least 1 and at most max_bytes (<= 10).
    std.debug.assert(len >= 1);
    std.debug.assert(len <= max_bytes);
    return len;
}

pub fn writeVarint(writer: *bits.cursor.ByteWriter, value: anytype) Error!void {
    const U = toUnsigned(@TypeOf(value));
    comptime {
        const max_bytes_check = (@typeInfo(U).int.bits + 6) / 7;
        std.debug.assert(max_bytes_check >= 1);
        std.debug.assert(max_bytes_check <= 10);
    }
    const value_u: U = bits.cast.castInt(U, value) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.Underflow => return error.Underflow,
    };
    const value_u64: u64 = bits.cast.castInt(u64, value_u) catch return error.Overflow;
    bits.varint.writeUleb128(writer, value_u64) catch |err| return switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.Overflow => error.Overflow,
    };
}

pub fn readVarint(reader: *bits.cursor.ByteReader, comptime T: type) Error!T {
    const info = @typeInfo(T);
    if (info != .int) {
        @compileError("readVarint expects an integer destination type");
    }
    // Precondition: max_bytes for T must be in range [1, 10].
    comptime {
        const max_bytes_check = (info.int.bits + 6) / 7;
        std.debug.assert(max_bytes_check >= 1 and max_bytes_check <= 10);
    }

    const decoded = bits.varint.readUleb128(reader) catch |err| return switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.InvalidEncoding => error.InvalidInput,
        error.Overflow => error.Overflow,
    };
    return bits.cast.castInt(T, decoded) catch |err| switch (err) {
        error.Overflow => error.Overflow,
        error.Underflow => error.Underflow,
    };
}

/// SE-R1: Renamed from `unsignedOf` to `toUnsigned`.
/// Converts any integer type (signed or unsigned) to its unsigned equivalent
/// with the same bit width. Used internally by varint encode/decode.
/// Contrast with zigzag.signedToUnsigned, which requires a signed input.
fn toUnsigned(comptime IntType: type) type {
    const info = @typeInfo(IntType);
    if (info != .int) @compileError("toUnsigned expects an integer type");
    return std.meta.Int(.unsigned, info.int.bits);
}

test "varint encode/decode canonical and atomic on failure" {
    var buf = [_]u8{0} ** 8;
    var writer = bits.cursor.ByteWriter.init(&buf);
    try writeVarint(&writer, @as(u32, 300));

    const written_len = writer.position();
    std.debug.assert(written_len > 0);
    var reader = bits.cursor.ByteReader.init(buf[0..written_len]);
    try std.testing.expectEqual(@as(u32, 300), try readVarint(&reader, u32));
    try std.testing.expectError(error.EndOfStream, readVarint(&reader, u32));
}

test "varint rejects non-canonical encoding (extra leading zero byte)" {
    // Value 1 encoded canonically is 0x01 (one byte).
    // Non-canonical: 0x81, 0x00 — two bytes encoding 1 with a trailing zero.
    const non_canonical = [_]u8{ 0x81, 0x00 };
    var reader = bits.cursor.ByteReader.init(&non_canonical);
    try std.testing.expectError(error.InvalidInput, readVarint(&reader, u32));
    // Cursor must be rolled back to start.
    try std.testing.expectEqual(@as(usize, 0), reader.position());
}

test "varint roundtrip boundary values" {
    var buf = [_]u8{0} ** 10;

    // u8 boundaries.
    for ([_]u32{ 0, 1, 127, 128, 255 }) |v| {
        var w = bits.cursor.ByteWriter.init(&buf);
        try writeVarint(&w, @as(u32, v));
        std.debug.assert(w.position() > 0);
        var r = bits.cursor.ByteReader.init(buf[0..w.position()]);
        try std.testing.expectEqual(v, try readVarint(&r, u32));
    }
}

test "varint write to short buffer rolls back position" {
    var buf = [_]u8{0} ** 1;
    var writer = bits.cursor.ByteWriter.init(&buf);
    // Value 300 requires 2 bytes; buffer only has 1.
    try std.testing.expectError(error.NoSpaceLeft, writeVarint(&writer, @as(u32, 300)));
    try std.testing.expectEqual(@as(usize, 0), writer.position());
}

test "SE-T2: varint u64 max roundtrip encodes to exactly 10 bytes" {
    // Goal: verify u64 max value encodes at maximum varint length (10 bytes).
    // Method: encode maxInt(u64), assert length == 10, then decode and compare.
    const max_u64: u64 = std.math.maxInt(u64);
    const encoded_len = varintLen(max_u64);
    try std.testing.expectEqual(@as(usize, 10), encoded_len);

    var buf = [_]u8{0} ** 10;
    var writer = bits.cursor.ByteWriter.init(&buf);
    try writeVarint(&writer, max_u64);
    try std.testing.expectEqual(@as(usize, 10), writer.position());

    var reader = bits.cursor.ByteReader.init(&buf);
    const decoded = try readVarint(&reader, u64);
    try std.testing.expectEqual(max_u64, decoded);
    std.debug.assert(reader.position() == 10);
}

test "SE-T4: readVarint returns EndOfStream on truncated data" {
    // Goal: verify that a partially encoded varint triggers EndOfStream and rolls back.
    // Method: write a multi-byte varint then truncate the reader buffer.
    var buf = [_]u8{ 0xAC, 0x02 }; // value 300: two-byte encoding.
    // Expose only the first byte to simulate truncation.
    var reader = bits.cursor.ByteReader.init(buf[0..1]);
    try std.testing.expectError(error.EndOfStream, readVarint(&reader, u32));
    // Rollback: position must be at 0.
    try std.testing.expectEqual(@as(usize, 0), reader.position());
}

test "SE-T4: writeVarint on full buffer returns NoSpaceLeft atomically" {
    // Goal: verify that a failed write is atomic.
    // Method: nearly fill the buffer, attempt a varint that overflows, check that the trailing byte is unchanged.
    var buf = [_]u8{0xFF} ** 4; // Pre-fill with 0xFF to detect non-zeroed bytes.
    var writer = bits.cursor.ByteWriter.init(&buf);
    // Write 3 bytes to fill most of the buffer.
    try writer.write(&.{ 0x01, 0x02, 0x03 });
    // Value 300 requires 2 bytes; only 1 remains.
    try std.testing.expectError(error.NoSpaceLeft, writeVarint(&writer, @as(u32, 300)));
    // Position rolled back: still at 3 (pre-write position).
    try std.testing.expectEqual(@as(usize, 3), writer.position());
    // Atomicity check: the untouched trailing byte remains unchanged.
    try std.testing.expectEqual(@as(u8, 0xFF), buf[3]);
}
