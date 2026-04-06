const static_ecs = @import("static_ecs");

comptime {
    _ = static_ecs.Entity;
}

const Position = struct { x: f32, y: f32 };
const Key = static_ecs.ArchetypeKey(.{ Position });
const key = Key.fromTypes(.{ Position, Position });

pub export const sentinel: u32 = key.count();
