const bits = @import("static_bits");

comptime {
    const bytes = [_]u8{ 0xFF, 0x00 };
    var reader = bits.cursor.BitReader.init(&bytes);
    _ = reader.readBitsCt(u8, 9) catch unreachable;
}
