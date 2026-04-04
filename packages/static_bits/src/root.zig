//! `static_bits` provides small, allocation-free primitives for working with bits and bytes.
//!
//! The public API is intentionally split by concern:
//! - `endian`: Endian-safe integer loads/stores over byte slices.
//! - `cursor`: Bounds-checked byte readers and writers.
//! - `varint`: Varint (LEB128) encode/decode helpers.
//! - `bitfield`: Bit-range extraction and packing utilities.
//! - `cast`: Explicit, checked integer casts.
//!
//! Package boundary:
//! - `static_bits` owns primitive mechanics over caller-owned memory.
//! - Higher-level wire-format flows belong in `static_serial`.
//! - This package must not grow checksum, framing, zigzag-policy, or schema helpers.

const std = @import("std");
pub const core = @import("static_core");

pub const endian = @import("bits/endian.zig");
pub const cast = @import("bits/cast.zig");
pub const cursor = @import("bits/cursor.zig");
pub const varint = @import("bits/varint.zig");
pub const bitfield = @import("bits/bitfield.zig");

test {
    _ = core;
    _ = endian;
    _ = cast;
    _ = cursor;
    _ = varint;
    _ = bitfield;
}

test "public API exports are wired consistently" {
    var bytes = [_]u8{ 0x34, 0x12 };
    try std.testing.expectEqual(@as(u16, 0x1234), try endian.readInt(&bytes, 0, u16, .little));
    try std.testing.expectEqual(@as(u16, 0x1234), endian.readIntAt(u16, &bytes, 0, .little));
    try std.testing.expectEqual(@as(u8, 7), try cast.castInt(u8, @as(u16, 7)));

    var reader = cursor.ByteReader.init(&bytes);
    try std.testing.expectEqual(@as(u8, 0x34), try reader.readByte());

    var writer = cursor.ByteWriter.init(&bytes);
    try varint.writeUleb128(&writer, 0x34);
    try std.testing.expectEqualSlices(u8, bytes[0..writer.position()], writer.writtenSlice());
    const extracted = try bitfield.extractBits(u8, bytes[0], 2, 3);
    try std.testing.expectEqual(@as(u8, 0b101), extracted);
    const extracted_ct = bitfield.extractBitsCt(u8, bytes[0], 2, 3);
    try std.testing.expectEqual(extracted, extracted_ct);

    var peek_bytes = [_]u8{ 0xAB, 0xCD };
    var peek_reader = cursor.ByteReader.init(&peek_bytes);
    try std.testing.expectEqual(@as(u8, 0xAB), try peek_reader.peekByte());
    try std.testing.expectEqual(@as(u16, 0xCDAB), try peek_reader.peekInt(u16, .little));
    try std.testing.expectEqual(@as(usize, 0), peek_reader.position());

    try endian.storeInt(&peek_bytes, @as(u16, 0x1234), .big);
    try std.testing.expectEqual(@as(u16, 0x1234), try endian.loadInt(u16, &peek_bytes, .big));
}
