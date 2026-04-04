const bits = @import("static_bits");

comptime {
    const bytes = [_]u8{0x01};
    _ = bits.endian.readIntAt(u16, &bytes, 0, .little);
}
