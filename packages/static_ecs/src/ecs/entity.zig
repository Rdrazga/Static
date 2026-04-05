const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const handle_mod = @import("static_collections").handle;

pub const Entity = packed struct {
    index: u32,
    generation: u32,

    comptime {
        assert(@sizeOf(Entity) == 8);
        assert(@bitSizeOf(Entity) == 64);
    }

    pub fn invalid() Entity {
        const entity: Entity = .{
            .index = std.math.maxInt(u32),
            .generation = 0,
        };
        assert(entity.index == std.math.maxInt(u32));
        assert(!entity.isValid());
        return entity;
    }

    pub fn isValid(self: Entity) bool {
        const generation_valid = self.generation != 0;
        const index_valid = self.index != std.math.maxInt(u32);
        return generation_valid and index_valid;
    }

    pub fn fromHandle(handle: handle_mod.Handle) Entity {
        const entity: Entity = .{
            .index = handle.index,
            .generation = handle.generation,
        };
        if (handle.isValid()) assert(entity.isValid());
        if (!handle.isValid()) assert(!entity.isValid());
        return entity;
    }

    pub fn toHandle(self: Entity) handle_mod.Handle {
        const handle: handle_mod.Handle = .{
            .index = self.index,
            .generation = self.generation,
        };
        if (self.isValid()) assert(handle.isValid());
        if (!self.isValid()) assert(!handle.isValid());
        return handle;
    }
};

test "entity invalid sentinel and validity mirror handle semantics" {
    const invalid = Entity.invalid();
    try testing.expect(!invalid.isValid());
    try testing.expect(!invalid.toHandle().isValid());

    const valid: Entity = .{ .index = 7, .generation = 3 };
    try testing.expect(valid.isValid());
    try testing.expect(valid.toHandle().isValid());
}

test "entity converts to and from collection handles" {
    const handle: handle_mod.Handle = .{ .index = 11, .generation = 5 };
    const entity = Entity.fromHandle(handle);

    try testing.expect(entity.isValid());
    try testing.expectEqual(handle.index, entity.index);
    try testing.expectEqual(handle.generation, entity.generation);
    try testing.expectEqual(handle, entity.toHandle());
}
