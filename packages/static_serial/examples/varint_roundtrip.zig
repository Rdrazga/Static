const std = @import("std");
const serial = @import("static_serial");

pub fn main() !void {
    var buf = [_]u8{0} ** 16;
    var w = serial.writer.Writer.init(&buf);
    try w.writeVarint(@as(u32, 300));

    var r = serial.reader.Reader.init(buf[0..w.position()]);
    _ = try r.readVarint(u32);
    _ = std;
}
