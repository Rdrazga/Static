const std = @import("std");
const strings = @import("static_string");

pub fn main() !void {
    var entry_storage: [8]strings.Entry = undefined;
    var byte_storage: [64]u8 = undefined;
    var pool = try strings.InternPool.init(entry_storage[0..], byte_storage[0..]);

    const a = try pool.intern("alpha");
    const b = try pool.intern("beta");
    const c = try pool.intern("alpha");

    std.debug.print("symbols: alpha={d}, beta={d}, alpha_dup={d}\n", .{ a, b, c });
    std.debug.print("resolve beta: {s}\n", .{try pool.resolve(b)});
}
