const std = @import("std");
const hash = @import("static_hash");

pub fn main() !void {
    // Hash a struct generically.
    const Point = struct { x: u32, y: u32 };
    const p = Point{ .x = 10, .y = 20 };
    const h = hash.hashAny(p);
    std.debug.print("hashAny(Point{{ .x=10, .y=20 }}) = 0x{x}\n", .{h});

    // Hash a tuple.
    const t = hash.hashTuple(.{ @as(u32, 1), @as(u32, 2), @as(u32, 3) });
    std.debug.print("hashTuple(.{{ 1, 2, 3 }}) = 0x{x}\n", .{t});
}
