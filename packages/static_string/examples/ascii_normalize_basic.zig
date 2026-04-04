const std = @import("std");
const strings = @import("static_string");

pub fn main() !void {
    const raw_header = " \tCONTENT-TYPE \r\n";

    var buffer_storage: [32]u8 = undefined;
    var buffer = strings.BoundedBuffer.init(buffer_storage[0..]);
    try buffer.append(strings.ascii.trimWhitespace(raw_header));

    const used_len = buffer.len();
    std.debug.assert(used_len > 0);
    std.debug.assert(strings.ascii.isAscii(buffer.bytes()));

    // ASCII helpers are byte-level normalization steps that feed the package's
    // bounded storage and deterministic interning story.
    strings.ascii.toLowerInPlace(buffer_storage[0..used_len]);
    const normalized = buffer.bytes();
    std.debug.assert(strings.ascii.eqIgnoreCase(normalized, "CONTENT-TYPE"));
    std.debug.assert(std.mem.eql(u8, normalized, "content-type"));

    var entry_storage: [4]strings.Entry = undefined;
    var byte_storage: [32]u8 = undefined;
    var pool = try strings.InternPool.init(entry_storage[0..], byte_storage[0..]);

    const symbol = try pool.intern(normalized);
    const resolved = try pool.resolve(symbol);
    std.debug.assert(std.mem.eql(u8, normalized, resolved));

    std.debug.print("normalized ascii symbol={d} text={s}\n", .{ symbol, resolved });
}
