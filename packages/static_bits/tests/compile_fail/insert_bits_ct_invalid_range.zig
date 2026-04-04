const bits = @import("static_bits");

comptime {
    _ = bits.bitfield.insertBitsCt(u8, 0x00, 0x01, 7, 2) catch unreachable;
}
