const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const collections = @import("static_collections");
const world_config_mod = @import("world_config.zig");
const entity_mod = @import("entity.zig");
const component_registry_mod = @import("component_registry.zig");

pub fn CommandBuffer(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const component_universe_count: usize = comptime Registry.count();
    const payload_size: usize = comptime maxPayloadSize(Registry);
    const payload_align: comptime_int = comptime maxPayloadAlign(Registry);
    const PayloadBytes = [payload_size]u8;

    return struct {
        const Self = @This();

        pub const Error = world_config_mod.Error || collections.vec.Error || error{
            SpawnOutputTooSmall,
        };

        pub const ApplyResult = struct {
            commands_applied: u32,
            spawned_count: u32,
        };

        const CommandTag = enum(u8) {
            spawn_empty,
            despawn,
            insert,
            remove,
        };

        const InsertCommand = struct {
            entity: entity_mod.Entity,
            component_id: component_registry_mod.ComponentTypeId,
            payload: PayloadBytes align(payload_align),
        };

        const RemoveCommand = struct {
            entity: entity_mod.Entity,
            component_id: component_registry_mod.ComponentTypeId,
        };

        const Command = union(CommandTag) {
            spawn_empty: void,
            despawn: entity_mod.Entity,
            insert: InsertCommand,
            remove: RemoveCommand,
        };

        const CommandVec = collections.vec.Vec(Command);

        config: world_config_mod.WorldConfig,
        commands: CommandVec,
        pending_spawns: u32,

        pub fn init(allocator: std.mem.Allocator, config: world_config_mod.WorldConfig) Error!Self {
            try config.validate();

            var self: Self = .{
                .config = config,
                .commands = try CommandVec.init(allocator, .{
                    .initial_capacity = config.command_buffer_entries_max,
                    .budget = config.budget,
                }),
                .pending_spawns = 0,
            };
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            self.commands.deinit();
            self.* = undefined;
        }

        pub fn len(self: *const Self) u32 {
            self.assertInvariants();
            const len_value: u32 = @intCast(self.commands.len());
            assert(len_value <= self.config.command_buffer_entries_max);
            return len_value;
        }

        pub fn isEmpty(self: *const Self) bool {
            self.assertInvariants();
            return self.commands.len() == 0;
        }

        pub fn pendingSpawnCount(self: *const Self) u32 {
            self.assertInvariants();
            assert(self.pending_spawns <= self.len());
            return self.pending_spawns;
        }

        pub fn clear(self: *Self) void {
            self.assertInvariants();
            self.commands.clear();
            self.pending_spawns = 0;
            assert(self.isEmpty());
            self.assertInvariants();
        }

        pub fn stageSpawn(self: *Self) Error!void {
            self.assertInvariants();
            try self.appendCommand(.{ .spawn_empty = {} });
            self.pending_spawns += 1;
            assert(self.pending_spawns > 0);
            self.assertInvariants();
        }

        pub fn stageDespawn(self: *Self, entity: entity_mod.Entity) Error!void {
            self.assertInvariants();
            assert(entity.isValid());
            try self.appendCommand(.{ .despawn = entity });
            self.assertInvariants();
        }

        pub fn stageInsert(self: *Self, entity: entity_mod.Entity, value: anytype) Error!void {
            const T = @TypeOf(value);
            comptime validateComponentType(T, Registry);

            self.assertInvariants();
            assert(entity.isValid());

            var payload: PayloadBytes align(payload_align) = [_]u8{0} ** payload_size;
            if (@sizeOf(T) != 0) {
                const payload_ptr: *T = @ptrCast(&payload);
                payload_ptr.* = value;
            }

            try self.appendCommand(.{
                .insert = .{
                    .entity = entity,
                    .component_id = Registry.typeId(T).?,
                    .payload = payload,
                },
            });
            self.assertInvariants();
        }

        pub fn stageInsertBundle(self: *Self, entity: entity_mod.Entity, comptime Bundle: anytype) Error!void {
            const fields = tupleFields(Bundle, "CommandBuffer.stageInsertBundle expects a comptime tuple of component values.");
            self.assertInvariants();
            inline for (fields) |field| {
                try self.stageInsert(entity, @field(Bundle, field.name));
            }
            self.assertInvariants();
        }

        pub fn stageRemove(self: *Self, entity: entity_mod.Entity, comptime T: type) Error!void {
            comptime validateComponentType(T, Registry);

            self.assertInvariants();
            assert(entity.isValid());
            try self.appendCommand(.{
                .remove = .{
                    .entity = entity,
                    .component_id = Registry.typeId(T).?,
                },
            });
            self.assertInvariants();
        }

        pub fn stageRemoveBundle(self: *Self, entity: entity_mod.Entity, comptime Types: anytype) Error!void {
            const fields = tupleFields(Types, "CommandBuffer.stageRemoveBundle expects a comptime tuple of component types.");
            self.assertInvariants();
            inline for (fields) |field| {
                const component = @field(Types, field.name);
                if (@TypeOf(component) != type) {
                    @compileError("CommandBuffer.stageRemoveBundle entries must be component types.");
                }
                try self.stageRemove(entity, component);
            }
            self.assertInvariants();
        }

        pub fn apply(self: *Self, world: anytype, spawned_entities_out: []entity_mod.Entity) anyerror!ApplyResult {
            self.assertInvariants();
            if (spawned_entities_out.len < self.pending_spawns) return error.SpawnOutputTooSmall;

            var command_index: usize = 0;
            var spawned_count: u32 = 0;

            while (command_index < self.commands.len()) {
                const command = self.commands.itemsConst()[command_index];
                self.applyOne(world, command, spawned_entities_out, &spawned_count) catch |err| {
                    self.consumeAppliedPrefix(@intCast(command_index));
                    self.assertInvariants();
                    return err;
                };
                command_index += 1;
            }

            const result: ApplyResult = .{
                .commands_applied = @intCast(command_index),
                .spawned_count = spawned_count,
            };
            self.clear();
            assert(result.commands_applied <= self.config.command_buffer_entries_max);
            return result;
        }

        fn appendCommand(self: *Self, command: Command) Error!void {
            assert(self.commands.len() <= self.config.command_buffer_entries_max);
            if (self.commands.len() >= self.config.command_buffer_entries_max) return error.NoSpaceLeft;
            try self.commands.append(command);
            assert(self.commands.len() <= self.config.command_buffer_entries_max);
        }

        fn applyOne(self: *Self, world: anytype, command: Command, spawned_entities_out: []entity_mod.Entity, spawned_count: *u32) anyerror!void {
            _ = self;
            switch (command) {
                .spawn_empty => {
                    const entity = try world.spawn();
                    const output_index: usize = spawned_count.*;
                    assert(output_index < spawned_entities_out.len);
                    spawned_entities_out[output_index] = entity;
                    spawned_count.* += 1;
                },
                .despawn => |entity| {
                    try world.despawn(entity);
                },
                .insert => |insert_command| {
                    inline for (0..component_universe_count) |index| {
                        const T = Registry.typeAt(index);
                        const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                        if (insert_command.component_id.value == id.value) {
                            if (@sizeOf(T) == 0) {
                                try world.insert(insert_command.entity, std.mem.zeroes(T));
                            } else {
                                const payload_ptr: *const T = @ptrCast(&insert_command.payload);
                                try world.insert(insert_command.entity, payload_ptr.*);
                            }
                            return;
                        }
                    }
                    unreachable;
                },
                .remove => |remove_command| {
                    inline for (0..component_universe_count) |index| {
                        const T = Registry.typeAt(index);
                        const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                        if (remove_command.component_id.value == id.value) {
                            try world.remove(remove_command.entity, T);
                            return;
                        }
                    }
                    unreachable;
                },
            }
        }

        fn consumeAppliedPrefix(self: *Self, applied_count: u32) void {
            self.assertInvariants();
            if (applied_count == 0) return;

            const total_count = self.commands.len();
            const applied_count_usize: usize = applied_count;
            assert(applied_count_usize <= total_count);

            const remaining_count = total_count - applied_count_usize;
            if (remaining_count > 0) {
                const items = self.commands.items();
                @memmove(items[0..remaining_count], items[applied_count_usize..total_count]);
            }
            while (self.commands.len() > remaining_count) {
                _ = self.commands.pop();
            }
            self.recountPendingSpawns();
            self.assertInvariants();
        }

        fn recountPendingSpawns(self: *Self) void {
            var spawn_count: u32 = 0;
            for (self.commands.itemsConst()) |command| {
                if (command == .spawn_empty) {
                    spawn_count += 1;
                }
            }
            self.pending_spawns = spawn_count;
        }

        fn assertInvariants(self: *const Self) void {
            assert(self.commands.len() <= self.config.command_buffer_entries_max);

            var spawn_count: u32 = 0;
            for (self.commands.itemsConst()) |command| {
                if (command == .spawn_empty) {
                    spawn_count += 1;
                }
            }
            assert(spawn_count == self.pending_spawns);
        }
    };
}

fn validateComponentType(comptime T: type, comptime Registry: type) void {
    if (!Registry.contains(T)) {
        @compileError("CommandBuffer component operations require a type from the component universe.");
    }
}

fn tupleFields(comptime Tuple: anytype, comptime err: []const u8) []const std.builtin.Type.StructField {
    const info = @typeInfo(@TypeOf(Tuple));
    switch (info) {
        .@"struct" => |struct_info| {
            if (!struct_info.is_tuple) {
                @compileError(err);
            }
            return struct_info.fields;
        },
        else => @compileError(err),
    }
}

fn maxPayloadSize(comptime Registry: type) usize {
    const component_universe_count: usize = comptime Registry.count();
    var size_max: usize = 1;
    inline for (0..component_universe_count) |index| {
        size_max = @max(size_max, @sizeOf(Registry.typeAt(index)));
    }
    return size_max;
}

fn maxPayloadAlign(comptime Registry: type) usize {
    const component_universe_count: usize = comptime Registry.count();
    var align_max: usize = 1;
    inline for (0..component_universe_count) |index| {
        align_max = @max(align_max, @alignOf(Registry.typeAt(index)));
    }
    return align_max;
}

test "command buffer stages deterministic structural commands and returns spawned entities in apply order" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Tag = struct {};
    const world_mod = @import("world.zig");
    const World = world_mod.World(.{ Position, Velocity, Tag });
    const Buffer = CommandBuffer(.{ Position, Velocity, Tag });

    var world = try World.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 8,
        .chunk_rows_max = 4,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 8,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer world.deinit();

    var buffer = try Buffer.init(testing.allocator, world.config);
    defer buffer.deinit();

    const first = try world.spawn();
    const second = try world.spawn();
    try world.insert(first, Position{ .x = 1, .y = 2 });
    try world.insert(second, Position{ .x = 3, .y = 4 });

    try buffer.stageInsert(first, Velocity{ .x = 10, .y = 20 });
    try buffer.stageInsert(first, Tag{});
    try buffer.stageDespawn(second);
    try buffer.stageSpawn();

    var spawned: [1]entity_mod.Entity = undefined;
    const result = try buffer.apply(&world, spawned[0..]);

    try testing.expectEqual(@as(u32, 4), result.commands_applied);
    try testing.expectEqual(@as(u32, 1), result.spawned_count);
    try testing.expect(world.contains(spawned[0]));
    try testing.expect(world.hasComponent(first, Velocity));
    try testing.expect(world.hasComponent(first, Tag));
    try testing.expect(!world.contains(second));
    try testing.expectEqual(@as(u32, 2), world.entityCount());
    try testing.expect(buffer.isEmpty());
}

test "command buffer preserves the failing command and later tail after partial apply" {
    const Position = struct { x: f32, y: f32 };
    const world_mod = @import("world.zig");
    const World = world_mod.World(.{ Position });
    const Buffer = CommandBuffer(.{ Position });

    var world = try World.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 4,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 4,
        .side_index_entries_max = 0,
        .budget = null,
    });
    defer world.deinit();

    var buffer = try Buffer.init(testing.allocator, world.config);
    defer buffer.deinit();

    const entity = try world.spawn();
    const stale = entity;
    try world.despawn(entity);

    try buffer.stageSpawn();
    try buffer.stageDespawn(stale);
    try buffer.stageSpawn();

    var spawned: [2]entity_mod.Entity = undefined;
    try testing.expectError(error.EntityNotFound, buffer.apply(&world, spawned[0..]));
    try testing.expectEqual(@as(u32, 2), buffer.len());
    try testing.expectEqual(@as(u32, 1), buffer.pendingSpawnCount());
    try testing.expectEqual(@as(u32, 1), world.entityCount());
}
