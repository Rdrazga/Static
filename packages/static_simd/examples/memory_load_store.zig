const std = @import("std");
const simd = @import("static_simd");

pub fn main() !void {
    var data = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };

    // Load 4 floats from the slice, multiply by 2, store back.
    const v = try simd.memory.load4f(&data);
    const doubled = simd.vec4f.Vec4f.mul(v, simd.vec4f.Vec4f.splat(2.0));
    try simd.memory.store4f(data[0..4], doubled);

    std.debug.print("First four doubled: {d} {d} {d} {d}\n", .{
        data[0], data[1], data[2], data[3],
    });
}
