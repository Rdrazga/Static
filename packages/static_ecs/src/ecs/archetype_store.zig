const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const memory = @import("static_memory");
const collections = @import("static_collections");
const world_config_mod = @import("world_config.zig");
const entity_mod = @import("entity.zig");
const component_registry_mod = @import("component_registry.zig");
const archetype_key_mod = @import("archetype_key.zig");
const chunk_mod = @import("chunk.zig");

pub fn ArchetypeStore(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const Key = archetype_key_mod.ArchetypeKey(Components);
    const Chunk = chunk_mod.Chunk(Components);
    const component_universe_count: usize = comptime Registry.count();

    return struct {
        const Self = @This();

        pub const Error = world_config_mod.Error || Chunk.Error || collections.vec.Error || error{
            AlreadyExists,
            ComponentInitRequired,
            EntityOutOfRange,
            EntityNotFound,
            EntitySlotOccupied,
        };

        pub const EntityLocation = struct {
            archetype_index: u32,
            chunk_index: u32,
            row_index: u32,
            occupied: bool,

            fn invalid() EntityLocation {
                const location: EntityLocation = .{
                    .archetype_index = invalid_index,
                    .chunk_index = invalid_index,
                    .row_index = invalid_index,
                    .occupied = false,
                };
                assert(!location.occupied);
                assert(location.archetype_index == invalid_index);
                return location;
            }
        };

        const invalid_index = std.math.maxInt(u32);

        const ChunkRecord = struct {
            chunk: Chunk,
            entities: []entity_mod.Entity,
            budget: ?*memory.budget.Budget,
            entity_reserved_bytes: usize,

            fn init(
                allocator: std.mem.Allocator,
                key: Key,
                rows_capacity: u32,
                budget: ?*memory.budget.Budget,
            ) Error!ChunkRecord {
                const entity_reserved_bytes = std.math.mul(usize, rows_capacity, @sizeOf(entity_mod.Entity)) catch
                    return error.Overflow;
                if (budget) |tracked_budget| {
                    try tracked_budget.tryReserve(entity_reserved_bytes);
                }
                errdefer if (budget) |tracked_budget| tracked_budget.release(entity_reserved_bytes);

                const entities = allocator.alloc(entity_mod.Entity, rows_capacity) catch return error.OutOfMemory;
                errdefer allocator.free(entities);

                const chunk = try Chunk.init(allocator, key, rows_capacity, budget);
                errdefer {
                    var cleanup_chunk = chunk;
                    cleanup_chunk.deinit();
                }

                const record: ChunkRecord = .{
                    .chunk = chunk,
                    .entities = entities,
                    .budget = budget,
                    .entity_reserved_bytes = entity_reserved_bytes,
                };
                assert(record.entities.len == rows_capacity);
                assert(record.chunk.capacity() == rows_capacity);
                return record;
            }

            fn deinit(self: *ChunkRecord, allocator: std.mem.Allocator) void {
                self.chunk.deinit();
                allocator.free(self.entities);
                if (self.budget) |tracked_budget| {
                    tracked_budget.release(self.entity_reserved_bytes);
                }
                self.* = undefined;
            }
        };

        const ChunkVec = collections.vec.Vec(ChunkRecord);

        const ArchetypeRecord = struct {
            key: Key,
            chunks: ChunkVec,

            fn init(allocator: std.mem.Allocator, key: Key, budget: ?*memory.budget.Budget) Error!ArchetypeRecord {
                var record: ArchetypeRecord = .{
                    .key = key,
                    .chunks = try ChunkVec.init(allocator, .{
                        .budget = budget,
                    }),
                };
                assert(record.chunks.len() == 0);
                return record;
            }

            fn deinit(self: *ArchetypeRecord, allocator: std.mem.Allocator) void {
                for (self.chunks.items()) |*chunk_record| {
                    chunk_record.deinit(allocator);
                }
                self.chunks.deinit();
                self.* = undefined;
            }
        };

        const ArchetypeVec = collections.vec.Vec(ArchetypeRecord);

        allocator: std.mem.Allocator,
        config: world_config_mod.WorldConfig,
        archetypes: ArchetypeVec,
        entity_locations: []EntityLocation,
        locations_reserved_bytes: usize,
        total_chunks: u32,
        active_entities: u32,

        pub fn init(allocator: std.mem.Allocator, config: world_config_mod.WorldConfig) Error!Self {
            try config.validate();
            if (Registry.count() > config.components_per_archetype_max) return error.InvalidConfig;

            const locations_reserved_bytes = std.math.mul(usize, config.entities_max, @sizeOf(EntityLocation)) catch
                return error.Overflow;
            if (config.budget) |budget| {
                try budget.tryReserve(locations_reserved_bytes);
            }
            errdefer if (config.budget) |budget| budget.release(locations_reserved_bytes);

            const entity_locations = allocator.alloc(EntityLocation, config.entities_max) catch return error.OutOfMemory;
            errdefer allocator.free(entity_locations);
            @memset(entity_locations, EntityLocation.invalid());

            var archetypes = try ArchetypeVec.init(allocator, .{
                .initial_capacity = 1,
                .budget = config.budget,
            });
            errdefer archetypes.deinit();

            const empty_record = try ArchetypeRecord.init(allocator, Key.empty(), config.budget);
            errdefer {
                var cleanup_record = empty_record;
                cleanup_record.deinit(allocator);
            }
            try archetypes.append(empty_record);

            var self: Self = .{
                .allocator = allocator,
                .config = config,
                .archetypes = archetypes,
                .entity_locations = entity_locations,
                .locations_reserved_bytes = locations_reserved_bytes,
                .total_chunks = 0,
                .active_entities = 0,
            };
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            for (self.archetypes.items()) |*archetype| {
                archetype.deinit(self.allocator);
            }
            self.archetypes.deinit();
            self.allocator.free(self.entity_locations);
            if (self.config.budget) |budget| {
                budget.release(self.locations_reserved_bytes);
            }
            self.* = undefined;
        }

        pub fn activeCount(self: *const Self) u32 {
            self.assertInvariants();
            assert(self.active_entities <= self.config.entities_max);
            return self.active_entities;
        }

        pub fn archetypeCount(self: *const Self) u32 {
            self.assertInvariants();
            assert(self.archetypes.len() <= self.config.archetypes_max);
            return @intCast(self.archetypes.len());
        }

        pub fn chunkCount(self: *const Self) u32 {
            self.assertInvariants();
            assert(self.total_chunks <= self.config.chunks_max);
            return self.total_chunks;
        }

        pub fn contains(self: *const Self, entity: entity_mod.Entity) bool {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return false;
            assert(location.occupied);
            return true;
        }

        pub fn locationOf(self: *const Self, entity: entity_mod.Entity) ?EntityLocation {
            self.assertInvariants();
            const location = self.locationRaw(entity) orelse return null;
            if (!location.occupied) return null;
            const chunk_record = self.chunkRecordConst(location) orelse return null;
            const row_index: usize = location.row_index;
            if (row_index >= chunk_record.entities.len) return null;
            if (location.row_index >= chunk_record.chunk.rowCount()) return null;
            if (!std.meta.eql(chunk_record.entities[row_index], entity)) return null;
            return location;
        }

        pub fn archetypeKeyOf(self: *const Self, entity: entity_mod.Entity) ?Key {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return null;
            const archetype = self.archetypeRecordConst(location.archetype_index).?;
            return archetype.key;
        }

        pub fn componentPtr(self: *Self, entity: entity_mod.Entity, comptime T: type) ?*T {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return null;
            var chunk_record = self.chunkRecord(location).?;
            const column = chunk_record.chunk.columnSlice(T) orelse return null;
            const row_index: usize = location.row_index;
            assert(row_index < column.len);
            return &column[row_index];
        }

        pub fn componentPtrConst(self: *const Self, entity: entity_mod.Entity, comptime T: type) ?*const T {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return null;
            const chunk_record = self.chunkRecordConst(location).?;
            const column = chunk_record.chunk.columnSliceConst(T) orelse return null;
            const row_index: usize = location.row_index;
            assert(row_index < column.len);
            return &column[row_index];
        }

        pub fn hasComponent(self: *const Self, entity: entity_mod.Entity, comptime T: type) bool {
            comptime validateComponentType(T, Registry);

            self.assertInvariants();
            const key = self.archetypeKeyOf(entity) orelse return false;
            return key.containsType(T);
        }

        pub fn spawn(self: *Self, entity: entity_mod.Entity) Error!void {
            self.assertInvariants();
            if (!entity.isValid()) return error.EntityOutOfRange;
            if (@as(usize, entity.index) >= self.entity_locations.len) return error.EntityOutOfRange;
            if (self.locationRaw(entity).?.occupied) {
                if (self.contains(entity)) return error.AlreadyExists;
                return error.EntitySlotOccupied;
            }
            if (self.contains(entity)) return error.AlreadyExists;

            const location = try self.appendEntityToArchetype(0, entity);
            self.writeLocation(entity, location);
            self.active_entities += 1;
            assert(self.contains(entity));
            self.assertInvariants();
        }

        pub fn despawn(self: *Self, entity: entity_mod.Entity) Error!void {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return error.EntityNotFound;
            try self.removeEntityAt(location, entity);
            self.clearLocation(entity);
            assert(self.active_entities > 0);
            self.active_entities -= 1;
            assert(!self.contains(entity));
            self.assertInvariants();
        }

        pub fn moveToArchetype(self: *Self, entity: entity_mod.Entity, target_key: Key) Error!void {
            self.assertInvariants();
            const source_location = self.locationOf(entity) orelse return error.EntityNotFound;
            const source_archetype = self.archetypeRecordConst(source_location.archetype_index).?;
            if (target_key.count() > self.config.components_per_archetype_max) return error.InvalidConfig;
            if (keysEqual(&source_archetype.key, &target_key)) {
                self.assertInvariants();
                return;
            }
            if (introducesUninitializedColumns(source_archetype.key, target_key)) {
                return error.ComponentInitRequired;
            }

            try self.moveEntityToArchetype(entity, target_key);
            assert(self.contains(entity));
            self.assertInvariants();
        }

        pub fn insertComponent(self: *Self, entity: entity_mod.Entity, comptime T: type, value: T) Error!void {
            comptime validateComponentType(T, Registry);

            self.assertInvariants();
            if (!self.contains(entity)) return error.EntityNotFound;

            if (!self.hasComponent(entity, T)) {
                const source_key = self.archetypeKeyOf(entity).?;
                const target_key = try source_key.withType(T);
                try self.moveEntityToArchetype(entity, target_key);
            }

            if (@sizeOf(T) != 0) {
                self.componentPtr(entity, T).?.* = value;
            }
            assert(self.hasComponent(entity, T));
            self.assertInvariants();
        }

        pub fn removeComponent(self: *Self, entity: entity_mod.Entity, comptime T: type) Error!void {
            comptime validateComponentType(T, Registry);

            self.assertInvariants();
            if (!self.contains(entity)) return error.EntityNotFound;

            const source_key = self.archetypeKeyOf(entity).?;
            if (!source_key.containsType(T)) {
                self.assertInvariants();
                return;
            }

            const target_key = source_key.withoutType(T);
            try self.moveEntityToArchetype(entity, target_key);
            assert(!self.hasComponent(entity, T));
            self.assertInvariants();
        }

        fn moveEntityToArchetype(self: *Self, entity: entity_mod.Entity, target_key: Key) Error!void {
            const source_location = self.locationOf(entity) orelse return error.EntityNotFound;
            const source_archetype = self.archetypeRecordConst(source_location.archetype_index).?;
            if (keysEqual(&source_archetype.key, &target_key)) {
                return;
            }

            const target_archetype_index = try self.ensureArchetype(&target_key);
            const target_location = try self.appendEntityToArchetype(target_archetype_index, entity);
            errdefer {
                _ = self.removeEntityAt(target_location, entity) catch {};
                self.clearLocation(entity);
            }

            try self.copySharedColumns(source_location, target_location);
            self.writeLocation(entity, target_location);
            try self.removeEntityAt(source_location, entity);

            assert(self.contains(entity));
            const current_key = self.archetypeKeyOf(entity).?;
            assert(keysEqual(&current_key, &target_key));
        }

        fn appendEntityToArchetype(self: *Self, archetype_index: u32, entity: entity_mod.Entity) Error!EntityLocation {
            const chunk_location = try self.ensureChunkWithSpace(archetype_index);
            var chunk_record = self.chunkRecord(chunk_location).?;
            const row_index = chunk_record.chunk.rowCount();
            const row_usize: usize = row_index;
            assert(row_index < chunk_record.chunk.capacity());
            try chunk_record.chunk.setRowCount(row_index + 1);
            chunk_record.entities[row_usize] = entity;

            const location: EntityLocation = .{
                .archetype_index = archetype_index,
                .chunk_index = chunk_location.chunk_index,
                .row_index = row_index,
                .occupied = true,
            };
            assert(location.occupied);
            return location;
        }

        fn copySharedColumns(self: *Self, source: EntityLocation, target: EntityLocation) Error!void {
            const source_archetype = self.archetypeRecordConst(source.archetype_index).?;
            const target_archetype = self.archetypeRecordConst(target.archetype_index).?;
            var source_chunk = self.chunkRecord(source).?;
            var target_chunk = self.chunkRecord(target).?;

            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                if (@sizeOf(T) != 0 and source_archetype.key.containsId(id) and target_archetype.key.containsId(id)) {
                    const src_column = source_chunk.chunk.columnSliceConst(T).?;
                    const dst_column = target_chunk.chunk.columnSlice(T).?;
                    const source_row: usize = source.row_index;
                    const target_row: usize = target.row_index;
                    assert(source_row < src_column.len);
                    assert(target_row < dst_column.len);
                    dst_column[target_row] = src_column[source_row];
                }
            }
        }

        fn removeEntityAt(self: *Self, location: EntityLocation, entity: entity_mod.Entity) Error!void {
            const archetype = self.archetypeRecord(location.archetype_index).?;
            const key = archetype.key;
            var chunk_record = self.chunkRecord(location).?;

            const rows_before = chunk_record.chunk.rowCount();
            assert(rows_before > 0);
            const last_row = rows_before - 1;
            const remove_row: usize = location.row_index;
            const last_row_usize: usize = last_row;
            assert(remove_row < rows_before);
            assert(std.meta.eql(chunk_record.entities[remove_row], entity));

            if (location.row_index != last_row) {
                inline for (0..component_universe_count) |index| {
                    const T = Registry.typeAt(index);
                    const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                    if (@sizeOf(T) != 0 and key.containsId(id)) {
                        const column = chunk_record.chunk.columnSlice(T).?;
                        column[remove_row] = column[last_row_usize];
                    }
                }

                const moved_entity = chunk_record.entities[last_row_usize];
                chunk_record.entities[remove_row] = moved_entity;
                self.writeLocation(moved_entity, .{
                    .archetype_index = location.archetype_index,
                    .chunk_index = location.chunk_index,
                    .row_index = location.row_index,
                    .occupied = true,
                });
            }

            try chunk_record.chunk.setRowCount(last_row);
            if (last_row > 0) {
                assert(chunk_record.chunk.rowCount() == last_row);
            }
            if (chunk_record.chunk.rowCount() == 0) {
                try self.removeChunkIfEmpty(location.archetype_index, location.chunk_index);
            }
        }

        fn ensureArchetype(self: *Self, key: *const Key) Error!u32 {
            if (self.findArchetypeIndex(key)) |index| return index;
            if (self.archetypes.len() >= self.config.archetypes_max) return error.NoSpaceLeft;

            var record = try ArchetypeRecord.init(self.allocator, key.*, self.config.budget);
            errdefer record.deinit(self.allocator);
            try self.archetypes.append(record);
            const archetype_index: u32 = @intCast(self.archetypes.len() - 1);
            assert(self.archetypeRecordConst(archetype_index) != null);
            return archetype_index;
        }

        fn ensureChunkWithSpace(self: *Self, archetype_index: u32) Error!EntityLocation {
            const archetype = self.archetypeRecord(archetype_index).?;
            for (archetype.chunks.items(), 0..) |*chunk_record, index| {
                if (chunk_record.chunk.rowCount() < chunk_record.chunk.capacity()) {
                    return .{
                        .archetype_index = archetype_index,
                        .chunk_index = @intCast(index),
                        .row_index = chunk_record.chunk.rowCount(),
                        .occupied = true,
                    };
                }
            }

            if (self.total_chunks >= self.config.chunks_max) return error.NoSpaceLeft;

            var record = try ChunkRecord.init(
                self.allocator,
                archetype.key,
                self.config.chunk_rows_max,
                self.config.budget,
            );
            errdefer record.deinit(self.allocator);
            try archetype.chunks.append(record);
            self.total_chunks += 1;

            const chunk_index: u32 = @intCast(archetype.chunks.len() - 1);
            return .{
                .archetype_index = archetype_index,
                .chunk_index = chunk_index,
                .row_index = 0,
                .occupied = true,
            };
        }

        fn removeChunkIfEmpty(self: *Self, archetype_index: u32, chunk_index: u32) Error!void {
            const archetype = self.archetypeRecord(archetype_index).?;
            const index: usize = chunk_index;
            const items = archetype.chunks.items();
            assert(index < items.len);
            assert(items[index].chunk.rowCount() == 0);

            var removed_chunk = items[index];
            const last_index = items.len - 1;
            if (index != last_index) {
                items[index] = items[last_index];
            }
            _ = archetype.chunks.pop();
            removed_chunk.deinit(self.allocator);

            assert(self.total_chunks > 0);
            self.total_chunks -= 1;

            if (index != last_index) {
                try self.reindexChunkEntities(archetype_index, @intCast(index));
            }
            try self.removeArchetypeIfEmpty(archetype_index);
        }

        fn removeArchetypeIfEmpty(self: *Self, archetype_index: u32) Error!void {
            if (archetype_index == 0) return;

            const archetype = self.archetypeRecord(archetype_index).?;
            if (archetype.chunks.len() != 0) return;

            const index: usize = archetype_index;
            const items = self.archetypes.items();
            var removed_archetype = items[index];
            const last_index = items.len - 1;
            if (index != last_index) {
                items[index] = items[last_index];
            }
            _ = self.archetypes.pop();
            removed_archetype.deinit(self.allocator);

            if (index != last_index) {
                try self.reindexArchetypeEntities(@intCast(index));
            }
        }

        fn reindexArchetypeEntities(self: *Self, archetype_index: u32) Error!void {
            const archetype = self.archetypeRecordConst(archetype_index).?;
            for (archetype.chunks.itemsConst(), 0..) |_, chunk_index| {
                try self.reindexChunkEntities(archetype_index, @intCast(chunk_index));
            }
        }

        fn reindexChunkEntities(self: *Self, archetype_index: u32, chunk_index: u32) Error!void {
            var chunk_record = self.chunkRecord(.{
                .archetype_index = archetype_index,
                .chunk_index = chunk_index,
                .row_index = 0,
                .occupied = true,
            }).?;
            const row_count: usize = chunk_record.chunk.rowCount();
            for (0..row_count) |row_index| {
                const entity = chunk_record.entities[row_index];
                self.writeLocation(entity, .{
                    .archetype_index = archetype_index,
                    .chunk_index = chunk_index,
                    .row_index = @intCast(row_index),
                    .occupied = true,
                });
            }
        }

        fn findArchetypeIndex(self: *const Self, key: *const Key) ?u32 {
            const archetypes = self.archetypes.itemsConst();
            for (archetypes, 0..) |_, index| {
                const archetype = &archetypes[index];
                if (keysEqual(&archetype.key, key)) return @intCast(index);
            }
            return null;
        }

        fn keysEqual(a: *const Key, b: *const Key) bool {
            inline for (0..component_universe_count) |index| {
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                if (a.containsId(id) != b.containsId(id)) return false;
            }
            return true;
        }

        fn introducesUninitializedColumns(source_key: Key, target_key: Key) bool {
            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                if (@sizeOf(T) != 0 and !source_key.containsId(id) and target_key.containsId(id)) {
                    return true;
                }
            }
            return false;
        }

        fn locationRaw(self: *const Self, entity: entity_mod.Entity) ?EntityLocation {
            if (!entity.isValid()) return null;
            const index: usize = entity.index;
            if (index >= self.entity_locations.len) return null;
            return self.entity_locations[index];
        }

        fn writeLocation(self: *Self, entity: entity_mod.Entity, location: EntityLocation) void {
            const index: usize = entity.index;
            assert(index < self.entity_locations.len);
            assert(location.occupied);
            self.entity_locations[index] = location;
        }

        fn clearLocation(self: *Self, entity: entity_mod.Entity) void {
            const index: usize = entity.index;
            assert(index < self.entity_locations.len);
            self.entity_locations[index] = EntityLocation.invalid();
        }

        fn archetypeRecord(self: *Self, archetype_index: u32) ?*ArchetypeRecord {
            const index: usize = archetype_index;
            if (index >= self.archetypes.len()) return null;
            return &self.archetypes.items()[index];
        }

        fn archetypeRecordConst(self: *const Self, archetype_index: u32) ?*const ArchetypeRecord {
            const index: usize = archetype_index;
            if (index >= self.archetypes.len()) return null;
            return &self.archetypes.itemsConst()[index];
        }

        fn chunkRecord(self: *Self, location: EntityLocation) ?*ChunkRecord {
            const archetype = self.archetypeRecord(location.archetype_index) orelse return null;
            const chunk_index: usize = location.chunk_index;
            if (chunk_index >= archetype.chunks.len()) return null;
            return &archetype.chunks.items()[chunk_index];
        }

        fn chunkRecordConst(self: *const Self, location: EntityLocation) ?*const ChunkRecord {
            const archetype = self.archetypeRecordConst(location.archetype_index) orelse return null;
            const chunk_index: usize = location.chunk_index;
            if (chunk_index >= archetype.chunks.len()) return null;
            return &archetype.chunks.itemsConst()[chunk_index];
        }

        fn assertInvariants(self: *const Self) void {
            assert(self.archetypes.len() > 0);
            assert(self.archetypes.len() <= self.config.archetypes_max);
            assert(self.total_chunks <= self.config.chunks_max);
            assert(self.active_entities <= self.config.entities_max);
            assert(Registry.count() <= self.config.components_per_archetype_max);
            const empty_key = Key.empty();
            assert(keysEqual(&self.archetypes.itemsConst()[0].key, &empty_key));

            var occupied_count: u32 = 0;
            for (self.entity_locations, 0..) |location, entity_index| {
                if (!location.occupied) continue;
                occupied_count += 1;
                assert(location.archetype_index < self.archetypes.len());

                const archetype = self.archetypes.itemsConst()[location.archetype_index];
                assert(location.chunk_index < archetype.chunks.len());

                const chunk_record = archetype.chunks.itemsConst()[location.chunk_index];
                assert(location.row_index < chunk_record.chunk.rowCount());
                assert(location.row_index < chunk_record.chunk.capacity());

                const row_index: usize = location.row_index;
                const entity = chunk_record.entities[row_index];
                assert(entity.index == entity_index);
                assert(entity.isValid());
            }
            assert(occupied_count == self.active_entities);
        }
    };
}

fn validateComponentType(comptime T: type, comptime Registry: type) void {
    if (!Registry.contains(T)) {
        @compileError("ArchetypeStore component operations require a type from the component universe.");
    }
}

test "archetype store spawns into the empty archetype and tracks locations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position, Velocity });

    var store = try Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer store.deinit();

    const first: entity_mod.Entity = .{ .index = 0, .generation = 1 };
    const second: entity_mod.Entity = .{ .index = 1, .generation = 1 };

    try store.spawn(first);
    try store.spawn(second);

    try testing.expect(store.contains(first));
    try testing.expect(store.contains(second));
    try testing.expectEqual(@as(u32, 2), store.activeCount());
    try testing.expectEqual(@as(u32, 1), store.archetypeCount());
    try testing.expectEqual(@as(u32, 1), store.chunkCount());

    const first_location = store.locationOf(first).?;
    const second_location = store.locationOf(second).?;
    try testing.expectEqual(@as(u32, 0), first_location.row_index);
    try testing.expectEqual(@as(u32, 1), second_location.row_index);
    try testing.expectEqual(@as(u32, 0), store.archetypeKeyOf(first).?.count());
}

test "archetype store rejects direct configs that understate the component universe" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position, Velocity });

    try testing.expectError(error.InvalidConfig, Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 1,
        .chunks_max = 4,
        .chunk_rows_max = 4,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    }));
}

test "archetype store despawn swap-removes rows and updates moved entity locations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position, Velocity });

    var store = try Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 4,
        .chunk_rows_max = 8,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer store.deinit();

    const first: entity_mod.Entity = .{ .index = 0, .generation = 1 };
    const second: entity_mod.Entity = .{ .index = 1, .generation = 1 };
    const third: entity_mod.Entity = .{ .index = 2, .generation = 1 };

    try store.spawn(first);
    try store.spawn(second);
    try store.spawn(third);
    try store.insertComponent(first, Position, .{ .x = 10, .y = 11 });
    try store.insertComponent(second, Position, .{ .x = 20, .y = 21 });
    try store.insertComponent(third, Position, .{ .x = 30, .y = 31 });

    try store.despawn(second);

    try testing.expect(!store.contains(second));
    try testing.expect(store.contains(first));
    try testing.expect(store.contains(third));
    try testing.expectEqual(@as(u32, 2), store.activeCount());
    try testing.expectEqual(@as(u32, 1), store.locationOf(third).?.row_index);
    try testing.expectEqual(@as(f32, 30), store.componentPtrConst(third, Position).?.x);
    try testing.expectEqual(@as(f32, 31), store.componentPtrConst(third, Position).?.y);
}

test "archetype store rejects same-index direct spawn aliasing before mutation" {
    const Position = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position });

    var store = try Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 4,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer store.deinit();

    const first: entity_mod.Entity = .{ .index = 0, .generation = 1 };
    const alias: entity_mod.Entity = .{ .index = 0, .generation = 2 };

    try store.spawn(first);
    try store.insertComponent(first, Position, .{ .x = 11, .y = 13 });

    try testing.expectError(error.EntitySlotOccupied, store.spawn(alias));
    try testing.expect(store.contains(first));
    try testing.expect(!store.contains(alias));
    try testing.expectEqual(@as(u32, 1), store.activeCount());
    try testing.expectEqual(@as(f32, 11), store.componentPtrConst(first, Position).?.x);
    try testing.expectEqual(@as(f32, 13), store.componentPtrConst(first, Position).?.y);
    try testing.expectEqual(@as(u32, 0), store.locationOf(first).?.row_index);
}

test "archetype store transitions preserve overlapping columns and reclaim empty archetypes" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position, Velocity });

    var store = try Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 4,
        .chunk_rows_max = 4,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer store.deinit();

    const entity: entity_mod.Entity = .{ .index = 0, .generation = 1 };

    try store.spawn(entity);
    try store.insertComponent(entity, Position, .{ .x = 7, .y = 9 });
    try store.insertComponent(entity, Velocity, .{ .x = 3, .y = 5 });

    try testing.expectEqual(@as(u32, 2), store.archetypeCount());
    try testing.expect(store.componentPtr(entity, Velocity) != null);
    try testing.expectEqual(@as(f32, 7), store.componentPtrConst(entity, Position).?.x);
    try testing.expectEqual(@as(f32, 9), store.componentPtrConst(entity, Position).?.y);
    try testing.expectEqual(@as(f32, 3), store.componentPtrConst(entity, Velocity).?.x);
}

test "archetype store reindexes swapped chunks after draining a non-tail chunk" {
    const Position = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position });

    var store = try Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
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

    try store.spawn(first);
    try store.spawn(second);
    try store.spawn(third);
    try store.insertComponent(first, Position, .{ .x = 10, .y = 11 });
    try store.insertComponent(second, Position, .{ .x = 20, .y = 21 });
    try store.insertComponent(third, Position, .{ .x = 30, .y = 31 });

    try testing.expectEqual(@as(u32, 2), store.chunkCount());

    try store.despawn(first);
    try store.despawn(second);

    try testing.expect(store.contains(third));
    try testing.expectEqual(@as(u32, 1), store.chunkCount());
    const third_location = store.locationOf(third).?;
    try testing.expectEqual(@as(u32, 0), third_location.chunk_index);
    try testing.expectEqual(@as(u32, 0), third_location.row_index);
    try testing.expectEqual(@as(f32, 30), store.componentPtrConst(third, Position).?.x);
    try testing.expectEqual(@as(f32, 31), store.componentPtrConst(third, Position).?.y);
}

test "archetype store reindexes swapped archetypes after removing an empty middle archetype" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position, Velocity });
    const Key = archetype_key_mod.ArchetypeKey(.{ Position, Velocity });

    var store = try Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 6,
        .components_per_archetype_max = 4,
        .chunks_max = 6,
        .chunk_rows_max = 2,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer store.deinit();

    const position_entity: entity_mod.Entity = .{ .index = 0, .generation = 1 };
    const velocity_entity: entity_mod.Entity = .{ .index = 1, .generation = 1 };

    try store.spawn(position_entity);
    try store.spawn(velocity_entity);
    try store.insertComponent(position_entity, Position, .{ .x = 4, .y = 8 });
    try store.insertComponent(velocity_entity, Velocity, .{ .x = 9, .y = 10 });

    try testing.expectEqual(@as(u32, 3), store.archetypeCount());
    try store.despawn(position_entity);

    try testing.expect(!store.contains(position_entity));
    try testing.expect(store.contains(velocity_entity));
    try testing.expectEqual(@as(u32, 2), store.archetypeCount());
    try testing.expectEqual(@as(u32, 1), store.locationOf(velocity_entity).?.archetype_index);
    const velocity_key = store.archetypeKeyOf(velocity_entity).?;
    const expected_velocity_key = Key.fromTypes(.{ Velocity });
    try testing.expectEqual(expected_velocity_key.count(), velocity_key.count());
    try testing.expect(velocity_key.containsType(Velocity));
    try testing.expect(!velocity_key.containsType(Position));
    try testing.expectEqual(@as(f32, 9), store.componentPtrConst(velocity_entity, Velocity).?.x);
    try testing.expectEqual(@as(f32, 10), store.componentPtrConst(velocity_entity, Velocity).?.y);
}

test "archetype store rejects raw value-component additions without initialization and allows tag-only moves" {
    const Position = struct { x: f32, y: f32 };
    const Tag = struct {};
    const Store = ArchetypeStore(.{ Position, Tag });
    const Key = archetype_key_mod.ArchetypeKey(.{ Position, Tag });

    var store = try Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 4,
        .chunk_rows_max = 4,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer store.deinit();

    const entity: entity_mod.Entity = .{ .index = 0, .generation = 1 };
    try store.spawn(entity);

    try testing.expectError(error.ComponentInitRequired, store.moveToArchetype(entity, Key.fromTypes(.{ Position })));

    try store.moveToArchetype(entity, Key.fromTypes(.{ Tag }));
    try testing.expect(store.hasComponent(entity, Tag));
    try testing.expect(!store.hasComponent(entity, Position));
}

test "archetype store releases chunk init reservations when chunk vector append fails" {
    const Position = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position });

    const probe_config: world_config_mod.WorldConfig = .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    };

    var probe_budget = try memory.budget.Budget.init(1024);
    var probe_store = try Store.init(testing.allocator, .{
        .entities_max = probe_config.entities_max,
        .archetypes_max = probe_config.archetypes_max,
        .components_per_archetype_max = probe_config.components_per_archetype_max,
        .chunks_max = probe_config.chunks_max,
        .chunk_rows_max = probe_config.chunk_rows_max,
        .query_cache_entries_max = probe_config.query_cache_entries_max,
        .command_buffer_entries_max = probe_config.command_buffer_entries_max,
        .side_index_entries_max = probe_config.side_index_entries_max,
        .budget = &probe_budget,
    });
    const base_used = probe_budget.used();
    probe_store.deinit();
    try testing.expectEqual(@as(u64, 0), probe_budget.used());

    const chunk_entity_bytes = try std.math.mul(usize, probe_config.chunk_rows_max, @sizeOf(entity_mod.Entity));
    const limit_bytes = try std.math.add(usize, @intCast(base_used), chunk_entity_bytes);
    var budget = try memory.budget.Budget.init(limit_bytes);
    {
        var store = try Store.init(testing.allocator, .{
            .entities_max = probe_config.entities_max,
            .archetypes_max = probe_config.archetypes_max,
            .components_per_archetype_max = probe_config.components_per_archetype_max,
            .chunks_max = probe_config.chunks_max,
            .chunk_rows_max = probe_config.chunk_rows_max,
            .query_cache_entries_max = probe_config.query_cache_entries_max,
            .command_buffer_entries_max = probe_config.command_buffer_entries_max,
            .side_index_entries_max = probe_config.side_index_entries_max,
            .budget = &budget,
        });
        defer store.deinit();

        const entity: entity_mod.Entity = .{ .index = 0, .generation = 1 };
        try testing.expectError(error.NoSpaceLeft, store.spawn(entity));
        try testing.expectEqual(base_used, budget.used());
        try testing.expectEqual(@as(u32, 0), store.activeCount());
        try testing.expectEqual(@as(u32, 0), store.chunkCount());
        try testing.expect(!store.contains(entity));
    }
    try testing.expectEqual(@as(u64, 0), budget.used());
}
