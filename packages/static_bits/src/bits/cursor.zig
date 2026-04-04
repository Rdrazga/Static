//! Cursor utilities over byte and bit slices.
//!
//! Key types: `ByteReader`, `ByteWriter`, `BitReader`, `BitWriter`, `Checkpoint`, `BitCheckpoint`.
//! Usage pattern: construct a cursor with `init(buf)`, then call read/write helpers;
//! capture a `Checkpoint` with `mark()` and restore with `rewind()` for atomic operations.
//! Thread safety: not thread-safe — each cursor instance must be used from one thread.

const std = @import("std");
const core = @import("static_core");
const endian = @import("endian.zig");

/// Byte order used by the byte cursor helpers.
pub const Endian = endian.Endian;

/// Errors returned by `ByteReader` operations.
pub const ReaderError = error{
    /// The requested read extends past the end of the buffer.
    EndOfStream,
    /// The requested operation overflowed an internal `usize` calculation.
    Overflow,
};

/// Errors returned by `ByteWriter` operations.
pub const WriterError = error{
    /// The requested write extends past the end of the buffer.
    NoSpaceLeft,
    /// The requested operation overflowed an internal `usize` calculation.
    Overflow,
};

/// Combined error set for APIs that can read or write.
pub const CursorError = error{
    /// The requested read extends past the end of the buffer.
    EndOfStream,
    /// The requested write extends past the end of the buffer.
    NoSpaceLeft,
    /// The requested operation overflowed an internal `usize` calculation.
    Overflow,
};

comptime {
    core.errors.assertVocabularySubset(ReaderError);
    core.errors.assertVocabularySubset(WriterError);
    core.errors.assertVocabularySubset(CursorError);
}

/// Byte offset checkpoint produced by `ByteReader.mark` and `ByteWriter.mark`.
pub const Checkpoint = struct {
    position: usize,
};

/// Bit offset checkpoint produced by `BitReader.mark` and `BitWriter.mark`.
pub const BitCheckpoint = struct {
    position_bits: usize,
};

fn assertNonZeroIntType(comptime T: type, comptime fn_name: []const u8) void {
    if (@typeInfo(T) != .int) {
        @compileError(fn_name ++ " expects an integer type");
    }
    if (@typeInfo(T).int.bits == 0) {
        @compileError(fn_name ++ " requires a non-zero-width integer");
    }
}

fn assertBitIntType(comptime T: type, comptime fn_name: []const u8) void {
    if (@typeInfo(T) != .int) {
        @compileError(fn_name ++ " expects an integer type");
    }

    const bits = @typeInfo(T).int.bits;
    if (bits == 0) {
        @compileError(fn_name ++ " requires a non-zero-width integer");
    }

    if (bits > 128) {
        @compileError(fn_name ++ " supports integers up to 128 bits");
    }
}

fn assertBitCountFitsType(comptime T: type, comptime bit_count: u8, comptime fn_name: []const u8) void {
    comptime assertBitIntType(T, fn_name);
    const type_width: u16 = @intCast(@typeInfo(T).int.bits);
    const bit_count_u16: u16 = @as(u16, bit_count);
    if (bit_count_u16 > type_width) {
        const message = std.fmt.comptimePrint(
            "{s} bit_count {d} exceeds `{s}` width {d}",
            .{ fn_name, bit_count, @typeName(T), type_width },
        );
        @compileError(message);
    }
}

fn maskU128(bit_count: u8) u128 {
    if (bit_count == 0) return 0;
    if (bit_count >= 128) return std.math.maxInt(u128);

    const shift: u7 = @intCast(bit_count);
    return (@as(u128, 1) << shift) - 1;
}

// Converts raw bit payloads into `T`.
// Signed negatives are only accepted for full-width reads so truncating reads cannot silently reinterpret sign bits.
fn valueFromRawBits(comptime T: type, raw: u128, bit_count: u8) T {
    comptime assertBitIntType(T, "readBits");
    const info = @typeInfo(T).int;
    const bits_u8: u8 = @intCast(info.bits);
    std.debug.assert(bit_count <= bits_u8);

    const truncated_raw = raw & maskU128(bit_count);
    if (info.signedness == .unsigned) {
        return @intCast(truncated_raw);
    }

    // Full-width signed reads preserve two's-complement bit patterns exactly.
    if (bit_count == bits_u8) {
        const U = std.meta.Int(.unsigned, info.bits);
        const raw_bits: U = @truncate(truncated_raw);
        return @bitCast(raw_bits);
    }

    return @intCast(truncated_raw);
}

// Produces the raw payload for a write.
// Negative signed values require full-width writes so truncating writes cannot drop the sign bit and produce a different value.
fn rawBitsFromValue(value: anytype, bit_count: u8) WriterError!u128 {
    const T = @TypeOf(value);
    comptime assertBitIntType(T, "writeBits");
    const info = @typeInfo(T).int;
    const bits_u8: u8 = @intCast(info.bits);

    if (bit_count > bits_u8) return error.Overflow;
    if (bit_count == 0) {
        if (value != 0) return error.Overflow;
        return 0;
    }

    const mask = maskU128(bit_count);
    if (info.signedness == .signed) {
        if (value < 0) {
            if (bit_count != bits_u8) return error.Overflow;
            const U = std.meta.Int(.unsigned, info.bits);
            const raw_signed: U = @bitCast(value);
            return @as(u128, raw_signed) & mask;
        }
    }

    const raw_non_negative: u128 = @intCast(value);
    if ((raw_non_negative & ~mask) != 0) return error.Overflow;
    return raw_non_negative;
}

fn readerEnd(pos: usize, n: usize, len: usize) ReaderError!usize {
    std.debug.assert(pos <= len);
    const end = std.math.add(usize, pos, n) catch return error.Overflow;
    if (end > len) return error.EndOfStream;
    std.debug.assert(end >= pos);
    return end;
}

fn writerEnd(pos: usize, n: usize, len: usize) WriterError!usize {
    std.debug.assert(pos <= len);
    const end = std.math.add(usize, pos, n) catch return error.Overflow;
    if (end > len) return error.NoSpaceLeft;
    std.debug.assert(end >= pos);
    return end;
}

fn totalBits(len: usize) usize {
    std.debug.assert(len <= std.math.maxInt(usize) / 8);
    return len * 8;
}

fn readerBitEnd(bit_pos: usize, bit_count: usize, total_bits: usize) ReaderError!usize {
    std.debug.assert(bit_pos <= total_bits);
    const end = std.math.add(usize, bit_pos, bit_count) catch return error.Overflow;
    if (end > total_bits) return error.EndOfStream;
    std.debug.assert(end >= bit_pos);
    return end;
}

fn writerBitEnd(bit_pos: usize, bit_count: usize, total_bits: usize) WriterError!usize {
    std.debug.assert(bit_pos <= total_bits);
    const end = std.math.add(usize, bit_pos, bit_count) catch return error.Overflow;
    if (end > total_bits) return error.NoSpaceLeft;
    std.debug.assert(end >= bit_pos);
    return end;
}

fn readRawBitsRuntime(buf: []const u8, bit_start: usize, bit_count: u8) u128 {
    var raw: u128 = 0;
    var bit_index: u8 = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        const absolute_bit = bit_start + bit_index;
        const byte_index = absolute_bit / 8;
        const bit_offset: u3 = @intCast(absolute_bit % 8);
        const bit = (buf[byte_index] >> bit_offset) & 0x01;
        const shift: u7 = @intCast(bit_index);
        raw |= @as(u128, bit) << shift;
    }
    return raw;
}

fn readRawBitsFixedWidth(buf: []const u8, bit_start: usize, comptime bit_count: u8) u128 {
    var raw: u128 = 0;
    inline for (0..bit_count) |bit_index| {
        const absolute_bit = bit_start + bit_index;
        const byte_index = absolute_bit / 8;
        const bit_offset: u3 = @intCast(absolute_bit % 8);
        const bit = (buf[byte_index] >> bit_offset) & 0x01;
        const shift: u7 = @intCast(bit_index);
        raw |= @as(u128, bit) << shift;
    }
    return raw;
}

fn writeRawBitsRuntime(buf: []u8, bit_start: usize, raw: u128, bit_count: u8) void {
    var bit_index: u8 = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        const absolute_bit = bit_start + bit_index;
        const byte_index = absolute_bit / 8;
        const bit_offset: u3 = @intCast(absolute_bit % 8);
        const shift: u7 = @intCast(bit_index);
        const bit_is_set = ((raw >> shift) & 0x01) != 0;
        const mask: u8 = @as(u8, 1) << bit_offset;
        if (bit_is_set) {
            buf[byte_index] |= mask;
        } else {
            buf[byte_index] &= ~mask;
        }
    }
}

fn writeRawBitsFixedWidth(buf: []u8, bit_start: usize, raw: u128, comptime bit_count: u8) void {
    inline for (0..bit_count) |bit_index| {
        const absolute_bit = bit_start + bit_index;
        const byte_index = absolute_bit / 8;
        const bit_offset: u3 = @intCast(absolute_bit % 8);
        const shift: u7 = @intCast(bit_index);
        const bit_is_set = ((raw >> shift) & 0x01) != 0;
        const mask: u8 = @as(u8, 1) << bit_offset;
        if (bit_is_set) {
            buf[byte_index] |= mask;
        } else {
            buf[byte_index] &= ~mask;
        }
    }
}

fn clearBitRange(buf: []u8, bit_start: usize, bit_count: usize) void {
    if (bit_count == 0) return;

    const bit_end = bit_start + bit_count;
    std.debug.assert(bit_end >= bit_start);
    std.debug.assert(bit_end <= buf.len * 8);

    // Clear leading partial-byte bits one at a time (at most 7).
    var current = bit_start;
    while (current < bit_end and current % 8 != 0) {
        const byte_idx = current / 8;
        const bit_offset: u3 = @intCast(current % 8);
        buf[byte_idx] &= ~(@as(u8, 1) << bit_offset);
        current += 1;
    }

    // Clear whole interior bytes with memset.
    const full_byte_start = current / 8;
    const full_bytes = (bit_end - current) / 8;
    if (full_bytes > 0) {
        @memset(buf[full_byte_start .. full_byte_start + full_bytes], 0);
        current += full_bytes * 8;
    }

    // Clear trailing partial-byte bits one at a time (at most 7).
    while (current < bit_end) {
        const byte_idx = current / 8;
        const bit_offset: u3 = @intCast(current % 8);
        buf[byte_idx] &= ~(@as(u8, 1) << bit_offset);
        current += 1;
    }

    std.debug.assert(current == bit_end);
}

fn assertBytePositionInBounds(pos: usize, len: usize) void {
    std.debug.assert(pos <= len);
}

fn assertBitPositionInBounds(pos: usize, total_bits: usize) void {
    std.debug.assert(pos <= total_bits);
}

fn validateByteReadPosition(pos: usize, len: usize) ReaderError!void {
    assertBytePositionInBounds(@min(pos, len), len);
    if (pos > len) return error.EndOfStream;
}

fn validateByteWritePosition(pos: usize, len: usize) WriterError!void {
    assertBytePositionInBounds(@min(pos, len), len);
    if (pos > len) return error.NoSpaceLeft;
}

fn validateBitReadPosition(pos: usize, total_bits: usize) ReaderError!void {
    assertBitPositionInBounds(@min(pos, total_bits), total_bits);
    if (pos > total_bits) return error.EndOfStream;
}

fn validateBitWritePosition(pos: usize, total_bits: usize) WriterError!void {
    assertBitPositionInBounds(@min(pos, total_bits), total_bits);
    if (pos > total_bits) return error.NoSpaceLeft;
}

/// A bounds-checked cursor for reading from an in-memory byte buffer.
///
/// Reads are atomic: on error, the cursor position is not advanced.
pub const ByteReader = struct {
    buf: []const u8,
    pos: usize = 0,

    /// Returns a reader positioned at the start of `buf`.
    pub fn init(buf: []const u8) ByteReader {
        return .{ .buf = buf };
    }

    /// Returns the current byte position.
    pub fn position(self: *const ByteReader) usize {
        assertBytePositionInBounds(self.pos, self.buf.len);
        return self.pos;
    }

    /// Captures the current byte position for a later `rewind`.
    pub fn mark(self: *const ByteReader) Checkpoint {
        assertBytePositionInBounds(self.pos, self.buf.len);
        return .{ .position = self.pos };
    }

    /// Restores the byte position captured in `checkpoint`.
    pub fn rewind(self: *ByteReader, checkpoint: Checkpoint) ReaderError!void {
        assertBytePositionInBounds(self.pos, self.buf.len);
        try validateByteReadPosition(checkpoint.position, self.buf.len);
        self.pos = checkpoint.position;
        assertBytePositionInBounds(self.pos, self.buf.len);
    }

    /// Sets the read cursor to `pos`. A position equal to `buf.len` is valid
    /// and represents end-of-buffer; any subsequent read at this position will
    /// return `error.EndOfStream`. Returns `error.EndOfStream` if `pos` exceeds
    /// `buf.len`.
    pub fn setPosition(self: *ByteReader, pos: usize) ReaderError!void {
        try validateByteReadPosition(pos, self.buf.len);
        self.pos = pos;
        assertBytePositionInBounds(self.pos, self.buf.len);
    }

    /// Returns the number of unread bytes.
    pub fn remaining(self: *const ByteReader) usize {
        assertBytePositionInBounds(self.pos, self.buf.len);
        return self.buf.len - self.pos;
    }

    /// Returns the next `n` bytes without advancing the cursor.
    pub fn peek(self: *const ByteReader, n: usize) ReaderError![]const u8 {
        const end = try readerEnd(self.pos, n, self.buf.len);
        return self.buf[self.pos..end];
    }

    /// Returns the next byte without advancing the cursor.
    pub fn peekByte(self: *const ByteReader) ReaderError!u8 {
        return (try self.peek(1))[0];
    }

    /// Returns the next integer without advancing the cursor.
    pub fn peekInt(self: *const ByteReader, comptime T: type, comptime order: Endian) ReaderError!T {
        comptime assertNonZeroIntType(T, "ByteReader.peekInt");
        assertBytePositionInBounds(self.pos, self.buf.len);
        return endian.readInt(self.buf, self.pos, T, order) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.Overflow => return error.Overflow,
        };
    }

    /// Reads the next `n` bytes and advances the cursor by `n`.
    pub fn read(self: *ByteReader, n: usize) ReaderError![]const u8 {
        const end = try readerEnd(self.pos, n, self.buf.len);
        const out = self.buf[self.pos..end];
        self.pos = end;
        std.debug.assert(self.pos <= self.buf.len);
        return out;
    }

    /// Reads a single byte.
    pub fn readByte(self: *ByteReader) ReaderError!u8 {
        return (try self.read(1))[0];
    }

    /// Reads one integer value using `order` and advances by `@sizeOf(T)` bytes.
    pub fn readInt(self: *ByteReader, comptime T: type, comptime order: Endian) ReaderError!T {
        comptime assertNonZeroIntType(T, "ByteReader.readInt");
        const end = try readerEnd(self.pos, @sizeOf(T), self.buf.len);
        const value = endian.readInt(self.buf, self.pos, T, order) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.Overflow => return error.Overflow,
        };
        self.pos = end;
        assertBytePositionInBounds(self.pos, self.buf.len);
        return value;
    }

    /// Reads one little-endian `u16`.
    pub fn readU16Le(self: *ByteReader) ReaderError!u16 {
        return self.readInt(u16, .little);
    }

    /// Reads one big-endian `u16`.
    pub fn readU16Be(self: *ByteReader) ReaderError!u16 {
        return self.readInt(u16, .big);
    }

    /// Reads one little-endian `u32`.
    pub fn readU32Le(self: *ByteReader) ReaderError!u32 {
        return self.readInt(u32, .little);
    }

    /// Reads one big-endian `u32`.
    pub fn readU32Be(self: *ByteReader) ReaderError!u32 {
        return self.readInt(u32, .big);
    }

    /// Advances the cursor by `n` bytes.
    pub fn skip(self: *ByteReader, n: usize) ReaderError!void {
        _ = try self.read(n);
    }
};

/// A bounds-checked cursor for writing into an in-memory byte buffer.
///
/// Writes are atomic: on error, the cursor position is not advanced.
pub const ByteWriter = struct {
    buf: []u8,
    pos: usize = 0,

    /// Returns a writer positioned at the start of `buf`.
    pub fn init(buf: []u8) ByteWriter {
        return .{ .buf = buf };
    }

    /// Returns the current byte position.
    pub fn position(self: *const ByteWriter) usize {
        assertBytePositionInBounds(self.pos, self.buf.len);
        return self.pos;
    }

    /// Captures the current byte position for a later `rewind`.
    pub fn mark(self: *const ByteWriter) Checkpoint {
        assertBytePositionInBounds(self.pos, self.buf.len);
        return .{ .position = self.pos };
    }

    /// Restores the byte position captured in `checkpoint`.
    pub fn rewind(self: *ByteWriter, checkpoint: Checkpoint) WriterError!void {
        assertBytePositionInBounds(self.pos, self.buf.len);
        try validateByteWritePosition(checkpoint.position, self.buf.len);
        self.pos = checkpoint.position;
        assertBytePositionInBounds(self.pos, self.buf.len);
    }

    /// Sets the write cursor to `pos`. A position equal to `buf.len` is valid
    /// and represents end-of-buffer; any subsequent write at this position will
    /// return `error.NoSpaceLeft`. Returns `error.NoSpaceLeft` if `pos` exceeds
    /// `buf.len`. Forward seeks zero the skipped region so reused buffers do not
    /// leak stale bytes into later output.
    pub fn setPosition(self: *ByteWriter, pos: usize) WriterError!void {
        try validateByteWritePosition(pos, self.buf.len);
        if (pos > self.pos) @memset(self.buf[self.pos..pos], 0);
        self.pos = pos;
        assertBytePositionInBounds(self.pos, self.buf.len);
    }

    /// Returns the number of unwritten bytes remaining in the buffer.
    pub fn remaining(self: *const ByteWriter) usize {
        assertBytePositionInBounds(self.pos, self.buf.len);
        return self.buf.len - self.pos;
    }

    /// Returns the portion of the buffer that has been written so far.
    pub fn writtenSlice(self: *const ByteWriter) []const u8 {
        assertBytePositionInBounds(self.pos, self.buf.len);
        return self.buf[0..self.pos];
    }

    /// Writes `bytes` and advances the cursor by `bytes.len`.
    pub fn write(self: *ByteWriter, bytes: []const u8) WriterError!void {
        const end = try writerEnd(self.pos, bytes.len, self.buf.len);
        @memcpy(self.buf[self.pos..end], bytes);
        self.pos = end;
        assertBytePositionInBounds(self.pos, self.buf.len);
    }

    /// Writes one byte.
    pub fn writeByte(self: *ByteWriter, b: u8) WriterError!void {
        return self.write(&.{b});
    }

    /// Writes one integer value using `order`.
    pub fn writeInt(self: *ByteWriter, value: anytype, comptime order: Endian) WriterError!void {
        comptime assertNonZeroIntType(@TypeOf(value), "ByteWriter.writeInt");
        const end = try writerEnd(self.pos, @sizeOf(@TypeOf(value)), self.buf.len);
        endian.writeInt(self.buf, self.pos, value, order) catch |err| switch (err) {
            error.NoSpaceLeft => return error.NoSpaceLeft,
            error.Overflow => return error.Overflow,
        };
        self.pos = end;
        assertBytePositionInBounds(self.pos, self.buf.len);
    }

    /// Writes one little-endian `u16`.
    pub fn writeU16Le(self: *ByteWriter, value: u16) WriterError!void {
        return self.writeInt(value, .little);
    }

    /// Writes one big-endian `u16`.
    pub fn writeU16Be(self: *ByteWriter, value: u16) WriterError!void {
        return self.writeInt(value, .big);
    }

    /// Writes one little-endian `u32`.
    pub fn writeU32Le(self: *ByteWriter, value: u32) WriterError!void {
        return self.writeInt(value, .little);
    }

    /// Writes one big-endian `u32`.
    pub fn writeU32Be(self: *ByteWriter, value: u32) WriterError!void {
        return self.writeInt(value, .big);
    }
};

/// A bounds-checked cursor for reading individual bits in LSB-first order.
///
/// Bit 0 refers to the least-significant bit of `buf[0]`.
pub const BitReader = struct {
    buf: []const u8,
    bit_pos: usize = 0,

    /// Returns a reader positioned at the first bit of `buf`.
    pub fn init(buf: []const u8) BitReader {
        // Ensure `buf.len * 8` fits in `usize` so bit-position arithmetic cannot overflow.
        std.debug.assert(buf.len <= std.math.maxInt(usize) / 8);
        return .{ .buf = buf };
    }

    /// Returns the current bit position.
    pub fn positionBits(self: *const BitReader) usize {
        const total_bits = totalBits(self.buf.len);
        assertBitPositionInBounds(self.bit_pos, total_bits);
        return self.bit_pos;
    }

    /// Captures the current bit position for a later `rewind`.
    pub fn mark(self: *const BitReader) BitCheckpoint {
        const total_bits = totalBits(self.buf.len);
        assertBitPositionInBounds(self.bit_pos, total_bits);
        return .{ .position_bits = self.bit_pos };
    }

    /// Restores the bit position captured in `checkpoint`.
    pub fn rewind(self: *BitReader, checkpoint: BitCheckpoint) ReaderError!void {
        const total_bits = totalBits(self.buf.len);
        assertBitPositionInBounds(self.bit_pos, total_bits);
        try validateBitReadPosition(checkpoint.position_bits, total_bits);
        self.bit_pos = checkpoint.position_bits;
        assertBitPositionInBounds(self.bit_pos, total_bits);
    }

    /// Returns the number of unread bits.
    pub fn remainingBits(self: *const BitReader) usize {
        const total_bits = totalBits(self.buf.len);
        assertBitPositionInBounds(self.bit_pos, total_bits);
        return total_bits - self.bit_pos;
    }

    /// Sets the current bit position.
    pub fn setPositionBits(self: *BitReader, bit_pos: usize) ReaderError!void {
        const total_bits = totalBits(self.buf.len);
        try validateBitReadPosition(bit_pos, total_bits);
        self.bit_pos = bit_pos;
        assertBitPositionInBounds(self.bit_pos, total_bits);
    }

    /// Advances by `bit_count` bits.
    pub fn skipBits(self: *BitReader, bit_count: usize) ReaderError!void {
        const total_bits = totalBits(self.buf.len);
        const end_bit = try readerBitEnd(self.bit_pos, bit_count, total_bits);
        self.bit_pos = end_bit;
        assertBitPositionInBounds(self.bit_pos, total_bits);
    }

    /// Reads `bit_count` bits as an LSB-first integer value.
    ///
    /// A zero-width read returns 0 and does not advance the cursor.
    pub fn readBits(self: *BitReader, comptime T: type, bit_count: u8) ReaderError!T {
        comptime assertBitIntType(T, "readBits");
        const info = @typeInfo(T).int;
        const bits_u8: u8 = @intCast(info.bits);
        if (bit_count > bits_u8) return error.Overflow;

        const total_bits = totalBits(self.buf.len);
        const end_bit = try readerBitEnd(self.bit_pos, bit_count, total_bits);
        const raw = readRawBitsRuntime(self.buf, self.bit_pos, bit_count);

        const value = valueFromRawBits(T, raw, bit_count);
        self.bit_pos = end_bit;
        assertBitPositionInBounds(self.bit_pos, total_bits);
        return value;
    }

    /// Reads `bit_count` bits as an LSB-first integer value.
    ///
    /// This variant enforces `bit_count <= @bitSizeOf(T)` at compile time and
    /// unrolls extraction for fixed-width bit layouts.
    pub fn readBitsCt(self: *BitReader, comptime T: type, comptime bit_count: u8) ReaderError!T {
        comptime assertBitCountFitsType(T, bit_count, "readBitsCt");

        const total_bits = totalBits(self.buf.len);
        const end_bit = try readerBitEnd(self.bit_pos, bit_count, total_bits);
        const raw = readRawBitsFixedWidth(self.buf, self.bit_pos, bit_count);

        const value = valueFromRawBits(T, raw, bit_count);
        self.bit_pos = end_bit;
        assertBitPositionInBounds(self.bit_pos, total_bits);
        return value;
    }
};

/// A bounds-checked cursor for writing individual bits in LSB-first order.
///
/// Bit 0 refers to the least-significant bit of `buf[0]`.
pub const BitWriter = struct {
    buf: []u8,
    bit_pos: usize = 0,

    /// Returns a writer positioned at the first bit of `buf`.
    pub fn init(buf: []u8) BitWriter {
        // Ensure `buf.len * 8` fits in `usize` so bit-position arithmetic cannot overflow.
        std.debug.assert(buf.len <= std.math.maxInt(usize) / 8);
        return .{ .buf = buf };
    }

    /// Returns the current bit position.
    pub fn positionBits(self: *const BitWriter) usize {
        const total_bits = totalBits(self.buf.len);
        assertBitPositionInBounds(self.bit_pos, total_bits);
        return self.bit_pos;
    }

    /// Captures the current bit position for a later `rewind`.
    pub fn mark(self: *const BitWriter) BitCheckpoint {
        const total_bits = totalBits(self.buf.len);
        assertBitPositionInBounds(self.bit_pos, total_bits);
        return .{ .position_bits = self.bit_pos };
    }

    /// Restores the bit position captured in `checkpoint`.
    pub fn rewind(self: *BitWriter, checkpoint: BitCheckpoint) WriterError!void {
        const total_bits = totalBits(self.buf.len);
        assertBitPositionInBounds(self.bit_pos, total_bits);
        try validateBitWritePosition(checkpoint.position_bits, total_bits);
        self.bit_pos = checkpoint.position_bits;
        assertBitPositionInBounds(self.bit_pos, total_bits);
    }

    /// Returns the number of unwritten bits remaining in the buffer.
    pub fn remainingBits(self: *const BitWriter) usize {
        const total_bits = totalBits(self.buf.len);
        assertBitPositionInBounds(self.bit_pos, total_bits);
        return total_bits - self.bit_pos;
    }

    /// Sets the current bit position.
    ///
    /// Forward seeks zero the skipped bit range so reused buffers do not leak
    /// stale bitfields into later output.
    pub fn setPositionBits(self: *BitWriter, bit_pos: usize) WriterError!void {
        const total_bits = totalBits(self.buf.len);
        try validateBitWritePosition(bit_pos, total_bits);
        if (bit_pos > self.bit_pos) clearBitRange(self.buf, self.bit_pos, bit_pos - self.bit_pos);
        self.bit_pos = bit_pos;
        assertBitPositionInBounds(self.bit_pos, total_bits);
    }

    /// Advances by `bit_count` bits.
    ///
    /// Skipped bits are zeroed so later readers observe deterministic output.
    pub fn skipBits(self: *BitWriter, bit_count: usize) WriterError!void {
        const total_bits = totalBits(self.buf.len);
        const end_bit = try writerBitEnd(self.bit_pos, bit_count, total_bits);
        clearBitRange(self.buf, self.bit_pos, bit_count);
        self.bit_pos = end_bit;
        assertBitPositionInBounds(self.bit_pos, total_bits);
    }

    /// Writes the lower `bit_count` bits of `value` in LSB-first order.
    ///
    /// A zero-width write is a no-op and requires `value == 0`. Negative signed
    /// values are accepted only for full-width writes.
    pub fn writeBits(self: *BitWriter, value: anytype, bit_count: u8) WriterError!void {
        const raw = try rawBitsFromValue(value, bit_count);
        const total_bits = totalBits(self.buf.len);
        const end_bit = try writerBitEnd(self.bit_pos, bit_count, total_bits);
        writeRawBitsRuntime(self.buf, self.bit_pos, raw, bit_count);

        self.bit_pos = end_bit;
        assertBitPositionInBounds(self.bit_pos, total_bits);
    }

    /// Writes the lower `bit_count` bits of `value` in LSB-first order.
    ///
    /// This variant enforces `bit_count <= @bitSizeOf(@TypeOf(value))` at compile
    /// time, preserves the same signed-value rules as `writeBits`, and unrolls
    /// writes for fixed-width bit layouts.
    pub fn writeBitsCt(self: *BitWriter, value: anytype, comptime bit_count: u8) WriterError!void {
        comptime assertBitCountFitsType(@TypeOf(value), bit_count, "writeBitsCt");
        const raw = try rawBitsFromValue(value, bit_count);

        const total_bits = totalBits(self.buf.len);
        const end_bit = try writerBitEnd(self.bit_pos, bit_count, total_bits);
        writeRawBitsFixedWidth(self.buf, self.bit_pos, raw, bit_count);

        self.bit_pos = end_bit;
        assertBitPositionInBounds(self.bit_pos, total_bits);
    }
};

fn nextDeterministic(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

test "reader and writer preserve atomic cursor semantics on failure" {
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    var r = ByteReader.init(&data);
    try std.testing.expectEqual(@as(usize, 0), r.position());
    try std.testing.expectError(error.EndOfStream, r.readInt(u32, .little));
    try std.testing.expectEqual(@as(usize, 0), r.position());
    try std.testing.expectEqual(@as(u16, 0x0201), try r.readInt(u16, .little));
    try std.testing.expectEqual(@as(usize, 2), r.position());

    var out = [_]u8{0} ** 2;
    var w = ByteWriter.init(&out);
    try std.testing.expectError(error.NoSpaceLeft, w.writeInt(@as(u32, 0xDEADBEEF), .little));
    try std.testing.expectEqual(@as(usize, 0), w.position());
}

test "reader cursor bounds and position semantics are explicit" {
    const data = [_]u8{ 0x10, 0x20, 0x30 };
    var reader = ByteReader.init(&data);

    try std.testing.expectEqual(@as(usize, 3), reader.remaining());
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20 }, try reader.peek(2));
    try std.testing.expectEqual(@as(usize, 0), reader.position());
    try std.testing.expectError(error.EndOfStream, reader.setPosition(4));

    try reader.setPosition(3);
    try std.testing.expectEqual(@as(usize, 3), reader.position());
    try std.testing.expectError(error.EndOfStream, reader.readByte());
}

test "reader overflow does not advance position" {
    const data = [_]u8{ 0xAA, 0xBB };
    var reader = ByteReader.init(&data);
    try reader.setPosition(1);
    try std.testing.expectError(error.Overflow, reader.read(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 1), reader.position());
}

test "writer cursor bounds and write helpers are explicit" {
    var out = [_]u8{0} ** 7;
    var writer = ByteWriter.init(&out);

    try writer.writeByte(0x11);
    try writer.write(&.{ 0x22, 0x33 });
    try writer.writeU16Be(0x4455);
    try writer.writeU16Le(0x6677);
    try std.testing.expectEqual(@as(usize, 7), writer.position());
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x77, 0x66 }, out[0..7]);
    try std.testing.expectError(error.NoSpaceLeft, writer.setPosition(8));
}

test "byte cursor checkpoints support rewind" {
    const data = [_]u8{ 0xAA, 0xBB, 0xCC };
    var reader = ByteReader.init(&data);
    _ = try reader.readByte();
    const read_mark = reader.mark();
    try std.testing.expectEqual(@as(u8, 0xBB), try reader.readByte());
    try reader.rewind(read_mark);
    try std.testing.expectEqual(@as(u8, 0xBB), try reader.readByte());

    var out = [_]u8{0} ** 4;
    var writer = ByteWriter.init(&out);
    try writer.write(&.{ 0x10, 0x20 });
    const write_mark = writer.mark();
    try writer.write(&.{ 0x30, 0x40 });
    try writer.rewind(write_mark);
    try writer.write(&.{ 0x55, 0x66 });
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x55, 0x66 }, &out);
}

test "bit cursor supports non-byte-aligned round-trip" {
    var out = [_]u8{0} ** 3;
    var writer = BitWriter.init(&out);
    try writer.writeBits(@as(u3, 0b101), 3);
    const checkpoint = writer.mark();
    try writer.writeBits(@as(u4, 0b1101), 4);
    try writer.rewind(checkpoint);
    try writer.writeBits(@as(u4, 0b0110), 4);
    try writer.writeBits(@as(u2, 0b11), 2);
    try std.testing.expectEqual(@as(usize, 9), writer.positionBits());

    var reader = BitReader.init(&out);
    try std.testing.expectEqual(@as(u3, 0b101), try reader.readBits(u3, 3));
    try std.testing.expectEqual(@as(u4, 0b0110), try reader.readBits(u4, 4));
    try std.testing.expectEqual(@as(u2, 0b11), try reader.readBits(u2, 2));
    try std.testing.expectError(error.EndOfStream, reader.readBits(u16, 16));
}

test "bit cursor zero-width reads and writes are no-ops" {
    var out = [_]u8{0} ** 2;
    var writer = BitWriter.init(&out);
    try writer.writeBits(@as(u8, 0), 0);
    try std.testing.expectEqual(@as(usize, 0), writer.positionBits());
    try std.testing.expectError(error.Overflow, writer.writeBits(@as(u8, 1), 0));
    try std.testing.expectEqual(@as(usize, 0), writer.positionBits());
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00 }, &out);

    var reader = BitReader.init(&out);
    try std.testing.expectEqual(@as(u16, 0), try reader.readBits(u16, 0));
    try std.testing.expectEqual(@as(usize, 0), reader.positionBits());
}

test "bit cursor signed full-width reads preserve two's-complement payloads" {
    var out = [_]u8{0} ** 1;
    var writer = BitWriter.init(&out);
    try writer.writeBits(@as(i8, -1), 8);
    try std.testing.expectEqual(@as(u8, 0xFF), out[0]);

    var reader = BitReader.init(&out);
    try std.testing.expectEqual(@as(i8, -1), try reader.readBits(i8, 8));
}

test "bit writer preserves position on failure" {
    var out = [_]u8{0} ** 1;
    var writer = BitWriter.init(&out);
    try writer.writeBits(@as(u4, 0b1010), 4);
    try std.testing.expectEqual(@as(usize, 4), writer.positionBits());
    try std.testing.expectError(error.NoSpaceLeft, writer.writeBits(@as(u8, 0xFF), 8));
    try std.testing.expectEqual(@as(usize, 4), writer.positionBits());
    try std.testing.expectError(error.Overflow, writer.writeBits(@as(u8, 0x80), 7));
    try std.testing.expectEqual(@as(usize, 4), writer.positionBits());
}

test "bit writer skipBits preserves atomic cursor semantics on failure" {
    var out = [_]u8{0} ** 1;
    var writer = BitWriter.init(&out);
    try writer.skipBits(4);
    try std.testing.expectEqual(@as(usize, 4), writer.positionBits());
    try std.testing.expectError(error.NoSpaceLeft, writer.skipBits(5));
    try std.testing.expectEqual(@as(usize, 4), writer.positionBits());
}

test "writer forward seeks zero skipped regions" {
    var bytes = [_]u8{0xFF} ** 4;
    var writer = ByteWriter.init(&bytes);
    try writer.writeByte(0x11);
    try writer.setPosition(3);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x00, 0x00, 0xFF }, &bytes);

    var bits_buf = [_]u8{0xFF} ** 2;
    var bit_writer = BitWriter.init(&bits_buf);
    try bit_writer.writeBits(@as(u3, 0b101), 3);
    try bit_writer.setPositionBits(8);
    try std.testing.expectEqual(@as(u8, 0b0000_0101), bits_buf[0]);
}

test "bit writer skipBits zeroes skipped range" {
    var bytes = [_]u8{0xFF} ** 2;
    var writer = BitWriter.init(&bytes);
    try writer.writeBits(@as(u2, 0b11), 2);
    try writer.skipBits(4);
    try writer.writeBits(@as(u2, 0b10), 2);
    try std.testing.expectEqual(@as(u8, 0b1000_0011), bytes[0]);
}

test "bit cursor comptime-width helpers mirror runtime helpers" {
    var out = [_]u8{0} ** 3;
    var writer = BitWriter.init(&out);
    try writer.writeBitsCt(@as(u3, 0b101), 3);
    try writer.writeBitsCt(@as(u5, 0b01110), 5);
    try writer.writeBitsCt(@as(u2, 0b11), 2);

    var reader = BitReader.init(&out);
    try std.testing.expectEqual(@as(u3, 0b101), try reader.readBitsCt(u3, 3));
    try std.testing.expectEqual(@as(u5, 0b01110), try reader.readBitsCt(u5, 5));
    try std.testing.expectEqual(@as(u2, 0b11), try reader.readBitsCt(u2, 2));
}

test "bit cursor comptime-width helpers preserve position on failure" {
    const data = [_]u8{0xAB};
    var reader = BitReader.init(&data);
    try reader.setPositionBits(4);
    try std.testing.expectError(error.EndOfStream, reader.readBitsCt(u8, 5));
    try std.testing.expectEqual(@as(usize, 4), reader.positionBits());

    var out = [_]u8{0} ** 1;
    var writer = BitWriter.init(&out);
    try writer.setPositionBits(4);
    try std.testing.expectError(error.NoSpaceLeft, writer.writeBitsCt(@as(u5, 0b1_1111), 5));
    try std.testing.expectEqual(@as(usize, 4), writer.positionBits());

    try std.testing.expectError(error.Overflow, writer.writeBitsCt(@as(u8, 0x80), 7));
    try std.testing.expectEqual(@as(usize, 4), writer.positionBits());
}

test "deterministic bit cursor model comparison" {
    var backing = [_]u8{0} ** 32;
    var bit_model = [_]u1{0} ** 256;
    var writer = BitWriter.init(&backing);

    var widths = [_]u8{0} ** 64;
    var values = [_]u16{0} ** 64;
    var op_count: usize = 0;
    var bit_model_pos: usize = 0;
    var state: u64 = 0x9E3779B97F4A7C15;

    while (op_count < widths.len) {
        const rand = nextDeterministic(&state);
        const width: u8 = @intCast((rand & 0x0F) + 1);
        if (writer.remainingBits() < width) break;

        const mask: u16 = if (width == 16)
            std.math.maxInt(u16)
        else
            (@as(u16, 1) << @as(u4, @intCast(width))) - 1;
        const value: u16 = @intCast((rand >> 8) & mask);
        try writer.writeBits(value, width);

        widths[op_count] = width;
        values[op_count] = value;
        var bit_index: u8 = 0;
        while (bit_index < width) : (bit_index += 1) {
            const shift: u4 = @intCast(bit_index);
            bit_model[bit_model_pos] = @intCast((value >> shift) & 0x01);
            bit_model_pos += 1;
        }

        op_count += 1;
    }

    var reader = BitReader.init(&backing);
    var read_op: usize = 0;
    var model_bit_pos: usize = 0;
    while (read_op < op_count) : (read_op += 1) {
        const width = widths[read_op];
        const expected = values[read_op];
        const got = try reader.readBits(u16, width);
        try std.testing.expectEqual(expected, got);

        var bit_index: u8 = 0;
        while (bit_index < width) : (bit_index += 1) {
            const shift: u4 = @intCast(bit_index);
            const got_bit: u1 = @intCast((got >> shift) & 0x01);
            try std.testing.expectEqual(bit_model[model_bit_pos], got_bit);
            model_bit_pos += 1;
        }
    }
}
