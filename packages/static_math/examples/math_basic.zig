const std = @import("std");
const math = @import("static_math");

pub fn main() !void {
    // This example samples one primitive from each major family so new users
    // can confirm the package conventions quickly.
    // Vec3 cross product.
    const a = math.Vec3.init(1.0, 0.0, 0.0);
    const b = math.Vec3.init(0.0, 1.0, 0.0);
    const c = a.cross(b);
    std.debug.print("cross: ({d}, {d}, {d})\n", .{ c.x, c.y, c.z });

    // Mat4 perspective projection.
    const proj = math.Mat4.perspective(
        math.toRadians(60.0),
        16.0 / 9.0,
        0.1,
        100.0,
    );
    std.debug.print("proj col0.x: {d:.4}\n", .{proj.cols[0].x});

    // Quaternion forward direction.
    const q = math.Quat.fromAxisAngle(math.Vec3.init(0.0, 1.0, 0.0), math.pi / 2.0);
    const fwd = q.forward();
    std.debug.print("forward: ({d:.4}, {d:.4}, {d:.4})\n", .{
        fwd.x, fwd.y, fwd.z,
    });
}
