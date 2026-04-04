const std = @import("std");
const strings = @import("static_string");

pub fn main() !void {
    var storage: [64]u8 = undefined;
    var buffer = strings.BoundedBuffer.init(storage[0..]);

    try buffer.append("frame=");
    try buffer.appendFmt("{d}", .{120});
    try buffer.append(" status=ok");

    std.debug.print("{s}\n", .{buffer.bytes()});
}
