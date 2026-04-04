const bits = @import("static_bits");

comptime {
    const bytes = [_]u8{ 0xAC, 0x02, 0x00 };
    _ = bits.varint.decodeUleb128Ct(&bytes);
}
