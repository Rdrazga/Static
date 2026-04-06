const testing = @import("std").testing;
const static_ecs = @import("static_ecs");

test "command buffer applies hot-path staged structural work after chunk iteration" {
    const Position = struct { x: f32, y: f32 };
    const Tag = struct {};
    const World = static_ecs.World(.{ Position, Tag });

    var world = try World.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 6,
        .components_per_archetype_max = 4,
        .chunks_max = 8,
        .chunk_rows_max = 2,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    var command_buffer = try world.initCommandBuffer(testing.allocator);
    defer command_buffer.deinit();

    const first = try world.spawn();
    const second = try world.spawn();
    try world.insert(first, Position{ .x = 1, .y = 2 });
    try world.insert(second, Position{ .x = 3, .y = 4 });

    var view = world.view(.{
        static_ecs.Write(Position),
    });
    var it = view.iterator();
    while (it.next()) |batch| {
        for (batch.entities(), batch.read(Position)) |entity, position| {
            if (position.x == 1) {
                try command_buffer.stageInsert(entity, Tag{});
            } else {
                try command_buffer.stageDespawn(entity);
            }
        }
    }
    try command_buffer.stageSpawn();

    var spawned: [1]static_ecs.Entity = undefined;
    const result = try command_buffer.apply(&world, spawned[0..]);

    try testing.expectEqual(@as(u32, 3), result.commands_applied);
    try testing.expectEqual(@as(u32, 1), result.spawned_count);
    try testing.expect(world.contains(first));
    try testing.expect(world.hasComponent(first, Tag));
    try testing.expect(!world.contains(second));
    try testing.expect(world.contains(spawned[0]));
}
