//! Demonstrates fixed-layout endian access with compile-time-validated offsets.

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("static_bits");

pub fn main() !void {
    var header = [_]u8{ 0x34, 0x12, 0x00, 0x00, 0x78, 0x56 };
    const message_type = bits.endian.readIntAt(u16, &header, 0, .little);
    const payload_len = bits.endian.readIntAt(u16, &header, 4, .little);
    assert(message_type == 0x1234);
    assert(payload_len == 0x5678);

    bits.endian.writeIntAt(&header, 2, @as(u16, 0xABCD), .big);
    assert(header[2] == 0xAB);
    assert(header[3] == 0xCD);
}
