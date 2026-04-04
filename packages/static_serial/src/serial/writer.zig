//! Structured binary writer over caller-provided byte slices.
//!
//! Key types: `Writer`.
//! Usage pattern: call `Writer.init(buf)`, then chain `writeInt`, `writeVarint`,
//! and `writeZigZag` calls; on failure the cursor does not advance.
//! Thread safety: not thread-safe — each `Writer` instance must be used from one thread.

const std = @import("std");
const bits = @import("static_bits");
const varint = @import("varint.zig");
const zigzag = @import("zigzag.zig");

pub const Endian = bits.endian.Endian;

pub const Error = error{
    NoSpaceLeft,
    InvalidInput,
    Overflow,
    Underflow,
};

pub const Writer = struct {
    cursor: bits.cursor.ByteWriter,

    pub fn init(bytes: []u8) Writer {
        const w = Writer{ .cursor = bits.cursor.ByteWriter.init(bytes) };
        // Postcondition: writer always starts at position zero.
        std.debug.assert(w.cursor.position() == 0);
        // Postcondition: the backing slice length matches the input length.
        std.debug.assert(w.cursor.remaining() == bytes.len);
        return w;
    }

    pub fn position(self: *const Writer) usize {
        const pos = self.cursor.position();
        // Postcondition: position is always <= total buffer size.
        std.debug.assert(pos <= pos + self.cursor.remaining());
        return pos;
    }

    pub fn remaining(self: *const Writer) usize {
        const rem = self.cursor.remaining();
        // Postcondition: remaining is consistent with position.
        std.debug.assert(rem <= rem + self.cursor.position());
        return rem;
    }

    pub fn writeBytes(self: *Writer, bytes: []const u8) Error!void {
        const pos_before = self.cursor.position();
        self.cursor.write(bytes) catch |err| return switch (err) {
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.Overflow => error.Overflow,
        };
        // Postcondition: position advanced by exactly bytes.len.
        std.debug.assert(self.cursor.position() == pos_before + bytes.len);
    }

    pub fn writeInt(self: *Writer, value: anytype, comptime order: Endian) Error!void {
        const T = @TypeOf(value);
        const pos_before = self.cursor.position();
        self.cursor.writeInt(value, order) catch |err| return switch (err) {
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.Overflow => error.Overflow,
        };
        // Postcondition: position advanced by exactly @sizeOf(T) bytes.
        std.debug.assert(self.cursor.position() == pos_before + @sizeOf(T));
    }

    pub fn writeVarint(self: *Writer, value: anytype) Error!void {
        // Precondition: value type must be an integer.
        comptime std.debug.assert(@typeInfo(@TypeOf(value)) == .int);
        const pos_before = self.cursor.position();
        varint.writeVarint(&self.cursor, value) catch |err| return switch (err) {
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.InvalidInput => error.InvalidInput,
            error.Overflow => error.Overflow,
            error.Underflow => error.Underflow,
            error.EndOfStream => @panic(
                "writeVarint: internal error (EndOfStream from writer cursor)",
            ),
        };
        // Postcondition: on success, position has advanced by at least 1 byte.
        std.debug.assert(self.cursor.position() > pos_before);
    }

    pub fn writeZigZag(self: *Writer, value: anytype) Error!void {
        // Precondition: value type must be a signed integer.
        comptime std.debug.assert(@typeInfo(@TypeOf(value)) == .int);
        comptime std.debug.assert(@typeInfo(@TypeOf(value)).int.signedness == .signed);
        const pos_before = self.cursor.position();
        const encoded = zigzag.zigZagEncode(value);
        try self.writeVarint(encoded);
        // Postcondition: on success, position has advanced by at least 1 byte.
        std.debug.assert(self.cursor.position() > pos_before);
    }
};

test "writer writes canonical varints and bounded bytes" {
    var buf = [_]u8{0} ** 8;
    var w = Writer.init(&buf);
    try w.writeVarint(@as(u32, 300));
    try std.testing.expect(w.position() > 0);
}

test "SE-T4: writeBytes past end returns NoSpaceLeft" {
    // Goal: verify writeBytes returns NoSpaceLeft when there is insufficient space.
    // Method: attempt to write more bytes than the buffer can hold.
    var buf = [_]u8{0} ** 2;
    var w = Writer.init(&buf);
    try std.testing.expectError(error.NoSpaceLeft, w.writeBytes(&.{ 0x01, 0x02, 0x03 }));
    // Position must not have advanced on failure.
    try std.testing.expectEqual(@as(usize, 0), w.position());
}

test "SE-T4: writeBytes success advances position by bytes.len" {
    // Goal: verify writeBytes postcondition: position advances by exactly bytes.len.
    // Method: write 2 bytes to a 4-byte buffer.
    var buf = [_]u8{0} ** 4;
    var w = Writer.init(&buf);
    try w.writeBytes(&.{ 0xAA, 0xBB });
    try std.testing.expectEqual(@as(usize, 2), w.position());
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, buf[0..2]);
}
