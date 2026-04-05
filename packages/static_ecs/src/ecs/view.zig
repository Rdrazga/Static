const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const entity_mod = @import("entity.zig");
const archetype_key_mod = @import("archetype_key.zig");
const archetype_store_mod = @import("archetype_store.zig");
const chunk_mod = @import("chunk.zig");
const query_mod = @import("query.zig");

pub fn View(comptime Components: anytype, comptime Accesses: anytype) type {
    const QueryShape = query_mod.Query(Components, Accesses);
    const ArchetypeStore = archetype_store_mod.ArchetypeStore(Components);
    const Key = archetype_key_mod.ArchetypeKey(Components);
    const Chunk = chunk_mod.Chunk(Components);

    return struct {
        const Self = @This();

        pub const Query = QueryShape;

        pub const ChunkBatch = struct {
            key: Key,
            entities_slice: []const entity_mod.Entity,
            chunk: *Chunk,

            pub fn len(self: *const ChunkBatch) usize {
                assert(self.entities_slice.len == self.chunk.rowCount());
                return self.entities_slice.len;
            }

            pub fn archetypeKey(self: *const ChunkBatch) Key {
                assert(self.len() == self.entities_slice.len);
                return self.key;
            }

            pub fn entities(self: *const ChunkBatch) []const entity_mod.Entity {
                assert(self.entities_slice.len == self.chunk.rowCount());
                return self.entities_slice;
            }

            pub fn read(self: *const ChunkBatch, comptime T: type) []const T {
                comptime {
                    if (!QueryShape.allowsRead(T) and !QueryShape.allowsWrite(T)) {
                        @compileError("ChunkBatch.read requires a Read or Write access descriptor for T.");
                    }
                }
                const slice = self.chunk.columnSliceConst(T).?;
                assert(slice.len == self.entities_slice.len);
                return slice;
            }

            pub fn write(self: *ChunkBatch, comptime T: type) []T {
                comptime {
                    if (!QueryShape.allowsWrite(T)) {
                        @compileError("ChunkBatch.write requires a Write access descriptor for T.");
                    }
                }
                const slice = self.chunk.columnSlice(T).?;
                assert(slice.len == self.entities_slice.len);
                return slice;
            }

            pub fn optionalRead(self: *const ChunkBatch, comptime T: type) ?[]const T {
                comptime {
                    if (!QueryShape.allowsOptionalRead(T) and !QueryShape.allowsOptionalWrite(T)) {
                        @compileError("ChunkBatch.optionalRead requires an OptionalRead or OptionalWrite access descriptor for T.");
                    }
                }
                const slice = self.chunk.columnSliceConst(T) orelse return null;
                assert(slice.len == self.entities_slice.len);
                return slice;
            }

            pub fn optionalWrite(self: *ChunkBatch, comptime T: type) ?[]T {
                comptime {
                    if (!QueryShape.allowsOptionalWrite(T)) {
                        @compileError("ChunkBatch.optionalWrite requires an OptionalWrite access descriptor for T.");
                    }
                }
                const slice = self.chunk.columnSlice(T) orelse return null;
                assert(slice.len == self.entities_slice.len);
                return slice;
            }
        };

        pub const Iterator = struct {
            store: *ArchetypeStore,
            archetype_index: usize = 0,
            chunk_index: usize = 0,

            pub fn next(self: *Iterator) ?ChunkBatch {
                while (self.archetype_index < self.store.archetypes.len()) {
                    const archetype = &self.store.archetypes.items()[self.archetype_index];
                    if (!QueryShape.matches(archetype.key)) {
                        self.archetype_index += 1;
                        self.chunk_index = 0;
                        continue;
                    }

                    while (self.chunk_index < archetype.chunks.len()) {
                        const current_chunk_index = self.chunk_index;
                        self.chunk_index += 1;

                        const chunk_record = &archetype.chunks.items()[current_chunk_index];
                        const row_count: usize = chunk_record.chunk.rowCount();
                        if (row_count == 0) continue;

                        return .{
                            .key = archetype.key,
                            .entities_slice = chunk_record.entities[0..row_count],
                            .chunk = &chunk_record.chunk,
                        };
                    }

                    self.archetype_index += 1;
                    self.chunk_index = 0;
                }

                return null;
            }
        };

        store: *ArchetypeStore,

        pub fn init(store: *ArchetypeStore) Self {
            const self: Self = .{ .store = store };
            assert(@intFromPtr(self.store) != 0);
            return self;
        }

        pub fn iterator(self: *Self) Iterator {
            assert(@intFromPtr(self.store) != 0);
            return .{ .store = self.store };
        }
    };
}

test "view iterates matching chunks and exposes typed slices" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Health = struct { value: i32 };
    const Tag = struct {};
    const Store = archetype_store_mod.ArchetypeStore(.{ Position, Velocity, Health, Tag });
    const TestView = View(
        .{ Position, Velocity, Health, Tag },
        .{
            query_mod.Write(Position),
            query_mod.Read(Velocity),
            query_mod.OptionalRead(Health),
            query_mod.Exclude(Tag),
        },
    );
    var store = try Store.init(testing.allocator, .{
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
    defer store.deinit();

    const first: entity_mod.Entity = .{ .index = 0, .generation = 1 };
    const second: entity_mod.Entity = .{ .index = 1, .generation = 1 };
    const third: entity_mod.Entity = .{ .index = 2, .generation = 1 };
    const fourth: entity_mod.Entity = .{ .index = 3, .generation = 1 };

    try store.spawn(first);
    try store.spawn(second);
    try store.spawn(third);
    try store.spawn(fourth);
    try store.insertComponent(first, Position, .{ .x = 1, .y = 2 });
    try store.insertComponent(first, Velocity, .{ .x = 10, .y = 20 });
    try store.insertComponent(second, Position, .{ .x = 3, .y = 4 });
    try store.insertComponent(second, Velocity, .{ .x = 30, .y = 40 });
    try store.insertComponent(third, Position, .{ .x = 5, .y = 6 });
    try store.insertComponent(third, Velocity, .{ .x = 50, .y = 60 });
    try store.insertComponent(third, Health, .{ .value = 99 });
    try store.insertComponent(fourth, Position, .{ .x = 7, .y = 8 });
    try store.insertComponent(fourth, Velocity, .{ .x = 70, .y = 80 });
    try store.insertComponent(fourth, Tag, .{});

    var view = TestView.init(&store);
    var it = view.iterator();

    const first_batch = it.next().?;
    try testing.expectEqual(@as(usize, 2), first_batch.len());
    try testing.expectEqualSlices(entity_mod.Entity, &.{ first, second }, first_batch.entities());
    try testing.expect(first_batch.optionalRead(Health) == null);

    var mutable_first_batch = first_batch;
    const positions = mutable_first_batch.write(Position);
    positions[0].x += 100;
    try testing.expectEqual(@as(f32, 101), store.componentPtrConst(first, Position).?.x);
    try testing.expectEqual(@as(f32, 30), first_batch.read(Velocity)[1].x);

    const second_batch = it.next().?;
    try testing.expectEqual(@as(usize, 1), second_batch.len());
    try testing.expectEqualSlices(entity_mod.Entity, &.{third}, second_batch.entities());
    const second_health = second_batch.optionalRead(Health).?;
    try testing.expectEqual(@as(i32, 99), second_health[0].value);
    try testing.expect(it.next() == null);
}
