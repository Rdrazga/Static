//! Demonstrates compile-time layout and varint helpers.

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("static_bits");

pub fn main() !void {
    const encoded = comptime bits.varint.encodeUleb128Ct(300);
    const decoded = comptime bits.varint.decodeUleb128Ct(&encoded);
    assert(decoded == 300);

    const flags = comptime bits.bitfield.extractBitsCt(u8, 0b1011_0000, 4, 3);
    assert(flags == 0b011);
    const packed_bits = comptime try bits.bitfield.insertBitsCt(u8, 0, 0b101, 1, 3);
    assert(packed_bits == 0b0000_1010);

    const layout = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    const value = comptime bits.endian.readIntAt(u32, &layout, 0, .little);
    assert(value == 0x12345678);
}
