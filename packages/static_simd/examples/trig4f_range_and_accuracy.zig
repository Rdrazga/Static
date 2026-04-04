const std = @import("std");
const simd = @import("static_simd");

const tolerance: f32 = 2.0e-6;

pub fn main() void {
    const angles = simd.vec4f.Vec4f.init(.{
        0.0,
        std.math.pi / 6.0,
        std.math.pi / 4.0,
        std.math.pi / 3.0,
    });
    const sincos = simd.trig.sincos4f(angles);
    const tan_values = simd.trig.tan4f(angles).toArray();
    const sin_values = sincos.sin.toArray();
    const cos_values = sincos.cos.toArray();

    // The SIMD trig module is intentionally narrow: Vec4f-only approximations
    // with a documented valid input range rather than a broad generic trig layer.
    std.debug.assert(@abs(sin_values[1] - 0.5) <= tolerance);
    std.debug.assert(@abs(cos_values[2] - (@sqrt(@as(f32, 2.0)) * 0.5)) <= tolerance);
    std.debug.assert(@abs(tan_values[3] - 1.7320508) <= 3.0e-6);

    const scalar_sin = simd.trig.sin_scalar(std.math.pi / 6.0);
    std.debug.assert(@abs(scalar_sin - sin_values[1]) <= tolerance);
}
