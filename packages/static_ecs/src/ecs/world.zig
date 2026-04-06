const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const world_config_mod = @import("world_config.zig");
const entity_mod = @import("entity.zig");
const entity_pool_mod = @import("entity_pool.zig");
const component_registry_mod = @import("component_registry.zig");
const archetype_key_mod = @import("archetype_key.zig");
const chunk_mod = @import("chunk.zig");
const archetype_store_mod = @import("archetype_store.zig");
const bundle_codec_mod = @import("bundle_codec.zig");
const query_mod = @import("query.zig");
const view_mod = @import("view.zig");
const command_buffer_mod = @import("command_buffer.zig");
const memory = @import("static_memory");

pub fn World(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);

    return struct {
        const Self = @This();

        pub const Error = world_config_mod.Error || entity_pool_mod.Error || archetype_store_mod.ArchetypeStore(Components).Error || error{
            EntityNotAllocated,
        };
        pub const ComponentRegistry = Registry;
        pub const ArchetypeKey = archetype_key_mod.ArchetypeKey(Components);
        pub const Chunk = chunk_mod.Chunk(Components);
        pub const ArchetypeStore = archetype_store_mod.ArchetypeStore(Components);
        pub const Query = query_mod.Query;
        pub const View = view_mod.View;
        pub const CommandBuffer = command_buffer_mod.CommandBuffer(Components);

        config: world_config_mod.WorldConfig,
        entity_pool: entity_pool_mod.EntityPool,
        archetype_store: ArchetypeStore,

        pub fn init(allocator: std.mem.Allocator, config: world_config_mod.WorldConfig) Error!Self {
            try config.validate();

            const component_count = Registry.count();
            if (component_count > config.components_per_archetype_max) return error.InvalidConfig;

            var entity_pool = try entity_pool_mod.EntityPool.init(allocator, .{
                .entities_max = config.entities_max,
                .budget = config.budget,
            });
            errdefer entity_pool.deinit();

            var self: Self = .{
                .config = config,
                .entity_pool = entity_pool,
                .archetype_store = try ArchetypeStore.init(allocator, config),
            };
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            self.archetype_store.deinit();
            self.entity_pool.deinit();
            self.* = undefined;
        }

        pub fn spawn(self: *Self) Error!entity_mod.Entity {
            self.assertInvariants();
            const entity = try self.entity_pool.allocate();
            errdefer self.entity_pool.release(entity) catch {};
            try self.archetype_store.spawn(entity);
            assert(entity.isValid());
            assert(self.contains(entity));
            self.assertInvariants();
            return entity;
        }

        pub fn spawnBundle(self: *Self, bundle: anytype) Error!entity_mod.Entity {
            self.assertInvariants();
            const entity = try self.entity_pool.allocate();
            errdefer self.entity_pool.release(entity) catch {};
            const encoded = try self.encodeBundleAlloc(bundle);
            defer self.freeEncodedBundleScratch(encoded.bytes);
            try self.spawnBundleEncoded(entity, encoded.bytes, encoded.entry_count);
            assert(self.contains(entity));
            self.assertInvariants();
            return entity;
        }

        pub fn despawn(self: *Self, entity: entity_mod.Entity) Error!void {
            self.assertInvariants();
            try self.archetype_store.despawn(entity);
            try self.entity_pool.release(entity);
            assert(!self.entity_pool.contains(entity));
            self.assertInvariants();
        }

        pub fn contains(self: *const Self, entity: entity_mod.Entity) bool {
            self.assertInvariants();
            const pool_contains = self.entity_pool.contains(entity);
            const store_contains = self.archetype_store.contains(entity);
            assert(pool_contains == store_contains);
            return pool_contains;
        }

        pub fn entityCount(self: *const Self) u32 {
            self.assertInvariants();
            const entity_count = self.entity_pool.activeCount();
            assert(entity_count == self.archetype_store.activeCount());
            assert(entity_count <= self.config.entities_max);
            return entity_count;
        }

        pub fn componentCount(self: *const Self) u32 {
            self.assertInvariants();
            const component_count = Registry.count();
            assert(component_count <= self.config.components_per_archetype_max);
            return component_count;
        }

        pub fn componentTypeId(self: *const Self, comptime T: type) ?component_registry_mod.ComponentTypeId {
            self.assertInvariants();
            const maybe_id = Registry.typeId(T);
            if (maybe_id) |id| assert(id.value < Registry.count());
            if (maybe_id == null) assert(!Registry.contains(T));
            return maybe_id;
        }

        pub fn emptyArchetypeKey(self: *const Self) ArchetypeKey {
            self.assertInvariants();
            return ArchetypeKey.empty();
        }

        pub fn archetypeCount(self: *const Self) u32 {
            self.assertInvariants();
            return self.archetype_store.archetypeCount();
        }

        pub fn chunkCount(self: *const Self) u32 {
            self.assertInvariants();
            return self.archetype_store.chunkCount();
        }

        pub fn moveToArchetype(self: *Self, entity: entity_mod.Entity, key: ArchetypeKey) Error!void {
            self.assertInvariants();
            try self.archetype_store.moveToArchetype(entity, key);
            assert(self.contains(entity));
            self.assertInvariants();
        }

        pub fn hasComponent(self: *const Self, entity: entity_mod.Entity, comptime T: type) bool {
            self.assertInvariants();
            return self.archetype_store.hasComponent(entity, T);
        }

        pub fn insert(self: *Self, entity: entity_mod.Entity, value: anytype) Error!void {
            const T = @TypeOf(value);
            self.assertInvariants();
            try self.archetype_store.insertComponent(entity, T, value);
            assert(self.hasComponent(entity, T));
            self.assertInvariants();
        }

        pub fn insertBundle(self: *Self, entity: entity_mod.Entity, bundle: anytype) Error!void {
            self.assertInvariants();
            const encoded = try self.encodeBundleAlloc(bundle);
            defer self.freeEncodedBundleScratch(encoded.bytes);
            try self.insertBundleEncoded(entity, encoded.bytes, encoded.entry_count);
            self.assertInvariants();
        }

        pub fn remove(self: *Self, entity: entity_mod.Entity, comptime T: type) Error!void {
            self.assertInvariants();
            try self.archetype_store.removeComponent(entity, T);
            assert(!self.hasComponent(entity, T));
            self.assertInvariants();
        }

        pub fn archetypeKeyOf(self: *const Self, entity: entity_mod.Entity) ?ArchetypeKey {
            self.assertInvariants();
            return self.archetype_store.archetypeKeyOf(entity);
        }

        pub fn componentPtr(self: *Self, entity: entity_mod.Entity, comptime T: type) ?*T {
            self.assertInvariants();
            return self.archetype_store.componentPtr(entity, T);
        }

        pub fn componentPtrConst(self: *const Self, entity: entity_mod.Entity, comptime T: type) ?*const T {
            self.assertInvariants();
            return self.archetype_store.componentPtrConst(entity, T);
        }

        pub fn view(self: *Self, comptime Accesses: anytype) view_mod.View(Components, Accesses) {
            self.assertInvariants();
            return view_mod.View(Components, Accesses).init(&self.archetype_store);
        }

        pub fn initCommandBuffer(self: *const Self, allocator: std.mem.Allocator) command_buffer_mod.CommandBuffer(Components).Error!CommandBuffer {
            self.assertInvariants();
            return CommandBuffer.init(allocator, self.config);
        }

        pub fn spawnBundleEncoded(self: *Self, entity: entity_mod.Entity, bytes: []const u8, entry_count: u32) Error!void {
            if (!self.entity_pool.contains(entity)) return error.EntityNotAllocated;
            try self.archetype_store.spawnBundleEncoded(entity, bytes, entry_count);
            assert(self.contains(entity));
            self.assertInvariants();
        }

        pub fn spawnBundleFromEncoded(self: *Self, bytes: []const u8, entry_count: u32) Error!entity_mod.Entity {
            self.assertInvariants();
            const entity = try self.entity_pool.allocate();
            errdefer self.entity_pool.release(entity) catch {};
            try self.spawnBundleEncoded(entity, bytes, entry_count);
            assert(self.contains(entity));
            self.assertInvariants();
            return entity;
        }

        pub fn insertBundleEncoded(self: *Self, entity: entity_mod.Entity, bytes: []const u8, entry_count: u32) Error!void {
            self.assertInvariants();
            try self.archetype_store.insertBundleEncoded(entity, bytes, entry_count);
            assert(self.contains(entity));
            self.assertInvariants();
        }

        fn encodeBundleAlloc(self: *Self, bundle: anytype) Error!struct {
            bytes: []u8,
            entry_count: u32,
        } {
            const encoded_len: comptime_int = comptime bundle_codec_mod.encodedBundleSizeForType(Components, @TypeOf(bundle));
            if (encoded_len == 0) {
                return .{
                    .bytes = &.{},
                    .entry_count = 0,
                };
            }

            const bytes = self.archetype_store.allocator.alloc(u8, encoded_len) catch return error.OutOfMemory;
            errdefer self.archetype_store.allocator.free(bytes);
            const entry_count = bundle_codec_mod.encodeBundleTuple(Components, bundle, bytes);
            return .{
                .bytes = bytes,
                .entry_count = entry_count,
            };
        }

        fn freeEncodedBundleScratch(self: *Self, bytes: []const u8) void {
            if (bytes.len == 0) return;
            self.archetype_store.allocator.free(@constCast(bytes));
        }

        fn assertInvariants(self: *const Self) void {
            if (!std.debug.runtime_safety) return;
            assert(self.entity_pool.capacity() == self.config.entities_max);
            assert(Registry.count() <= self.config.components_per_archetype_max);
            assert(self.archetype_store.activeCount() == self.entity_pool.activeCount());
        }
    };
}

test "world validates config against the typed component universe" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const TestWorld = World(.{ Position, Velocity });

    try testing.expectError(error.InvalidConfig, TestWorld.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 1,
        .chunks_max = 2,
        .chunk_rows_max = 8,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    }));
}

test "world spawns, despawns, and reuses entity slots safely" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const TestWorld = World(.{ Position, Velocity });

    var world = try TestWorld.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 2,
        .chunk_rows_max = 8,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    const first = try world.spawn();
    try testing.expect(world.contains(first));
    try testing.expectEqual(@as(u32, 1), world.entityCount());
    try testing.expectEqual(@as(u32, 2), world.componentCount());
    try testing.expectEqual(@as(u32, 0), world.componentTypeId(Position).?.value);
    try testing.expectEqual(@as(u32, 1), world.componentTypeId(Velocity).?.value);
    try testing.expectEqual(@as(u32, 0), world.emptyArchetypeKey().count());

    try world.despawn(first);
    try testing.expect(!world.contains(first));
    try testing.expectEqual(@as(u32, 0), world.entityCount());

    const second = try world.spawn();
    try testing.expect(second.index == first.index);
    try testing.expect(second.generation != first.generation);
}

test "world keeps stale entities out after archetype mutation and same-slot reuse" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const TestWorld = World(.{ Position, Velocity });

    var world = try TestWorld.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 4,
        .chunk_rows_max = 8,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    const first = try world.spawn();
    try world.insert(first, Position{ .x = 12, .y = 24 });

    try testing.expectEqual(@as(u32, 2), world.archetypeCount());
    try testing.expectEqual(@as(f32, 12), world.componentPtrConst(first, Position).?.x);
    try testing.expectEqual(@as(u32, 1), world.chunkCount());

    try world.despawn(first);
    try testing.expect(!world.contains(first));

    const second = try world.spawn();
    try testing.expectEqual(first.index, second.index);
    try testing.expect(second.generation != first.generation);
    try testing.expect(!world.contains(first));
    try testing.expect(world.contains(second));
    try testing.expectEqual(@as(u32, 0), world.archetypeKeyOf(second).?.count());
}

test "world view iterates typed chunk batches over matching archetypes" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Health = struct { value: i32 };
    const Tag = struct {};
    const TestWorld = World(.{ Position, Velocity, Health, Tag });

    var world = try TestWorld.init(testing.allocator, .{
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

    const first = try world.spawn();
    const second = try world.spawn();
    const third = try world.spawn();
    const fourth = try world.spawn();

    try world.insert(first, Position{ .x = 1, .y = 2 });
    try world.insert(first, Velocity{ .x = 10, .y = 20 });
    try world.insert(second, Position{ .x = 3, .y = 4 });
    try world.insert(second, Velocity{ .x = 30, .y = 40 });
    try world.insert(third, Position{ .x = 5, .y = 6 });
    try world.insert(third, Velocity{ .x = 50, .y = 60 });
    try world.insert(third, Health{ .value = 77 });
    try world.insert(fourth, Position{ .x = 7, .y = 8 });
    try world.insert(fourth, Velocity{ .x = 70, .y = 80 });
    try world.insert(fourth, Tag{});

    var view = world.view(.{
        query_mod.Write(Position),
        query_mod.Read(Velocity),
        query_mod.OptionalRead(Health),
        query_mod.Exclude(Tag),
    });
    var it = view.iterator();

    const first_batch = it.next().?;
    try testing.expectEqual(@as(usize, 2), first_batch.len());
    try testing.expectEqual(first, first_batch.entities()[0]);
    try testing.expectEqual(second, first_batch.entities()[1]);
    try testing.expect(first_batch.optionalRead(Health) == null);

    var mutable_first_batch = first_batch;
    mutable_first_batch.write(Position)[1].x = 33;
    try testing.expectEqual(@as(f32, 33), world.componentPtrConst(second, Position).?.x);

    const second_batch = it.next().?;
    try testing.expectEqual(@as(usize, 1), second_batch.len());
    try testing.expectEqual(third, second_batch.entities()[0]);
    const second_health = second_batch.optionalRead(Health).?;
    try testing.expectEqual(@as(i32, 77), second_health[0].value);
    try testing.expect(it.next() == null);
}

test "world rejects raw value-component additions through moveToArchetype and supports typed insert remove" {
    const Position = struct { x: f32, y: f32 };
    const Tag = struct {};
    const TestWorld = World(.{ Position, Tag });

    var world = try TestWorld.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 4,
        .chunk_rows_max = 8,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    const entity = try world.spawn();

    try testing.expectError(error.ComponentInitRequired, world.moveToArchetype(entity, TestWorld.ArchetypeKey.fromTypes(.{ Position })));

    try world.insert(entity, Position{ .x = 11, .y = 13 });
    try testing.expect(world.hasComponent(entity, Position));
    try testing.expectEqual(@as(f32, 11), world.componentPtrConst(entity, Position).?.x);

    try world.insert(entity, Tag{});
    try testing.expect(world.hasComponent(entity, Tag));
    try world.remove(entity, Position);
    try testing.expect(!world.hasComponent(entity, Position));
    try testing.expect(world.hasComponent(entity, Tag));
}

test "world supports fused spawnBundle and insertBundle admission" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Tag = struct {};
    const TestWorld = World(.{ Position, Velocity, Tag });

    var world = try TestWorld.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 8,
        .chunk_rows_max = 4,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 512,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    const spawned = try world.spawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Tag{},
    });
    try testing.expect(world.hasComponent(spawned, Position));
    try testing.expect(world.hasComponent(spawned, Tag));
    try testing.expectEqual(@as(f32, 1), world.componentPtrConst(spawned, Position).?.x);

    const existing = try world.spawn();
    try world.insertBundle(existing, .{
        Position{ .x = 10, .y = 20 },
        Velocity{ .x = 30, .y = 40 },
    });
    try testing.expect(world.hasComponent(existing, Position));
    try testing.expect(world.hasComponent(existing, Velocity));
    try testing.expectEqual(@as(f32, 30), world.componentPtrConst(existing, Velocity).?.x);
}

test "world init releases entity-pool reservations when archetype store init fails" {
    const Position = struct { x: f32, y: f32 };
    const TestWorld = World(.{ Position });

    var probe_budget = try memory.budget.Budget.init(1024);
    var probe_pool = try entity_pool_mod.EntityPool.init(testing.allocator, .{
        .entities_max = 4,
        .budget = &probe_budget,
    });
    const pool_used = probe_budget.used();
    probe_pool.deinit();
    try testing.expectEqual(@as(u64, 0), probe_budget.used());

    var budget = try memory.budget.Budget.init(@intCast(pool_used));
    try testing.expectError(error.NoSpaceLeft, TestWorld.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 2,
        .chunk_rows_max = 4,
        .command_buffer_entries_max = 4,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = &budget,
    }));
    try testing.expectEqual(@as(u64, 0), budget.used());
}

test "world bundle routes accept large bounded bundle payloads" {
    const Large = struct { bytes: [16 * 1024]u8 };
    const Tag = struct {};
    const TestWorld = World(.{ Large, Tag });

    var first_value: Large = .{ .bytes = [_]u8{0} ** (16 * 1024) };
    first_value.bytes[0] = 7;
    first_value.bytes[first_value.bytes.len - 1] = 9;

    var second_value: Large = .{ .bytes = [_]u8{1} ** (16 * 1024) };
    second_value.bytes[0] = 3;
    second_value.bytes[second_value.bytes.len - 1] = 5;

    var world = try TestWorld.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .command_buffer_entries_max = 4,
        .command_buffer_payload_bytes_max = 64 * 1024,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    const spawned = try world.spawnBundle(.{
        first_value,
        Tag{},
    });
    try testing.expect(world.hasComponent(spawned, Large));
    try testing.expectEqual(@as(u8, 7), world.componentPtrConst(spawned, Large).?.bytes[0]);
    try testing.expectEqual(@as(u8, 9), world.componentPtrConst(spawned, Large).?.bytes[first_value.bytes.len - 1]);

    const existing = try world.spawn();
    try world.insertBundle(existing, .{
        second_value,
        Tag{},
    });
    try testing.expect(world.hasComponent(existing, Large));
    try testing.expectEqual(@as(u8, 3), world.componentPtrConst(existing, Large).?.bytes[0]);
    try testing.expectEqual(@as(u8, 5), world.componentPtrConst(existing, Large).?.bytes[second_value.bytes.len - 1]);
}
