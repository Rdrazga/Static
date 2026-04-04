const bits = @import("static_bits");

comptime {
    var bytes = [_]u8{0x01};
    bits.endian.writeIntAt(&bytes, 0, @as(u16, 0x1234), .little);
}
