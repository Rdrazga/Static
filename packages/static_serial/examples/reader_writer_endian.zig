const std = @import("std");
const serial = @import("static_serial");

pub fn main() !void {
    var buf = [_]u8{0} ** 8;
    var w = serial.writer.Writer.init(&buf);
    try w.writeInt(@as(u32, 0x11223344), .little);

    var r = serial.reader.Reader.init(buf[0..w.position()]);
    _ = try r.readInt(u32, .little);
    _ = std;
}
