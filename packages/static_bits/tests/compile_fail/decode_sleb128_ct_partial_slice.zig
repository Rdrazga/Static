const bits = @import("static_bits");

comptime {
    const bytes = [_]u8{ 0x7F, 0x00 };
    _ = bits.varint.decodeSleb128Ct(&bytes);
}
