//! Canonical LEB128 (varint) encoding and decoding over byte slices and cursors.
//!
//! Key types: `ByteReader`, `ByteWriter`, `DecodedUleb128`, `DecodedSleb128`.
//! Usage pattern: use `encodeUleb128`/`encodeSleb128` for direct slice output;
//! use `readUleb128`/`writeUleb128` for cursor-based atomic encode and decode.
//! Thread safety: not thread-safe — cursors are single-owner values.

const std = @import("std");
const cursor = @import("cursor.zig");

pub const ByteReader = cursor.ByteReader;
pub const ByteWriter = cursor.ByteWriter;

/// Maximum number of bytes required to encode a 64-bit LEB128 value.
const max_leb128_bytes_u8: u8 = 10;
const max_leb128_bytes: usize = @as(usize, max_leb128_bytes_u8);

/// Errors returned by the decode and read helpers.
pub const VarintReadError = cursor.ReaderError || error{
    /// The input bytes are not a canonical LEB128 encoding.
    InvalidEncoding,
};

/// Errors returned by the encode and write helpers.
pub const VarintWriteError = cursor.WriterError;

/// Result returned by `decodeUleb128`.
pub const DecodedUleb128 = struct {
    value: u64,
    bytes_read: u8,
};

/// Result returned by `decodeSleb128`.
pub const DecodedSleb128 = struct {
    value: i64,
    bytes_read: u8,
};

fn encodedUleb128LenRuntime(value: u64) u8 {
    var remaining = value;
    var byte_count: u8 = 1;
    while (byte_count < max_leb128_bytes_u8 and remaining >= 0x80) : (byte_count += 1) {
        remaining >>= 7;
    }

    std.debug.assert(byte_count >= 1);
    std.debug.assert(byte_count <= max_leb128_bytes_u8);
    std.debug.assert(remaining < 0x80);
    return byte_count;
}

fn encodedSleb128LenRuntime(value: i64) u8 {
    var remaining = value;
    var byte_count: u8 = 0;
    while (byte_count < max_leb128_bytes_u8) : (byte_count += 1) {
        const low: u8 = @truncate(@as(u64, @bitCast(remaining)));
        const payload = low & 0x7F;
        remaining >>= 7;

        const sign_bit_set = (payload & 0x40) != 0;
        const is_last = (remaining == 0 and !sign_bit_set) or (remaining == -1 and sign_bit_set);
        if (is_last) {
            const result = byte_count + 1;
            std.debug.assert(result >= 1);
            std.debug.assert(result <= max_leb128_bytes_u8);
            return result;
        }
    }

    unreachable; // An `i64` always encodes within `max_leb128_bytes_u8` bytes.
}

/// Returns the canonical LEB128 length for `value` at compile time.
pub fn encodedUleb128Len(comptime value: u64) u8 {
    var remaining = value;
    var byte_count: u8 = 1;
    while (byte_count < max_leb128_bytes_u8 and remaining >= 0x80) : (byte_count += 1) {
        remaining >>= 7;
    }
    comptime std.debug.assert(byte_count >= 1);
    comptime std.debug.assert(byte_count <= max_leb128_bytes_u8);
    return byte_count;
}

/// Returns the canonical signed LEB128 length for `value` at compile time.
pub fn encodedSleb128Len(comptime value: i64) u8 {
    var remaining = value;
    var byte_count: u8 = 0;
    while (byte_count < max_leb128_bytes_u8) : (byte_count += 1) {
        const low: u8 = @truncate(@as(u64, @bitCast(remaining)));
        const payload = low & 0x7F;
        remaining >>= 7;

        const sign_bit_set = (payload & 0x40) != 0;
        const is_last = (remaining == 0 and !sign_bit_set) or (remaining == -1 and sign_bit_set);
        if (is_last) return byte_count + 1;
    }

    @compileError("encodedSleb128Len exceeded max_leb128_bytes");
}

/// Encodes `value` into a canonical unsigned LEB128 byte array at compile time.
pub fn encodeUleb128Ct(comptime value: u64) [encodedUleb128Len(value)]u8 {
    var remaining = value;
    var encoded: [encodedUleb128Len(value)]u8 = undefined;
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        const payload: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;
        if (remaining == 0) {
            encoded[index] = payload;
            return encoded;
        }

        encoded[index] = payload | 0x80;
    }

    @compileError("encodeUleb128Ct exceeded encodedUleb128Len");
}

/// Encodes `value` into a canonical signed LEB128 byte array at compile time.
pub fn encodeSleb128Ct(comptime value: i64) [encodedSleb128Len(value)]u8 {
    var remaining = value;
    var encoded: [encodedSleb128Len(value)]u8 = undefined;
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        const low: u8 = @truncate(@as(u64, @bitCast(remaining)));
        const payload = low & 0x7F;
        remaining >>= 7;

        const sign_bit_set = (payload & 0x40) != 0;
        const is_last = (remaining == 0 and !sign_bit_set) or (remaining == -1 and sign_bit_set);
        encoded[index] = if (is_last) payload else (payload | 0x80);
        if (is_last) return encoded;
    }

    @compileError("encodeSleb128Ct exceeded encodedSleb128Len");
}

/// Decodes one canonical unsigned LEB128 value at compile time.
///
/// The full `bytes` slice must be consumed by the encoded value.
pub fn decodeUleb128Ct(comptime bytes: []const u8) u64 {
    const decoded = decodeUleb128(bytes) catch |err| {
        const message = std.fmt.comptimePrint(
            "decodeUleb128Ct invalid input: {s}",
            .{@errorName(err)},
        );
        @compileError(message);
    };

    if (decoded.bytes_read != bytes.len) {
        const message = std.fmt.comptimePrint(
            "decodeUleb128Ct requires full-slice consumption: read {d} of {d} bytes",
            .{ decoded.bytes_read, bytes.len },
        );
        @compileError(message);
    }

    return decoded.value;
}

/// Decodes one canonical signed LEB128 value at compile time.
///
/// The full `bytes` slice must be consumed by the encoded value.
pub fn decodeSleb128Ct(comptime bytes: []const u8) i64 {
    const decoded = decodeSleb128(bytes) catch |err| {
        const message = std.fmt.comptimePrint(
            "decodeSleb128Ct invalid input: {s}",
            .{@errorName(err)},
        );
        @compileError(message);
    };

    if (decoded.bytes_read != bytes.len) {
        const message = std.fmt.comptimePrint(
            "decodeSleb128Ct requires full-slice consumption: read {d} of {d} bytes",
            .{ decoded.bytes_read, bytes.len },
        );
        @compileError(message);
    }

    return decoded.value;
}

/// Encodes `value` using canonical unsigned LEB128.
///
/// The output slice is updated atomically: on `error.NoSpaceLeft`, `out` is left unchanged.
pub fn encodeUleb128(out: []u8, value: u64) VarintWriteError!usize {
    const encoded_len = encodedUleb128LenRuntime(value);
    if (out.len < encoded_len) return error.NoSpaceLeft;

    var remaining = value;
    var index: usize = 0;
    while (index < max_leb128_bytes) : (index += 1) {
        const payload: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;
        if (remaining == 0) {
            out[index] = payload;
            return index + 1;
        }

        out[index] = payload | 0x80;
    }

    unreachable; // A `u64` always encodes within `max_leb128_bytes` bytes.
}

/// Encodes `value` using canonical signed LEB128.
///
/// The output slice is updated atomically: on `error.NoSpaceLeft`, `out` is left unchanged.
pub fn encodeSleb128(out: []u8, value: i64) VarintWriteError!usize {
    const encoded_len = encodedSleb128LenRuntime(value);
    if (out.len < encoded_len) return error.NoSpaceLeft;

    var remaining = value;
    var index: usize = 0;
    while (index < max_leb128_bytes) : (index += 1) {
        const low: u8 = @truncate(@as(u64, @bitCast(remaining)));
        const payload = low & 0x7F;
        remaining >>= 7;

        const sign_bit_set = (payload & 0x40) != 0;
        const is_last = (remaining == 0 and !sign_bit_set) or (remaining == -1 and sign_bit_set);
        out[index] = if (is_last) payload else (payload | 0x80);
        if (is_last) return index + 1;
    }

    unreachable; // An `i64` always encodes within `max_leb128_bytes` bytes.
}

/// Decodes one canonical unsigned LEB128 value from the start of `bytes`.
pub fn decodeUleb128(bytes: []const u8) VarintReadError!DecodedUleb128 {
    var reader = ByteReader.init(bytes);
    const value = try readUleb128(&reader);
    const bytes_read_usize = reader.position();
    std.debug.assert(bytes_read_usize <= std.math.maxInt(u8));
    const bytes_read: u8 = @intCast(bytes_read_usize);
    return .{
        .value = value,
        .bytes_read = bytes_read,
    };
}

/// Decodes one canonical signed LEB128 value from the start of `bytes`.
pub fn decodeSleb128(bytes: []const u8) VarintReadError!DecodedSleb128 {
    var reader = ByteReader.init(bytes);
    const value = try readSleb128(&reader);
    const bytes_read_usize = reader.position();
    std.debug.assert(bytes_read_usize <= std.math.maxInt(u8));
    const bytes_read: u8 = @intCast(bytes_read_usize);
    return .{
        .value = value,
        .bytes_read = bytes_read,
    };
}

/// Reads one canonical unsigned LEB128 value and rolls back on failure.
pub fn readUleb128(reader: *ByteReader) VarintReadError!u64 {
    const checkpoint = reader.mark();
    errdefer {
        // `checkpoint` comes from `mark()`, so it always fits within the reader buffer.
        reader.rewind(checkpoint) catch unreachable;
    }

    var count: u8 = 0;
    var shift: u8 = 0;
    var value: u64 = 0;

    while (count < max_leb128_bytes_u8) : (count += 1) {
        const byte = try reader.readByte();

        const payload = byte & 0x7F;
        if (shift == 63 and payload > 1) return error.InvalidEncoding;

        std.debug.assert(shift <= 63);
        const shift_amount: u6 = @intCast(shift);
        value |= @as(u64, payload) << shift_amount;
        if ((byte & 0x80) == 0) {
            const consumed: u8 = count + 1;
            if (encodedUleb128LenRuntime(value) != consumed) return error.InvalidEncoding;
            return value;
        }

        shift += 7;
    }

    return error.InvalidEncoding;
}

/// Reads one canonical signed LEB128 value and rolls back on failure.
pub fn readSleb128(reader: *ByteReader) VarintReadError!i64 {
    const checkpoint = reader.mark();
    errdefer {
        // `checkpoint` comes from `mark()`, so it always fits within the reader buffer.
        reader.rewind(checkpoint) catch unreachable;
    }

    var count: u8 = 0;
    var shift: u8 = 0;
    var value: i128 = 0;

    while (count < max_leb128_bytes_u8) : (count += 1) {
        const byte = try reader.readByte();

        const payload: i128 = @intCast(byte & 0x7F);
        const shift_amount: u7 = @intCast(shift);
        value |= payload << shift_amount;
        shift += 7;

        if ((byte & 0x80) == 0) {
            if (shift < 128 and (byte & 0x40) != 0) {
                const extend_shift: u7 = @intCast(shift);
                value |= -(@as(i128, 1) << extend_shift);
            }

            if (value < std.math.minInt(i64)) return error.InvalidEncoding;
            if (value > std.math.maxInt(i64)) return error.InvalidEncoding;

            const decoded: i64 = @intCast(value);
            const consumed: u8 = count + 1;
            if (encodedSleb128LenRuntime(decoded) != consumed) return error.InvalidEncoding;
            return decoded;
        }
    }

    return error.InvalidEncoding;
}

/// Writes canonical unsigned LEB128 bytes into `writer`.
pub fn writeUleb128(writer: *ByteWriter, value: u64) VarintWriteError!void {
    var encoded = [_]u8{0} ** max_leb128_bytes;
    const count = try encodeUleb128(&encoded, value);
    try writer.write(encoded[0..count]);
}

/// Writes canonical signed LEB128 bytes into `writer`.
pub fn writeSleb128(writer: *ByteWriter, value: i64) VarintWriteError!void {
    var encoded = [_]u8{0} ** max_leb128_bytes;
    const count = try encodeSleb128(&encoded, value);
    try writer.write(encoded[0..count]);
}

fn nextDeterministic(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

test "uleb128 encodes and decodes known vectors" {
    var buf = [_]u8{0} ** 10;
    const zero_len = try encodeUleb128(&buf, 0);
    try std.testing.expectEqual(@as(usize, 1), zero_len);
    try std.testing.expectEqualSlices(u8, &.{0x00}, buf[0..zero_len]);

    const n_len = try encodeUleb128(&buf, 624485);
    try std.testing.expectEqualSlices(u8, &.{ 0xE5, 0x8E, 0x26 }, buf[0..n_len]);

    const decoded = try decodeUleb128(buf[0..n_len]);
    try std.testing.expectEqual(@as(u64, 624485), decoded.value);
    try std.testing.expectEqual(@as(u8, 3), decoded.bytes_read);
}

test "sleb128 encodes and decodes known vectors" {
    var buf = [_]u8{0} ** 10;
    const n_len = try encodeSleb128(&buf, -624485);
    try std.testing.expectEqualSlices(u8, &.{ 0x9B, 0xF1, 0x59 }, buf[0..n_len]);

    const decoded = try decodeSleb128(buf[0..n_len]);
    try std.testing.expectEqual(@as(i64, -624485), decoded.value);
    try std.testing.expectEqual(@as(u8, 3), decoded.bytes_read);
}

test "varint read errors rewind reader position" {
    var truncated = [_]u8{0x80};
    var reader = ByteReader.init(&truncated);
    try std.testing.expectError(error.EndOfStream, readUleb128(&reader));
    try std.testing.expectEqual(@as(usize, 0), reader.position());

    var overlong_zero = [_]u8{ 0x80, 0x00 };
    reader = ByteReader.init(&overlong_zero);
    try std.testing.expectError(error.InvalidEncoding, readUleb128(&reader));
    try std.testing.expectEqual(@as(usize, 0), reader.position());
}

test "varint write errors preserve writer position" {
    var out = [_]u8{0};
    var writer = ByteWriter.init(&out);
    try std.testing.expectError(error.NoSpaceLeft, writeUleb128(&writer, 300));
    try std.testing.expectEqual(@as(usize, 0), writer.position());
}

test "direct varint encoders leave output unchanged on short buffers" {
    var u_buf = [_]u8{0xFF};
    try std.testing.expectError(error.NoSpaceLeft, encodeUleb128(&u_buf, 300));
    try std.testing.expectEqualSlices(u8, &.{0xFF}, &u_buf);

    var s_buf = [_]u8{0xAA};
    try std.testing.expectError(error.NoSpaceLeft, encodeSleb128(&s_buf, -300));
    try std.testing.expectEqualSlices(u8, &.{0xAA}, &s_buf);
}

test "uleb128 rejects non-canonical encodings" {
    const overlong_zero = [_]u8{ 0x80, 0x00 };
    try std.testing.expectError(error.InvalidEncoding, decodeUleb128(&overlong_zero));

    const overlong_one = [_]u8{ 0x81, 0x00 };
    try std.testing.expectError(error.InvalidEncoding, decodeUleb128(&overlong_one));

    const overlong_127 = [_]u8{ 0xFF, 0x00 };
    try std.testing.expectError(error.InvalidEncoding, decodeUleb128(&overlong_127));
}

test "sleb128 rejects non-canonical encodings" {
    const overlong_zero = [_]u8{ 0x80, 0x00 };
    try std.testing.expectError(error.InvalidEncoding, decodeSleb128(&overlong_zero));

    const overlong_neg_one = [_]u8{ 0xFF, 0x7F };
    try std.testing.expectError(error.InvalidEncoding, decodeSleb128(&overlong_neg_one));
}

test "varint encodes and decodes integer extremes" {
    var u_buf = [_]u8{0} ** max_leb128_bytes;
    const u_len = try encodeUleb128(&u_buf, std.math.maxInt(u64));
    try std.testing.expectEqual(max_leb128_bytes, u_len);
    const u_decoded = try decodeUleb128(u_buf[0..u_len]);
    try std.testing.expectEqual(std.math.maxInt(u64), u_decoded.value);
    try std.testing.expectEqual(@as(u8, max_leb128_bytes_u8), u_decoded.bytes_read);

    var s_buf = [_]u8{0} ** max_leb128_bytes;
    const s_len_min = try encodeSleb128(&s_buf, std.math.minInt(i64));
    const s_decoded_min = try decodeSleb128(s_buf[0..s_len_min]);
    try std.testing.expectEqual(std.math.minInt(i64), s_decoded_min.value);
    try std.testing.expectEqual(@as(u8, @intCast(s_len_min)), s_decoded_min.bytes_read);

    const s_len_max = try encodeSleb128(&s_buf, std.math.maxInt(i64));
    const s_decoded_max = try decodeSleb128(s_buf[0..s_len_max]);
    try std.testing.expectEqual(std.math.maxInt(i64), s_decoded_max.value);
    try std.testing.expectEqual(@as(u8, @intCast(s_len_max)), s_decoded_max.bytes_read);
}

test "comptime varint helpers produce canonical vectors" {
    const encoded_u = comptime encodeUleb128Ct(624485);
    try std.testing.expectEqualSlices(u8, &.{ 0xE5, 0x8E, 0x26 }, &encoded_u);
    try std.testing.expectEqual(@as(u64, 624485), comptime decodeUleb128Ct(&encoded_u));

    const encoded_s = comptime encodeSleb128Ct(-624485);
    try std.testing.expectEqualSlices(u8, &.{ 0x9B, 0xF1, 0x59 }, &encoded_s);
    try std.testing.expectEqual(@as(i64, -624485), comptime decodeSleb128Ct(&encoded_s));

    try std.testing.expectEqual(@as(u8, 3), comptime encodedUleb128Len(624485));
    try std.testing.expectEqual(@as(u8, 3), comptime encodedSleb128Len(-624485));
}

test "deterministic varint roundtrip coverage" {
    var state: u64 = 0xC6A4A7935BD1E995;
    var iter: u16 = 0;
    while (iter < 256) : (iter += 1) {
        const random_value = nextDeterministic(&state);
        const unsigned_value: u64 = random_value ^ (random_value >> 13);
        const signed_value: i64 = @bitCast(random_value ^ (random_value >> 7));

        var u_buf = [_]u8{0} ** max_leb128_bytes;
        const u_len = try encodeUleb128(&u_buf, unsigned_value);
        const u_decoded = try decodeUleb128(u_buf[0..u_len]);
        try std.testing.expectEqual(unsigned_value, u_decoded.value);

        var s_buf = [_]u8{0} ** max_leb128_bytes;
        const s_len = try encodeSleb128(&s_buf, signed_value);
        const s_decoded = try decodeSleb128(s_buf[0..s_len]);
        try std.testing.expectEqual(signed_value, s_decoded.value);
    }
}
