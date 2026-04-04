const std = @import("std");
const rng = @import("static_rng");

pub fn main() !void {
    var engine = rng.Pcg32.init(100, 3);
    var values = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    std.debug.print("before: {any}\n", .{values});
    try rng.shuffleSlice(&engine, values[0..]);
    std.debug.print("after:  {any}\n", .{values});
}
