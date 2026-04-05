//! Demonstrates LEB128 encoding/decoding using `varint` helpers with cursor I/O.

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("static_bits");

pub fn main() !void {
    var storage = [_]u8{0} ** 10;
    var writer = bits.cursor.ByteWriter.init(&storage);
    try bits.varint.writeUleb128(&writer, 300);

    var reader = bits.cursor.ByteReader.init(storage[0..writer.position()]);
    const decoded = try bits.varint.readUleb128(&reader);
    assert(decoded == 300);
    assert(reader.remaining() == 0);
}
