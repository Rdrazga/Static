//! Demonstrates bit-level round-tripping using `cursor.BitReader` and `cursor.BitWriter`.

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("static_bits");

pub fn main() !void {
    var storage = [_]u8{0} ** 2;
    var writer = bits.cursor.BitWriter.init(&storage);
    try writer.writeBits(@as(u3, 0b101), 3);
    try writer.writeBits(@as(u5, 0b10010), 5);

    var reader = bits.cursor.BitReader.init(&storage);
    const first = try reader.readBits(u3, 3);
    const second = try reader.readBits(u5, 5);
    assert(first == 0b101);
    assert(second == 0b10010);
}
