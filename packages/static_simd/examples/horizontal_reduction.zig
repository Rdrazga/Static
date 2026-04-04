const std = @import("std");
const simd = @import("static_simd");

pub fn main() !void {
    const v = simd.vec4f.Vec4f.init([4]f32{ 3.0, 1.0, 4.0, 1.5 });

    const s = simd.horizontal.sum(v);
    const mn = simd.horizontal.min(v);
    const mx = simd.horizontal.max(v);

    std.debug.print("sum={d}, min={d}, max={d}\n", .{ s, mn, mx });
    std.debug.print("min at lane {d}, max at lane {d}\n", .{
        simd.horizontal.minIndex(v),
        simd.horizontal.maxIndex(v),
    });
}
