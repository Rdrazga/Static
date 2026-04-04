const std = @import("std");
const math = @import("static_math");

const tolerance: f32 = 1.0e-4;

fn assertVec3Approx(actual: math.Vec3, expected: math.Vec3) void {
    std.debug.assert(math.Vec3.approxEqual(actual, expected, tolerance));
}

pub fn main() void {
    // Keep the example to exact TRS so `Transform.fromMat4` can recover the
    // decomposed representation without losing information to shear.
    const local_to_world = math.Transform.init(
        math.Vec3.init(3.0, -2.0, 5.0),
        math.Quat.fromAxisAngle(math.Vec3.unit_y, math.toRadians(90.0)),
        math.Vec3.init(2.0, 1.5, 0.5),
    );

    const local_point = math.Vec3.init(1.0, 0.0, -2.0);
    const matrix = math.Transform.toMat4(local_to_world);
    const world_point_transform = math.Transform.transformPoint(local_to_world, local_point);
    const world_point_matrix = math.Mat4.transformPoint(matrix, local_point);

    // `Transform` stores SRT, and `toMat4` applies the same SRT convention as
    // the matrix layer: `T * R * S`.
    assertVec3Approx(world_point_transform, world_point_matrix);

    const recovered = math.Transform.fromMat4(matrix) orelse unreachable;
    assertVec3Approx(recovered.translation, local_to_world.translation);
    assertVec3Approx(recovered.scale, local_to_world.scale);
    std.debug.assert(math.Quat.approxEqual(
        recovered.rotation,
        local_to_world.rotation,
        tolerance,
    ));

    const roundtrip_point = math.Transform.transformPoint(recovered, local_point);
    assertVec3Approx(roundtrip_point, world_point_transform);
}
