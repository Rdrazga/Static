//! CRC32 checksum framing for the serial wire format.
//!
//! Key types: `Checksum32`.
//! Usage pattern: write payload bytes with a `Writer`, then call
//! `writeChecksum32(writer, payload)` to append the checksum; on the read side
//! call `verifyChecksum32(payload, stored)` to confirm integrity.
//! Thread safety: not thread-safe — `Writer` instances are single-owner values.

const std = @import("std");
const static_hash = @import("static_hash");
const writer_mod = @import("writer.zig");

pub const Checksum32 = static_hash.crc32.Crc32;

pub fn writeChecksum32(writer: *writer_mod.Writer, payload: []const u8) writer_mod.Error!void {
    // Precondition: an empty payload has no meaningful checksum to protect.
    std.debug.assert(payload.len > 0);
    const pos_before = writer.position();
    const sum = static_hash.crc32.checksum(payload);
    try writer.writeInt(sum, .little);
    // Postcondition: exactly 4 bytes (u32) were written to the writer.
    std.debug.assert(writer.position() == pos_before + 4);
}

pub fn verifyChecksum32(payload: []const u8, expected: u32) error{CorruptData}!void {
    // Precondition: an empty payload has no meaningful checksum to verify.
    std.debug.assert(payload.len > 0);
    // Precondition: expected value must be a plausible u32 (always true for the
    // type, but documenting that caller must pass the stored value, not zero by default).
    std.debug.assert(@TypeOf(expected) == u32);
    if (static_hash.crc32.checksum(payload) != expected) return error.CorruptData;
}

test "checksum mismatch returns CorruptData" {
    try std.testing.expectError(error.CorruptData, verifyChecksum32("abc", 0));
}

test "SE-T5: checksum positive case: write then verify succeeds" {
    // Goal: verify that writeChecksum32 followed by verifyChecksum32 succeeds
    // when the payload and stored value agree.
    // Method: write a checksum, extract the stored u32, then call verify.
    const payload = "hello, serial";
    var buf = [_]u8{0} ** 4;
    var w = writer_mod.Writer.init(&buf);
    try writeChecksum32(&w, payload);
    std.debug.assert(w.position() == 4);

    const stored_checksum = std.mem.readInt(u32, buf[0..4], .little);
    try verifyChecksum32(payload, stored_checksum);
}

test "SE-T1: serial end-to-end integration roundtrip" {
    // Goal: verify the full Writer -> Reader pipeline through all codec layers.
    // Method: write an integer, a varint, a zigzag-encoded value, and a checksum;
    // then read them back in the same order and assert roundtrip identity.
    const test_int: u32 = 0xDEAD_BEEF;
    const test_varint: u64 = 123_456_789;
    const test_zigzag: i32 = -42;

    // Write phase.
    var buf = [_]u8{0} ** 64;
    var w = writer_mod.Writer.init(&buf);
    const payload_start = w.position();

    try w.writeInt(test_int, .little);
    try w.writeVarint(test_varint);
    try w.writeZigZag(test_zigzag);

    const payload_end = w.position();
    std.debug.assert(payload_end > payload_start);

    const payload = buf[payload_start..payload_end];
    try writeChecksum32(&w, payload);
    const written_total = w.position();
    std.debug.assert(written_total == payload_end + 4);

    // Read phase.
    const reader_mod = @import("reader.zig");
    var r = reader_mod.Reader.init(buf[0..written_total]);

    const read_int = try r.readInt(u32, .little);
    try std.testing.expectEqual(test_int, read_int);

    const read_varint = try r.readVarint(u64);
    try std.testing.expectEqual(test_varint, read_varint);

    const read_zigzag = try r.readZigZag(i32);
    try std.testing.expectEqual(test_zigzag, read_zigzag);

    // Read and verify checksum.
    const stored_checksum = try r.readInt(u32, .little);
    try verifyChecksum32(payload, stored_checksum);

    // Postcondition: reader consumed exactly the bytes writer produced.
    std.debug.assert(r.remaining() == 0);
}
