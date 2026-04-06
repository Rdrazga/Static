const testing = @import("std").testing;
const static_ecs = @import("static_ecs");

test "world archetype store preserves overlapping columns across transitions" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const World = static_ecs.World(.{ Position, Velocity });

    var world = try World.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 4,
        .chunk_rows_max = 4,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    const entity = try world.spawn();

    try world.insert(entity, Position{ .x = 4, .y = 8 });
    try world.insert(entity, Velocity{ .x = 9, .y = 10 });

    try testing.expectEqual(@as(f32, 4), world.componentPtrConst(entity, Position).?.x);
    try testing.expectEqual(@as(f32, 8), world.componentPtrConst(entity, Position).?.y);
    try testing.expect(world.componentPtr(entity, Velocity) != null);
    try testing.expectEqual(@as(u32, 2), world.archetypeKeyOf(entity).?.count());
    try testing.expectEqual(@as(f32, 9), world.componentPtrConst(entity, Velocity).?.x);
}
