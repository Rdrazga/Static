const testing = @import("std").testing;
const static_ecs = @import("static_ecs");

test "query view supports with and exclude filters over chunk batches" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Tag = struct {};
    const Sleeping = struct {};
    const World = static_ecs.World(.{ Position, Velocity, Tag, Sleeping });

    var world = try World.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 6,
        .components_per_archetype_max = 4,
        .chunks_max = 8,
        .chunk_rows_max = 2,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer world.deinit();

    const first = try world.spawn();
    const second = try world.spawn();
    const third = try world.spawn();

    try world.insert(first, Position{ .x = 1, .y = 2 });
    try world.insert(first, Tag{});
    try world.insert(second, Position{ .x = 3, .y = 4 });
    try world.insert(second, Tag{});
    try world.insert(second, Sleeping{});
    try world.insert(third, Position{ .x = 5, .y = 6 });

    var view = world.view(.{
        static_ecs.Write(Position),
        static_ecs.With(Tag),
        static_ecs.Exclude(Sleeping),
    });
    var it = view.iterator();

    const batch = it.next().?;
    try testing.expectEqual(@as(usize, 1), batch.len());
    try testing.expectEqual(first, batch.entities()[0]);
    var mutable_batch = batch;
    try testing.expectEqual(@as(f32, 1), mutable_batch.write(Position)[0].x);
    try testing.expect(it.next() == null);
}
