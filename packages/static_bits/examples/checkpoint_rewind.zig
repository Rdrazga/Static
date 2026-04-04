//! Demonstrates checkpoint and rewind semantics for speculative parsing.

const std = @import("std");
const bits = @import("static_bits");

pub fn main() !void {
    const bytes = [_]u8{ 0xAA, 0xBB, 0xCC };
    var reader = bits.cursor.ByteReader.init(&bytes);
    _ = try reader.readByte();

    const checkpoint = reader.mark();
    const second = try reader.readByte();
    std.debug.assert(second == 0xBB);

    try reader.rewind(checkpoint);
    std.debug.assert(reader.position() == 1);
    std.debug.assert((try reader.readByte()) == 0xBB);
}
