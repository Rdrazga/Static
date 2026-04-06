const testing = @import("std").testing;
const static_ecs = @import("static_ecs");

test "typed world keeps bounded identity semantics stable through reuse" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const TestWorld = static_ecs.World(.{ Position, Velocity });

    var world = try TestWorld.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 2,
        .chunk_rows_max = 4,
        .command_buffer_entries_max = 4,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    const first = try world.spawn();
    const second = try world.spawn();
    try testing.expect(first.index != second.index);
    try testing.expectEqual(@as(u32, 2), world.entityCount());

    try world.despawn(first);
    try testing.expect(!world.contains(first));
    try testing.expectEqual(@as(u32, 1), world.entityCount());

    const reused = try world.spawn();
    try testing.expectEqual(first.index, reused.index);
    try testing.expect(reused.generation != first.generation);
    try testing.expect(world.contains(reused));
}
