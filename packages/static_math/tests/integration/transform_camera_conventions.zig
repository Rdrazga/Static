const std = @import("std");
const math = @import("static_math");

const tolerance: f32 = 1.0e-4;

fn assertVec3Approx(actual: math.Vec3, expected: math.Vec3) void {
    std.debug.assert(math.Vec3.approxEqual(actual, expected, tolerance));
}

test "Transform.lookAt and Mat4.lookAt agree on right-handed -Z-forward camera conventions" {
    const eye = math.Vec3.init(3.0, 2.0, 5.0);
    const target = math.Vec3.init(3.0, 2.0, 1.0);
    const up_dir = math.Vec3.unit_y;

    const camera_world = math.Transform.lookAt(
        math.Transform.fromTranslation(eye),
        target,
        up_dir,
    );
    const expected_forward = math.Vec3.normalize(math.Vec3.sub(target, eye));

    std.debug.assert(math.Vec3.approxEqual(
        math.Transform.forward(camera_world),
        expected_forward,
        tolerance,
    ));
    std.debug.assert(math.Vec3.approxEqual(
        math.Quat.forward(camera_world.rotation),
        expected_forward,
        tolerance,
    ));

    const view = math.Mat4.lookAt(eye, target, up_dir);
    const view_from_transform = math.Transform.inverseMat4(camera_world);
    std.debug.assert(math.Mat4.approxEqual(view, view_from_transform, tolerance));

    const eye_in_view = math.Mat4.transformPoint(view, eye);
    assertVec3Approx(eye_in_view, math.Vec3.zero);

    const target_in_view = math.Mat4.transformPoint(view, target);
    std.debug.assert(@abs(target_in_view.x) <= tolerance);
    std.debug.assert(@abs(target_in_view.y) <= tolerance);
    std.debug.assert(target_in_view.z < 0.0);
}

test "Transform.toMat4 transformPoint and fromMat4 roundtrip exact TRS" {
    const local_to_world = math.Transform.init(
        math.Vec3.init(3.0, -2.0, 5.0),
        math.Quat.fromAxisAngle(math.Vec3.unit_y, math.toRadians(90.0)),
        math.Vec3.init(2.0, 1.5, 0.5),
    );

    const local_point = math.Vec3.init(1.0, 0.0, -2.0);
    const matrix = math.Transform.toMat4(local_to_world);
    const world_point_transform = math.Transform.transformPoint(local_to_world, local_point);
    const world_point_matrix = math.Mat4.transformPoint(matrix, local_point);
    assertVec3Approx(world_point_transform, world_point_matrix);

    const recovered = math.Transform.fromMat4(matrix) orelse unreachable;
    assertVec3Approx(recovered.translation, local_to_world.translation);
    assertVec3Approx(recovered.scale, local_to_world.scale);
    std.debug.assert(math.Quat.approxEqual(
        recovered.rotation,
        local_to_world.rotation,
        tolerance,
    ));

    const recovered_matrix = math.Transform.toMat4(recovered);
    std.debug.assert(math.Mat4.approxEqual(matrix, recovered_matrix, tolerance));

    const roundtrip_point = math.Transform.transformPoint(recovered, local_point);
    assertVec3Approx(roundtrip_point, world_point_transform);
}
