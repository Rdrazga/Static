const std = @import("std");
const serial = @import("static_serial");

pub fn main() !void {
    const payload = "frame";
    var buf = [_]u8{0} ** 8;
    var w = serial.writer.Writer.init(&buf);
    try serial.checksum.writeChecksum32(&w, payload);

    var r = serial.reader.Reader.init(buf[0..w.position()]);
    const expected = try r.readInt(u32, .little);
    try serial.checksum.verifyChecksum32(payload, expected);
    _ = std;
}
