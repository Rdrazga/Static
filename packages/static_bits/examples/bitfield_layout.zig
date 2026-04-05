//! Demonstrates packing and unpacking two fields inside a single integer.

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("static_bits");

pub fn main() !void {
    const packed_value = try bits.bitfield.pack2Ct(u16, 0b101, 3, 0x12, 5);
    const fields = bits.bitfield.unpack2Ct(u16, packed_value, 3, 5);
    assert(fields.low == 0b101);
    assert(fields.high == 0x12);

    const inserted = try bits.bitfield.insertBitsCt(u16, packed_value, 0b11, 8, 2);
    const extracted = bits.bitfield.extractBitsCt(u16, inserted, 8, 2);
    assert(extracted == 0b11);
}
