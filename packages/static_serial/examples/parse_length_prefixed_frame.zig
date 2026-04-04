const std = @import("std");
const serial = @import("static_serial");

pub fn main() !void {
    const payload = "ok";
    var buf = [_]u8{0} ** 16;
    var w = serial.writer.Writer.init(&buf);
    try w.writeVarint(@as(u8, payload.len));
    try w.writeBytes(payload);

    var r = serial.reader.Reader.init(buf[0..w.position()]);
    const len = try r.readVarint(u8);
    _ = try r.readBytes(len);
    _ = std;
}
