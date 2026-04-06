const static_ecs = @import("static_ecs");

comptime {
    _ = static_ecs.Entity;
}

const Registry = static_ecs.ComponentRegistry(.{ u32, 1 });

pub export const sentinel: u32 = Registry.count();
