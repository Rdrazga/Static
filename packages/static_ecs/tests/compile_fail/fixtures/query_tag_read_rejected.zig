const static_ecs = @import("static_ecs");

comptime {
    _ = static_ecs.Entity;
}

const Tag = struct {};
const TestQuery = static_ecs.Query(.{ Tag }, .{
    static_ecs.Read(Tag),
});

pub export const sentinel: usize = @sizeOf(TestQuery);
