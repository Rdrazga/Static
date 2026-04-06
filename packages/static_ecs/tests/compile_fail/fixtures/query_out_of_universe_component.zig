const static_ecs = @import("static_ecs");

comptime {
    _ = static_ecs.Entity;
}

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const TestQuery = static_ecs.Query(.{ Position }, .{
    static_ecs.Read(Velocity),
});

pub export const sentinel: usize = @sizeOf(TestQuery);
