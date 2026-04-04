const std = @import("std");
const rng = @import("static_rng");

pub fn main() !void {
    var engine = rng.Pcg32.init(42, 7);

    var index: usize = 0;
    while (index < 5) : (index += 1) {
        std.debug.print("nextU32[{d}] = {d}\n", .{
            index,
            engine.nextU32(),
        });
    }
}
