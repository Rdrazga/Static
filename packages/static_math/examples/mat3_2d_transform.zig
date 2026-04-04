const std = @import("std");
const math = @import("static_math");

const tolerance: f32 = 1.0e-4;

fn assertVec2Approx(actual: math.Vec2, expected: math.Vec2) void {
    std.debug.assert(math.Vec2.approxEqual(actual, expected, tolerance));
}

pub fn main() void {
    const local_to_world = math.Mat3.mul(
        math.Mat3.fromTranslation(math.Vec2.init(10.0, -4.0)),
        math.Mat3.mul(
            math.Mat3.fromRotation2D(math.toRadians(90.0)),
            math.Mat3.fromScale(math.Vec2.init(2.0, 3.0)),
        ),
    );

    const local_point = math.Vec2.init(1.0, 2.0);
    const world_point = math.Mat3.transformPoint2(local_to_world, local_point);

    // In 2D homogeneous mode the same column-major convention applies:
    // `T * R * S` transforms points, while directions ignore translation.
    assertVec2Approx(world_point, math.Vec2.init(4.0, -2.0));

    const world_direction = math.Mat3.transformDir2(local_to_world, math.Vec2.unit_x);
    assertVec2Approx(world_direction, math.Vec2.init(0.0, 2.0));

    const world_to_local = math.Mat3.inverse(local_to_world) orelse unreachable;
    const roundtrip_point = math.Mat3.transformPoint2(world_to_local, world_point);
    assertVec2Approx(roundtrip_point, local_point);
}
