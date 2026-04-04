//! Demonstrates writing bytes into an in-memory buffer using `cursor.ByteWriter`.

const std = @import("std");
const bits = @import("static_bits");

pub fn main() !void {
    var buf = [_]u8{0} ** 3;
    var writer = bits.cursor.ByteWriter.init(&buf);
    try writer.writeByte('x');
    std.debug.assert(buf[0] == 'x');
    std.debug.assert(writer.position() == 1);
}
