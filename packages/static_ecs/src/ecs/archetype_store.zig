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
const bundle_codec_mod = @import("bundle_codec.zig");

pub fn ArchetypeStore(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const Key = archetype_key_mod.ArchetypeKey(Components);
    const Chunk = chunk_mod.Chunk(Components);
    const BundleReader = bundle_codec_mod.Reader(Components);
    const component_universe_count: usize = comptime Registry.count();

    const FingerprintCmp = struct {
        pub fn less(a: u64, b: u64) bool {
            return a < b;
        }
    };

    return struct {
        const Self = @This();

        pub const Error = world_config_mod.Error || Chunk.Error || collections.vec.Error || collections.sorted_vec_map.Error || error{
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
                return .{
                    .archetype_index = invalid_index,
                    .chunk_index = invalid_index,
                    .row_index = invalid_index,
                    .occupied = false,
                };
            }
        };

        const invalid_index = std.math.maxInt(u32);
        const FingerprintIndex = collections.sorted_vec_map.SortedVecMap(u64, u32, FingerprintCmp);

        const ChunkRecord = struct {
            chunk: Chunk,
            entities: []entity_mod.Entity,

            fn init(
                allocator: std.mem.Allocator,
                key: Key,
                rows_capacity: u32,
                budget: ?*memory.budget.Budget,
            ) Error!ChunkRecord {
                var chunk = try Chunk.init(allocator, key, rows_capacity, budget);
                errdefer chunk.deinit();
                return .{
                    .chunk = chunk,
                    .entities = chunk.entityStorage(),
                };
            }

            fn deinit(self: *ChunkRecord) void {
                self.chunk.deinit();
                self.* = undefined;
            }
        };

        const ChunkVec = collections.vec.Vec(ChunkRecord);

        const ArchetypeRecord = struct {
            key: Key,
            fingerprint: u64,
            chunks: ChunkVec,
            nonfull_chunk_hint: ?u32 = null,
            retained_empty_chunks: u32 = 0,

            fn init(allocator: std.mem.Allocator, key: Key, budget: ?*memory.budget.Budget) Error!ArchetypeRecord {
                return .{
                    .key = key,
                    .fingerprint = key.fingerprint64(),
                    .chunks = try ChunkVec.init(allocator, .{
                        .budget = budget,
                    }),
                };
            }

            fn deinit(self: *ArchetypeRecord) void {
                for (self.chunks.items()) |*chunk_record| {
                    chunk_record.deinit();
                }
                self.chunks.deinit();
                self.* = undefined;
            }
        };

        const ArchetypeVec = collections.vec.Vec(ArchetypeRecord);

        allocator: std.mem.Allocator,
        config: world_config_mod.WorldConfig,
        archetypes: ArchetypeVec,
        archetype_index: FingerprintIndex,
        entity_locations: []EntityLocation,
        locations_reserved_bytes: usize,
        total_chunks: u32,
        active_entities: u32,
        structural_epoch_value: u64,

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

            var index = try FingerprintIndex.init(allocator, .{
                .initial_capacity = 1,
                .budget = config.budget,
            });
            errdefer index.deinit();

            var empty_record = try ArchetypeRecord.init(allocator, Key.empty(), config.budget);
            errdefer empty_record.deinit();
            try archetypes.append(empty_record);
            try index.put(Key.empty().fingerprint64(), 0);

            var self: Self = .{
                .allocator = allocator,
                .config = config,
                .archetypes = archetypes,
                .archetype_index = index,
                .entity_locations = entity_locations,
                .locations_reserved_bytes = locations_reserved_bytes,
                .total_chunks = 0,
                .active_entities = 0,
                .structural_epoch_value = 0,
            };
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            for (self.archetypes.items()) |*archetype| {
                archetype.deinit();
            }
            self.archetypes.deinit();
            self.archetype_index.deinit();
            self.allocator.free(self.entity_locations);
            if (self.config.budget) |budget| {
                budget.release(self.locations_reserved_bytes);
            }
            self.* = undefined;
        }

        pub fn activeCount(self: *const Self) u32 {
            self.assertInvariants();
            return self.active_entities;
        }

        pub fn archetypeCount(self: *const Self) u32 {
            self.assertInvariants();
            return @intCast(self.archetypes.len());
        }

        pub fn chunkCount(self: *const Self) u32 {
            self.assertInvariants();
            return self.total_chunks;
        }

        pub fn structuralEpoch(self: *const Self) u64 {
            self.assertInvariants();
            return self.structural_epoch_value;
        }

        pub fn contains(self: *const Self, entity: entity_mod.Entity) bool {
            self.assertInvariants();
            return self.locationOf(entity) != null;
        }

        pub fn locationOf(self: *const Self, entity: entity_mod.Entity) ?EntityLocation {
            self.assertInvariants();
            const location = self.locationRaw(entity) orelse return null;
            if (!location.occupied) return null;
            const chunk_record = self.chunkRecordConst(location) orelse return null;
            if (location.row_index >= chunk_record.chunk.rowCount()) return null;
            if (!std.meta.eql(chunk_record.entities[location.row_index], entity)) return null;
            return location;
        }

        pub fn archetypeKeyOf(self: *const Self, entity: entity_mod.Entity) ?Key {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return null;
            return self.archetypeRecordConst(location.archetype_index).?.key;
        }

        pub fn componentPtr(self: *Self, entity: entity_mod.Entity, comptime T: type) ?*T {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return null;
            const chunk_record = self.chunkRecord(location).?;
            const column = chunk_record.chunk.columnSlice(T) orelse return null;
            return &column[location.row_index];
        }

        pub fn componentPtrConst(self: *const Self, entity: entity_mod.Entity, comptime T: type) ?*const T {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return null;
            const chunk_record = self.chunkRecordConst(location).?;
            const column = chunk_record.chunk.columnSliceConst(T) orelse return null;
            return &column[location.row_index];
        }

        pub fn hasComponent(self: *const Self, entity: entity_mod.Entity, comptime T: type) bool {
            comptime validateComponentType(T, Registry);
            self.assertInvariants();
            const key = self.archetypeKeyOf(entity) orelse return false;
            return key.containsType(T);
        }

        pub fn spawn(self: *Self, entity: entity_mod.Entity) Error!void {
            self.assertInvariants();
            try self.assertSpawnable(entity);

            const location = try self.appendEntityToArchetype(0, entity);
            self.writeLocation(entity, location);
            self.active_entities += 1;
            self.bumpStructuralEpoch();
            self.assertInvariants();
        }

        pub fn spawnBundleEncoded(self: *Self, entity: entity_mod.Entity, bytes: []const u8, entry_count: u32) Error!void {
            self.assertInvariants();
            try self.assertSpawnable(entity);

            const target_key = try self.keyFromEncodedBundle(bytes, entry_count);
            const target_archetype_index = try self.ensureArchetype(&target_key);
            const target_location = try self.appendEntityToArchetype(target_archetype_index, entity);
            errdefer _ = self.removeEntityAt(target_location, entity) catch {};

            try self.writeBundlePayloads(target_location, bytes, entry_count);
            self.writeLocation(entity, target_location);
            self.active_entities += 1;
            self.bumpStructuralEpoch();
            self.assertInvariants();
        }

        pub fn despawn(self: *Self, entity: entity_mod.Entity) Error!void {
            self.assertInvariants();
            const location = self.locationOf(entity) orelse return error.EntityNotFound;
            try self.removeEntityAt(location, entity);
            self.clearLocation(entity);
            self.active_entities -= 1;
            self.bumpStructuralEpoch();
            self.assertInvariants();
        }

        pub fn moveToArchetype(self: *Self, entity: entity_mod.Entity, target_key: Key) Error!void {
            self.assertInvariants();
            const source_location = self.locationOf(entity) orelse return error.EntityNotFound;
            const source_key = self.archetypeRecordConst(source_location.archetype_index).?.key;
            if (target_key.count() > self.config.components_per_archetype_max) return error.InvalidConfig;
            if (keysEqual(source_key, target_key)) return;
            if (introducesUninitializedColumns(Components, source_key, target_key)) {
                return error.ComponentInitRequired;
            }

            _ = try self.moveEntityToArchetype(entity, target_key, null);
            self.bumpStructuralEpoch();
            self.assertInvariants();
        }

        pub fn insertComponent(self: *Self, entity: entity_mod.Entity, comptime T: type, value: T) Error!void {
            comptime validateComponentType(T, Registry);

            self.assertInvariants();
            if (!self.contains(entity)) return error.EntityNotFound;

            if (!self.hasComponent(entity, T)) {
                const source_key = self.archetypeKeyOf(entity).?;
                const target_key = try source_key.withType(T);
                _ = try self.moveEntityToArchetype(entity, target_key, null);
                self.bumpStructuralEpoch();
            }

            if (@sizeOf(T) != 0) {
                self.componentPtr(entity, T).?.* = value;
            }
            self.assertInvariants();
        }

        pub fn insertBundleEncoded(self: *Self, entity: entity_mod.Entity, bytes: []const u8, entry_count: u32) Error!void {
            self.assertInvariants();
            const source_location = self.locationOf(entity) orelse return error.EntityNotFound;
            const source_key = self.archetypeRecordConst(source_location.archetype_index).?.key;
            const bundle_key = try self.keyFromEncodedBundle(bytes, entry_count);
            const target_key = try mergeKeys(Components, source_key, bundle_key);
            if (keysEqual(source_key, target_key)) {
                try self.writeBundlePayloads(source_location, bytes, entry_count);
            } else {
                _ = try self.moveEntityToArchetype(entity, target_key, .{
                    .bytes = bytes,
                    .entry_count = entry_count,
                });
                self.bumpStructuralEpoch();
            }
            self.assertInvariants();
        }

        pub fn removeComponent(self: *Self, entity: entity_mod.Entity, comptime T: type) Error!void {
            comptime validateComponentType(T, Registry);

            self.assertInvariants();
            if (!self.contains(entity)) return error.EntityNotFound;

            const source_key = self.archetypeKeyOf(entity).?;
            if (!source_key.containsType(T)) return;

            const target_key = source_key.withoutType(T);
            _ = try self.moveEntityToArchetype(entity, target_key, null);
            self.bumpStructuralEpoch();
            self.assertInvariants();
        }

        fn moveEntityToArchetype(
            self: *Self,
            entity: entity_mod.Entity,
            target_key: Key,
            bundle_write: ?struct {
                bytes: []const u8,
                entry_count: u32,
            },
        ) Error!EntityLocation {
            const source_location = self.locationOf(entity) orelse return error.EntityNotFound;
            const source_key = self.archetypeRecordConst(source_location.archetype_index).?.key;
            if (keysEqual(source_key, target_key)) return source_location;

            const target_archetype_index = try self.ensureArchetype(&target_key);
            const target_location = try self.appendEntityToArchetype(target_archetype_index, entity);
            errdefer _ = self.removeEntityAt(target_location, entity) catch {};

            try self.copySharedColumns(source_location, target_location);
            if (bundle_write) |write| {
                try self.writeBundlePayloads(target_location, write.bytes, write.entry_count);
            }
            self.writeLocation(entity, target_location);
            try self.removeEntityAt(source_location, entity);
            return target_location;
        }

        fn appendEntityToArchetype(self: *Self, archetype_index: u32, entity: entity_mod.Entity) Error!EntityLocation {
            const chunk_index = try self.ensureChunkWithSpace(archetype_index);
            const chunk_record = self.chunkRecord(.{
                .archetype_index = archetype_index,
                .chunk_index = chunk_index,
                .row_index = 0,
                .occupied = true,
            }).?;
            const row_index = chunk_record.chunk.rowCount();
            try chunk_record.chunk.setRowCount(row_index + 1);
            chunk_record.entities[row_index] = entity;
            self.refreshNonfullChunkHint(archetype_index);
            return .{
                .archetype_index = archetype_index,
                .chunk_index = chunk_index,
                .row_index = row_index,
                .occupied = true,
            };
        }

        fn copySharedColumns(self: *Self, source: EntityLocation, target: EntityLocation) Error!void {
            const source_key = self.archetypeRecordConst(source.archetype_index).?.key;
            const target_key = self.archetypeRecordConst(target.archetype_index).?.key;
            const source_chunk = self.chunkRecord(source).?;
            const target_chunk = self.chunkRecord(target).?;

            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                if (@sizeOf(T) != 0 and source_key.containsId(id) and target_key.containsId(id)) {
                    target_chunk.chunk.columnSlice(T).?[target.row_index] = source_chunk.chunk.columnSliceConst(T).?[source.row_index];
                }
            }
        }

        fn removeEntityAt(self: *Self, location: EntityLocation, entity: entity_mod.Entity) Error!void {
            const archetype = self.archetypeRecord(location.archetype_index).?;
            const key = archetype.key;
            const chunk_record = self.chunkRecord(location).?;

            const rows_before = chunk_record.chunk.rowCount();
            assert(rows_before > 0);
            const last_row = rows_before - 1;
            assert(std.meta.eql(chunk_record.entities[location.row_index], entity));

            if (location.row_index != last_row) {
                inline for (0..component_universe_count) |index| {
                    const T = Registry.typeAt(index);
                    const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                    if (@sizeOf(T) != 0 and key.containsId(id)) {
                        chunk_record.chunk.columnSlice(T).?[location.row_index] = chunk_record.chunk.columnSlice(T).?[last_row];
                    }
                }

                const moved_entity = chunk_record.entities[last_row];
                chunk_record.entities[location.row_index] = moved_entity;
                self.writeLocation(moved_entity, .{
                    .archetype_index = location.archetype_index,
                    .chunk_index = location.chunk_index,
                    .row_index = location.row_index,
                    .occupied = true,
                });
            }

            try chunk_record.chunk.setRowCount(last_row);
            if (chunk_record.chunk.rowCount() == 0) {
                try self.handleEmptyChunk(location.archetype_index, location.chunk_index);
            } else {
                self.refreshNonfullChunkHint(location.archetype_index);
            }
            try self.removeArchetypeIfInactive(location.archetype_index);
        }

        fn ensureArchetype(self: *Self, key: *const Key) Error!u32 {
            if (self.findArchetypeIndex(key.*)) |index| return index;
            if (self.archetypes.len() >= self.config.archetypes_max) return error.NoSpaceLeft;

            var record = try ArchetypeRecord.init(self.allocator, key.*, self.config.budget);
            errdefer record.deinit();
            try self.archetypes.append(record);
            const archetype_index: u32 = @intCast(self.archetypes.len() - 1);
            if (!self.archetype_index.contains(record.fingerprint)) {
                try self.archetype_index.put(record.fingerprint, archetype_index);
            }
            return archetype_index;
        }

        fn ensureChunkWithSpace(self: *Self, archetype_index: u32) Error!u32 {
            const archetype = self.archetypeRecord(archetype_index).?;
            if (archetype.nonfull_chunk_hint) |hint| {
                const record = self.chunkRecord(.{
                    .archetype_index = archetype_index,
                    .chunk_index = hint,
                    .row_index = 0,
                    .occupied = true,
                }).?;
                if (record.chunk.rowCount() < record.chunk.capacity()) return hint;
            }

            for (archetype.chunks.items(), 0..) |*chunk_record, chunk_index| {
                if (chunk_record.chunk.rowCount() < chunk_record.chunk.capacity()) {
                    archetype.nonfull_chunk_hint = @intCast(chunk_index);
                    return @intCast(chunk_index);
                }
            }

            if (self.total_chunks >= self.config.chunks_max) return error.NoSpaceLeft;

            var chunk_record = try ChunkRecord.init(
                self.allocator,
                archetype.key,
                self.config.chunk_rows_max,
                self.config.budget,
            );
            errdefer chunk_record.deinit();
            try archetype.chunks.append(chunk_record);
            self.total_chunks += 1;
            archetype.nonfull_chunk_hint = @intCast(archetype.chunks.len() - 1);
            return @intCast(archetype.chunks.len() - 1);
        }

        fn handleEmptyChunk(self: *Self, archetype_index: u32, chunk_index: u32) Error!void {
            const archetype = self.archetypeRecord(archetype_index).?;
            if (archetype_index != 0 and self.archetypeActiveRows(archetype_index) == 0) {
                try self.removeChunk(archetype_index, chunk_index);
                return;
            }

            if (archetype.retained_empty_chunks < self.config.empty_chunk_retained_max) {
                archetype.retained_empty_chunks += 1;
                self.refreshNonfullChunkHint(archetype_index);
                return;
            }

            try self.removeChunk(archetype_index, chunk_index);
        }

        fn removeChunk(self: *Self, archetype_index: u32, chunk_index: u32) Error!void {
            const archetype = self.archetypeRecord(archetype_index).?;
            const tail_index = archetype.chunks.len() - 1;
            var removed = archetype.chunks.items()[chunk_index];
            if (chunk_index != tail_index) {
                archetype.chunks.items()[chunk_index] = archetype.chunks.items()[tail_index];
                try self.reindexChunkEntities(archetype_index, chunk_index);
            }

            _ = archetype.chunks.pop();
            if (removed.chunk.rowCount() == 0 and archetype.retained_empty_chunks > 0) {
                archetype.retained_empty_chunks -= 1;
            }
            removed.deinit();
            self.total_chunks -= 1;
            self.refreshNonfullChunkHint(archetype_index);
        }

        fn removeArchetypeIfInactive(self: *Self, archetype_index: u32) Error!void {
            if (archetype_index == 0) return;
            if (self.archetypeActiveRows(archetype_index) != 0) return;

            var archetype = self.archetypeRecord(archetype_index).?;
            while (archetype.chunks.len() > 0) {
                try self.removeChunk(archetype_index, @intCast(archetype.chunks.len() - 1));
                archetype = self.archetypeRecord(archetype_index).?;
            }

            const tail_index = self.archetypes.len() - 1;
            var removed = archetype.*;
            if (archetype_index != tail_index) {
                archetype.* = self.archetypes.items()[tail_index];
                try self.reindexArchetypeEntities(archetype_index);
            }
            _ = self.archetypes.pop();
            removed.deinit();
            try self.rebuildArchetypeIndex();
        }

        fn reindexArchetypeEntities(self: *Self, archetype_index: u32) Error!void {
            const archetype = self.archetypeRecordConst(archetype_index).?;
            for (archetype.chunks.itemsConst(), 0..) |_, chunk_index| {
                try self.reindexChunkEntities(archetype_index, @intCast(chunk_index));
            }
        }

        fn reindexChunkEntities(self: *Self, archetype_index: u32, chunk_index: u32) Error!void {
            const chunk_record = self.chunkRecord(.{
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

        fn rebuildArchetypeIndex(self: *Self) Error!void {
            self.archetype_index.clear();
            for (self.archetypes.itemsConst(), 0..) |archetype, index| {
                if (!self.archetype_index.contains(archetype.fingerprint)) {
                    try self.archetype_index.put(archetype.fingerprint, @intCast(index));
                }
            }
        }

        fn refreshNonfullChunkHint(self: *Self, archetype_index: u32) void {
            const archetype = self.archetypeRecord(archetype_index).?;
            archetype.nonfull_chunk_hint = null;
            for (archetype.chunks.items(), 0..) |*chunk_record, chunk_index| {
                if (chunk_record.chunk.rowCount() < chunk_record.chunk.capacity()) {
                    archetype.nonfull_chunk_hint = @intCast(chunk_index);
                    return;
                }
            }
        }

        fn keyFromEncodedBundle(self: *const Self, bytes: []const u8, entry_count: u32) Error!Key {
            _ = self;
            var key = Key.empty();
            var reader = BundleReader.init(bytes, entry_count);
            while (reader.next()) |entry| {
                key = try key.withId(entry.component_id);
            }
            return key;
        }

        fn writeBundlePayloads(self: *Self, location: EntityLocation, bytes: []const u8, entry_count: u32) Error!void {
            var reader = BundleReader.init(bytes, entry_count);
            while (reader.next()) |entry| {
                try self.writeComponentBytes(location, entry.component_id, entry.payload);
            }
        }

        fn writeComponentBytes(self: *Self, location: EntityLocation, component_id: component_registry_mod.ComponentTypeId, payload: []const u8) Error!void {
            const chunk_record = self.chunkRecord(location).?;
            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                if (index == component_id.value) {
                    if (@sizeOf(T) == 0) {
                        assert(payload.len == 0);
                        return;
                    }
                    assert(payload.len == @sizeOf(T));
                    var value: T = undefined;
                    @memcpy(std.mem.asBytes(&value), payload);
                    chunk_record.chunk.columnSlice(T).?[location.row_index] = value;
                    return;
                }
            }
            unreachable;
        }

        fn findArchetypeIndex(self: *const Self, key: Key) ?u32 {
            const fingerprint = key.fingerprint64();
            if (self.archetype_index.getConst(fingerprint)) |index_ptr| {
                const index = index_ptr.*;
                const archetype = self.archetypeRecordConst(index) orelse return null;
                if (keysEqual(archetype.key, key)) return index;
            }
            for (self.archetypes.itemsConst(), 0..) |archetype, index| {
                if (archetype.fingerprint == fingerprint and keysEqual(archetype.key, key)) {
                    return @intCast(index);
                }
            }
            return null;
        }

        fn archetypeActiveRows(self: *const Self, archetype_index: u32) u32 {
            const archetype = self.archetypeRecordConst(archetype_index).?;
            var total: u32 = 0;
            for (archetype.chunks.itemsConst()) |chunk_record| {
                total += chunk_record.chunk.rowCount();
            }
            return total;
        }

        fn assertSpawnable(self: *const Self, entity: entity_mod.Entity) Error!void {
            if (!entity.isValid()) return error.EntityOutOfRange;
            if (entity.index >= self.entity_locations.len) return error.EntityOutOfRange;
            if (self.locationRaw(entity).?.occupied) {
                if (self.contains(entity)) return error.AlreadyExists;
                return error.EntitySlotOccupied;
            }
        }

        fn locationRaw(self: *const Self, entity: entity_mod.Entity) ?EntityLocation {
            if (!entity.isValid()) return null;
            if (entity.index >= self.entity_locations.len) return null;
            return self.entity_locations[entity.index];
        }

        fn writeLocation(self: *Self, entity: entity_mod.Entity, location: EntityLocation) void {
            assert(location.occupied);
            self.entity_locations[entity.index] = location;
        }

        fn clearLocation(self: *Self, entity: entity_mod.Entity) void {
            self.entity_locations[entity.index] = EntityLocation.invalid();
        }

        fn archetypeRecord(self: *Self, archetype_index: u32) ?*ArchetypeRecord {
            if (archetype_index >= self.archetypes.len()) return null;
            return &self.archetypes.items()[archetype_index];
        }

        fn archetypeRecordConst(self: *const Self, archetype_index: u32) ?*const ArchetypeRecord {
            if (archetype_index >= self.archetypes.len()) return null;
            return &self.archetypes.itemsConst()[archetype_index];
        }

        fn chunkRecord(self: *Self, location: EntityLocation) ?*ChunkRecord {
            const archetype = self.archetypeRecord(location.archetype_index) orelse return null;
            if (location.chunk_index >= archetype.chunks.len()) return null;
            return &archetype.chunks.items()[location.chunk_index];
        }

        fn chunkRecordConst(self: *const Self, location: EntityLocation) ?*const ChunkRecord {
            const archetype = self.archetypeRecordConst(location.archetype_index) orelse return null;
            if (location.chunk_index >= archetype.chunks.len()) return null;
            return &archetype.chunks.itemsConst()[location.chunk_index];
        }

        fn bumpStructuralEpoch(self: *Self) void {
            self.structural_epoch_value +%= 1;
        }

        fn assertInvariants(self: *const Self) void {
            assert(self.archetypes.len() > 0);
            assert(self.archetypes.len() <= self.config.archetypes_max);
            assert(self.total_chunks <= self.config.chunks_max);
            assert(self.active_entities <= self.config.entities_max);
            assert(Registry.count() <= self.config.components_per_archetype_max);
            assert(keysEqual(self.archetypes.itemsConst()[0].key, Key.empty()));

            var occupied_count: u32 = 0;
            for (self.entity_locations, 0..) |location, entity_index| {
                if (!location.occupied) continue;
                occupied_count += 1;
                const chunk_record = self.chunkRecordConst(location).?;
                assert(location.row_index < chunk_record.chunk.rowCount());
                const entity = chunk_record.entities[location.row_index];
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

fn keysEqual(a: anytype, b: @TypeOf(a)) bool {
    return std.meta.eql(a, b);
}

fn introducesUninitializedColumns(comptime Components: anytype, source_key: archetype_key_mod.ArchetypeKey(Components), target_key: archetype_key_mod.ArchetypeKey(Components)) bool {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const component_count: usize = comptime Registry.count();
    inline for (0..component_count) |index| {
        const T = Registry.typeAt(index);
        const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
        if (@sizeOf(T) != 0 and !source_key.containsId(id) and target_key.containsId(id)) return true;
    }
    return false;
}

fn mergeKeys(comptime Components: anytype, source_key: archetype_key_mod.ArchetypeKey(Components), bundle_key: archetype_key_mod.ArchetypeKey(Components)) !archetype_key_mod.ArchetypeKey(Components) {
    var merged = source_key;
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const component_count: usize = comptime Registry.count();
    inline for (0..component_count) |index| {
        const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
        if (bundle_key.containsId(id)) {
            merged = try merged.withId(id);
        }
    }
    return merged;
}

test "archetype store restores the empty archetype and structural epoch surface" {
    const Position = struct { x: f32, y: f32 };
    const Store = ArchetypeStore(.{ Position });

    var store = try Store.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 1,
        .budget = null,
    });
    defer store.deinit();

    try testing.expectEqual(@as(u32, 1), store.archetypeCount());
    try testing.expectEqual(@as(u64, 0), store.structuralEpoch());
}
