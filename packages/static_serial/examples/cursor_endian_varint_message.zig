const std = @import("std");
const serial = @import("static_serial");

pub fn main() !void {
    var frame_bytes: [32]u8 = [_]u8{0} ** 32;
    var writer = serial.writer.Writer.init(&frame_bytes);

    // Encode the frame through the structured serial layer so callers do not
    // need to coordinate cursor movement, endian helpers, and varint details manually.
    try writer.writeInt(@as(u16, 0xCAFE), .big);
    try writer.writeVarint(@as(u32, 5));
    try writer.writeInt(@as(u32, 0x01020304), .little);
    try writer.writeBytes("hello");

    const frame_len = writer.position();
    std.debug.assert(frame_len == 13);

    var reader = serial.reader.Reader.init(frame_bytes[0..frame_len]);
    const message_kind = try reader.readInt(u16, .big);
    const payload_len = try reader.readVarint(u32);
    const sequence_id = try reader.readInt(u32, .little);
    const payload = try reader.readBytes(payload_len);

    std.debug.assert(message_kind == 0xCAFE);
    std.debug.assert(payload_len == 5);
    std.debug.assert(sequence_id == 0x01020304);
    std.debug.assert(std.mem.eql(u8, payload, "hello"));
    std.debug.assert(reader.position() == frame_len);
}
