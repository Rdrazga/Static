const static_ecs = @import("static_ecs");

comptime {
    _ = static_ecs.Entity;
}

const Position = struct { x: f32, y: f32 };
const Buffer = static_ecs.CommandBuffer(.{ Position });

comptime {
    var buffer: Buffer = undefined;
    buffer.stageRemove(.{ .index = 0, .generation = 1 }, u32) catch unreachable;
}

pub export const sentinel: usize = @sizeOf(Buffer);
