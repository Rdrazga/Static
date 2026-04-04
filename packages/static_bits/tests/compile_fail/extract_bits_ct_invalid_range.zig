const bits = @import("static_bits");

comptime {
    _ = bits.bitfield.extractBitsCt(u8, 0xFF, 7, 2);
}
