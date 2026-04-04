const std = @import("std");
const math = @import("static_math");

const tolerance: f32 = 1.0e-4;

fn assertVec3Approx(actual: math.Vec3, expected: math.Vec3) void {
    std.debug.assert(math.Vec3.approxEqual(actual, expected, tolerance));
}

pub fn main() void {
    const eye = math.Vec3.init(3.0, 2.0, 5.0);
    const target = math.Vec3.init(3.0, 2.0, 1.0);
    const up_dir = math.Vec3.unit_y;

    const camera_world = math.Transform.lookAt(
        math.Transform.fromTranslation(eye),
        target,
        up_dir,
    );
    const expected_forward = math.Vec3.normalize(math.Vec3.sub(target, eye));

    // The package uses a right-handed space with local `-Z` as forward, so a
    // look-at rotation makes `Transform.forward()` point toward the target.
    assertVec3Approx(math.Transform.forward(camera_world), expected_forward);
    assertVec3Approx(math.Quat.forward(camera_world.rotation), expected_forward);

    const view = math.Mat4.lookAt(eye, target, up_dir);
    const eye_in_view = math.Mat4.transformPoint(view, eye);
    assertVec3Approx(eye_in_view, math.Vec3.zero);

    const target_in_view = math.Mat4.transformPoint(view, target);
    std.debug.assert(@abs(target_in_view.x) <= tolerance);
    std.debug.assert(@abs(target_in_view.y) <= tolerance);
    std.debug.assert(target_in_view.z < 0.0);

    // For a camera transform with unit scale, the view matrix is the inverse
    // of the world transform built under the same `-Z` forward convention.
    const view_from_transform = math.Transform.inverseMat4(camera_world);
    std.debug.assert(math.Mat4.approxEqual(view, view_from_transform, tolerance));
}
