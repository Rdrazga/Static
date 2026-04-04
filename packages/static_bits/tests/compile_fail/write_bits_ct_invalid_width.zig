const bits = @import("static_bits");

comptime {
    var bytes = [_]u8{0} ** 2;
    var writer = bits.cursor.BitWriter.init(&bytes);
    writer.writeBitsCt(@as(u8, 0xFF), 9) catch unreachable;
}
