const testing = @import("std").testing;
const static_ecs = @import("static_ecs");

test "archetype key and chunk preserve typed subset semantics" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Tag = struct {};

    const Key = static_ecs.ArchetypeKey(.{ Position, Velocity, Tag });
    const TestChunk = static_ecs.Chunk(.{ Position, Velocity, Tag });

    const key = Key.fromTypes(.{ Position, Tag });
    var chunk = try TestChunk.init(testing.allocator, key, 4, null);
    defer chunk.deinit();

    try chunk.setRowCount(2);
    try testing.expectEqual(@as(u32, 2), chunk.rowCount());
    try testing.expect(key.containsType(Position));
    try testing.expect(!key.containsType(Velocity));
    try testing.expect(key.containsType(Tag));

    const position_column = chunk.columnSlice(Position).?;
    try testing.expectEqual(@as(usize, 2), position_column.len);
    try testing.expect(chunk.columnSlice(Velocity) == null);
    try testing.expect(chunk.columnSlice(Tag) == null);

    const tag_layout = chunk.columnLayout(Tag);
    try testing.expect(tag_layout.present);
    try testing.expect(!tag_layout.materialized);
    try testing.expectEqual(@as(u32, 0), tag_layout.stride);
}
