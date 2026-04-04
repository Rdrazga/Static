//! Structured binary reader over byte slices.
//!
//! Key types: `Reader`.
//! Usage pattern: call `Reader.init(bytes)`, then chain `readInt`, `readVarint`,
//! and `readZigZag` calls; on failure the cursor does not advance.
//! Thread safety: not thread-safe — each `Reader` instance must be used from one thread.

const std = @import("std");
const bits = @import("static_bits");
const varint = @import("varint.zig");
const zigzag = @import("zigzag.zig");

pub const Endian = bits.endian.Endian;

pub const Error = error{
    EndOfStream,
    InvalidInput,
    Overflow,
    Underflow,
    CorruptData,
};

pub const Reader = struct {
    cursor: bits.cursor.ByteReader,

    pub fn init(bytes: []const u8) Reader {
        const r = Reader{ .cursor = bits.cursor.ByteReader.init(bytes) };
        // Postcondition: reader always starts at position zero.
        std.debug.assert(r.cursor.position() == 0);
        // Postcondition: the backing slice length matches the input length.
        std.debug.assert(r.cursor.remaining() == bytes.len);
        return r;
    }

    pub fn position(self: *const Reader) usize {
        const pos = self.cursor.position();
        // Postcondition: position is always <= total byte count (remaining + position).
        std.debug.assert(pos <= pos + self.cursor.remaining());
        return pos;
    }

    pub fn remaining(self: *const Reader) usize {
        const rem = self.cursor.remaining();
        // Postcondition: remaining is always >= 0 (unsigned, so always true) and
        // consistent with position -- document the structural invariant.
        std.debug.assert(rem <= rem + self.cursor.position());
        return rem;
    }

    pub fn readBytes(self: *Reader, n: usize) Error![]const u8 {
        const pos_before = self.cursor.position();
        const slice = self.cursor.read(n) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.Overflow => return error.Overflow,
        };
        // Postcondition: returned slice length must exactly equal the requested n.
        std.debug.assert(slice.len == n);
        // Postcondition: position advanced by exactly n bytes.
        std.debug.assert(self.cursor.position() == pos_before + n);
        return slice;
    }

    pub fn readInt(self: *Reader, comptime T: type, comptime order: Endian) Error!T {
        const pos_before = self.cursor.position();
        const value = self.cursor.readInt(T, order) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.Overflow => return error.Overflow,
        };
        // Postcondition: position advanced by exactly @sizeOf(T) bytes.
        std.debug.assert(self.cursor.position() == pos_before + @sizeOf(T));
        return value;
    }

    pub fn readVarint(self: *Reader, comptime T: type) Error!T {
        // Precondition: T must be an integer type (enforced by readVarint itself).
        comptime std.debug.assert(@typeInfo(T) == .int);
        const pos_before = self.cursor.position();
        const value = varint.readVarint(&self.cursor, T) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.InvalidInput => return error.InvalidInput,
            error.Overflow => return error.Overflow,
            error.Underflow => return error.Underflow,
            error.NoSpaceLeft => @panic(
                "readVarint: internal error (NoSpaceLeft from reader cursor)",
            ),
        };
        // Postcondition: on success, position has advanced by at least 1 byte.
        std.debug.assert(self.cursor.position() > pos_before);
        return value;
    }

    pub fn readZigZag(self: *Reader, comptime T: type) Error!T {
        // Precondition: T must be a signed integer.
        comptime std.debug.assert(@typeInfo(T) == .int);
        comptime std.debug.assert(@typeInfo(T).int.signedness == .signed);
        const U = zigzag.signedToUnsigned(T);
        const pos_before = self.cursor.position();
        const raw = try self.readVarint(U);
        const decoded = zigzag.zigZagDecode(T, raw);
        // Postcondition: position advanced (readVarint already guarantees >= 1).
        std.debug.assert(self.cursor.position() > pos_before);
        return decoded;
    }
};

test "reader delegates to bits cursor deterministically" {
    const bytes = [_]u8{ 0x34, 0x12 };
    var r = Reader.init(&bytes);
    try std.testing.expectEqual(@as(u16, 0x1234), try r.readInt(u16, .little));
    try std.testing.expectError(error.EndOfStream, r.readInt(u8, .little));
}

test "SE-T4: readBytes past end returns EndOfStream" {
    // Goal: verify readBytes returns EndOfStream when n exceeds remaining bytes.
    // Method: request more bytes than the buffer holds.
    const bytes = [_]u8{ 0xAA, 0xBB };
    var r = Reader.init(&bytes);
    try std.testing.expectError(error.EndOfStream, r.readBytes(3));
    // Position must not have advanced on failure.
    try std.testing.expectEqual(@as(usize, 0), r.position());
}

test "SE-T4: readBytes success advances position by n" {
    // Goal: verify readBytes postcondition: position advances by exactly n.
    // Method: read 2 bytes from a 3-byte buffer.
    const bytes = [_]u8{ 0x01, 0x02, 0x03 };
    var r = Reader.init(&bytes);
    const slice = try r.readBytes(2);
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(usize, 2), r.position());
}
