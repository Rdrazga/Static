const std = @import("std");
const simd = @import("static_simd");

pub fn main() !void {
    const a = simd.vec4f.Vec4f.init([4]f32{ 1.0, 2.0, 3.0, 4.0 });
    const b = simd.vec4f.Vec4f.splat(0.5);
    const c = simd.vec4f.Vec4f.mul(a, b);
    const arr = c.toArray();
    std.debug.print("{d} {d} {d} {d}\n", .{ arr[0], arr[1], arr[2], arr[3] });
}
