//! Demonstrates reading bytes from an in-memory buffer using `cursor.ByteReader`.

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("static_bits");

pub fn main() !void {
    var reader = bits.cursor.ByteReader.init("abc");
    const first = try reader.readByte();
    assert(first == 'a');
    assert(reader.remaining() == 2);
}
