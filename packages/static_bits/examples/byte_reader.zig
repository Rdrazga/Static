//! Demonstrates reading bytes from an in-memory buffer using `cursor.ByteReader`.

const std = @import("std");
const bits = @import("static_bits");

pub fn main() !void {
    var reader = bits.cursor.ByteReader.init("abc");
    const first = try reader.readByte();
    std.debug.assert(first == 'a');
    std.debug.assert(reader.remaining() == 2);
}
