const std = @import("std");
const strings = @import("static_string");

pub fn main() !void {
    const valid_name = "caf\xc3\xa9";
    const invalid_name = "\xc3\x28";

    // UTF-8 validation is the package's admission check before bounded storage
    // or interning accepts external byte data as text.
    std.debug.assert(strings.utf8.isValid(valid_name));
    try strings.utf8.validate(valid_name);

    if (strings.utf8.validate(invalid_name)) |_| {
        unreachable;
    } else |err| {
        std.debug.assert(err == error.InvalidInput);
    }

    var entry_storage: [4]strings.Entry = undefined;
    var byte_storage: [32]u8 = undefined;
    var pool = try strings.InternPool.init(entry_storage[0..], byte_storage[0..]);

    const symbol = try pool.intern(valid_name);
    const resolved = try pool.resolve(symbol);
    std.debug.assert(std.mem.eql(u8, valid_name, resolved));

    std.debug.print("validated utf8 symbol={d} text={s}\n", .{ symbol, resolved });
}
