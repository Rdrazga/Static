const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const collections = @import("static_collections");
const world_config_mod = @import("world_config.zig");
const entity_mod = @import("entity.zig");
const component_registry_mod = @import("component_registry.zig");
const bundle_codec_mod = @import("bundle_codec.zig");

pub fn CommandBuffer(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const component_universe_count: usize = comptime Registry.count();

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
            spawn_bundle,
            despawn,
            insert_bundle,
            remove,
        };

        const EncodedBundleRef = struct {
            payload_offset: u32,
            payload_len: u32,
            entry_count: u32,
        };

        const SpawnBundleCommand = struct {
            bundle: EncodedBundleRef,
        };

        const InsertBundleCommand = struct {
            entity: entity_mod.Entity,
            bundle: EncodedBundleRef,
        };

        const RemoveCommand = struct {
            entity: entity_mod.Entity,
            component_id: component_registry_mod.ComponentTypeId,
        };

        const Command = union(CommandTag) {
            spawn_empty: void,
            spawn_bundle: SpawnBundleCommand,
            despawn: entity_mod.Entity,
            insert_bundle: InsertBundleCommand,
            remove: RemoveCommand,
        };

        const CommandVec = collections.vec.Vec(Command);
        const ByteVec = collections.vec.Vec(u8);

        config: world_config_mod.WorldConfig,
        commands: CommandVec,
        payload_bytes: ByteVec,
        pending_spawns: u32,

        pub fn init(allocator: std.mem.Allocator, config: world_config_mod.WorldConfig) Error!Self {
            try config.validate();

            var self: Self = .{
                .config = config,
                .commands = try CommandVec.init(allocator, .{
                    .initial_capacity = config.command_buffer_entries_max,
                    .budget = config.budget,
                }),
                .payload_bytes = try ByteVec.init(allocator, .{
                    .initial_capacity = config.command_buffer_payload_bytes_max,
                    .budget = config.budget,
                }),
                .pending_spawns = 0,
            };
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            self.payload_bytes.deinit();
            self.commands.deinit();
            self.* = undefined;
        }

        pub fn len(self: *const Self) u32 {
            self.assertInvariants();
            return @intCast(self.commands.len());
        }

        pub fn isEmpty(self: *const Self) bool {
            self.assertInvariants();
            return self.commands.len() == 0;
        }

        pub fn pendingSpawnCount(self: *const Self) u32 {
            self.assertInvariants();
            return self.pending_spawns;
        }

        pub fn clear(self: *Self) void {
            self.assertInvariants();
            self.commands.clear();
            self.payload_bytes.clear();
            self.pending_spawns = 0;
            self.assertInvariants();
        }

        pub fn stageSpawn(self: *Self) Error!void {
            self.assertInvariants();
            try self.appendCommand(.{ .spawn_empty = {} });
            self.pending_spawns += 1;
            self.assertInvariants();
        }

        pub fn stageSpawnBundle(self: *Self, bundle: anytype) Error!void {
            _ = tupleFields(@TypeOf(bundle), "CommandBuffer.stageSpawnBundle expects a comptime tuple of component values.");
            self.assertInvariants();
            if (self.commands.len() >= self.config.command_buffer_entries_max) return error.NoSpaceLeft;
            const payload_len_before = self.payload_bytes.len();
            errdefer self.truncatePayloadBytes(payload_len_before);
            const encoded = try self.appendEncodedBundle(bundle);
            if (encoded.entry_count == 0) return self.stageSpawn();

            try self.appendCommand(.{
                .spawn_bundle = .{
                    .bundle = encoded,
                },
            });
            self.pending_spawns += 1;
            self.assertInvariants();
        }

        pub fn stageDespawn(self: *Self, entity: entity_mod.Entity) Error!void {
            self.assertInvariants();
            assert(entity.isValid());
            try self.appendCommand(.{ .despawn = entity });
            self.assertInvariants();
        }

        pub fn stageInsert(self: *Self, entity: entity_mod.Entity, value: anytype) Error!void {
            comptime validateComponentType(@TypeOf(value), Registry);
            try self.stageInsertBundle(entity, .{value});
        }

        pub fn stageInsertBundle(self: *Self, entity: entity_mod.Entity, bundle: anytype) Error!void {
            _ = tupleFields(@TypeOf(bundle), "CommandBuffer.stageInsertBundle expects a comptime tuple of component values.");
            self.assertInvariants();
            assert(entity.isValid());
            if (self.commands.len() >= self.config.command_buffer_entries_max) return error.NoSpaceLeft;
            const payload_len_before = self.payload_bytes.len();
            errdefer self.truncatePayloadBytes(payload_len_before);
            const encoded = try self.appendEncodedBundle(bundle);
            if (encoded.entry_count == 0) return;

            try self.appendCommand(.{
                .insert_bundle = .{
                    .entity = entity,
                    .bundle = encoded,
                },
            });
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
            return result;
        }

        fn appendCommand(self: *Self, command: Command) Error!void {
            if (self.commands.len() >= self.config.command_buffer_entries_max) return error.NoSpaceLeft;
            try self.commands.append(command);
        }

        fn appendEncodedBundle(self: *Self, bundle: anytype) Error!EncodedBundleRef {
            const encoded_len: comptime_int = comptime bundle_codec_mod.encodedBundleSizeForType(Components, @TypeOf(bundle));
            const payload_offset: u32 = @intCast(self.payload_bytes.len());
            const payload_len: u32 = @intCast(encoded_len);
            const payload_end = std.math.add(u32, payload_offset, payload_len) catch return error.Overflow;
            if (payload_end > self.config.command_buffer_payload_bytes_max) return error.NoSpaceLeft;

            try self.payload_bytes.ensureCapacity(payload_end);
            const len_before = self.payload_bytes.len();
            self.payload_bytes.storage.items.len = payload_end;
            @memset(self.payload_bytes.items()[len_before..payload_end], 0);
            const entry_count = bundle_codec_mod.encodeBundleTuple(
                Components,
                bundle,
                self.payload_bytes.items()[len_before..payload_end],
            );
            return .{
                .payload_offset = payload_offset,
                .payload_len = payload_len,
                .entry_count = entry_count,
            };
        }

        fn applyOne(self: *Self, world: anytype, command: Command, spawned_entities_out: []entity_mod.Entity, spawned_count: *u32) anyerror!void {
            switch (command) {
                .spawn_empty => {
                    const entity = try world.spawn();
                    spawned_entities_out[spawned_count.*] = entity;
                    spawned_count.* += 1;
                },
                .spawn_bundle => |spawn_command| {
                    const entity = try world.spawnBundleFromEncoded(self.payloadSlice(spawn_command.bundle), spawn_command.bundle.entry_count);
                    spawned_entities_out[spawned_count.*] = entity;
                    spawned_count.* += 1;
                },
                .despawn => |entity| {
                    try world.despawn(entity);
                },
                .insert_bundle => |insert_command| {
                    try world.insertBundleEncoded(insert_command.entity, self.payloadSlice(insert_command.bundle), insert_command.bundle.entry_count);
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

        fn payloadSlice(self: *const Self, bundle: EncodedBundleRef) []const u8 {
            const start: usize = bundle.payload_offset;
            const end: usize = start + bundle.payload_len;
            return self.payload_bytes.itemsConst()[start..end];
        }

        fn consumeAppliedPrefix(self: *Self, applied_count: u32) void {
            self.assertInvariants();
            if (applied_count == 0) return;

            const total_count = self.commands.len();
            const applied_count_usize: usize = applied_count;
            const remaining_count = total_count - applied_count_usize;

            const consumed_payload_bytes = self.payloadBytesConsumedByPrefix(applied_count_usize);
            if (remaining_count > 0) {
                const items = self.commands.items();
                @memmove(items[0..remaining_count], items[applied_count_usize..total_count]);
                for (items[0..remaining_count]) |*command| {
                    self.rebaseCommandPayload(command, consumed_payload_bytes);
                }
            }
            while (self.commands.len() > remaining_count) {
                _ = self.commands.pop();
            }

            const payload_len_before = self.payload_bytes.len();
            const payload_remaining = payload_len_before - consumed_payload_bytes;
            if (payload_remaining > 0) {
                const bytes = self.payload_bytes.items();
                @memmove(bytes[0..payload_remaining], bytes[consumed_payload_bytes..payload_len_before]);
            }
            while (self.payload_bytes.len() > payload_remaining) {
                _ = self.payload_bytes.pop();
            }
            self.recountPendingSpawns();
            self.assertInvariants();
        }

        fn payloadBytesConsumedByPrefix(self: *const Self, applied_count: usize) usize {
            var consumed: usize = 0;
            for (self.commands.itemsConst()[0..applied_count]) |command| {
                consumed = @max(consumed, self.commandPayloadEnd(command));
            }
            return consumed;
        }

        fn commandPayloadEnd(self: *const Self, command: Command) usize {
            _ = self;
            return switch (command) {
                .spawn_bundle => |bundle_command| bundle_command.bundle.payload_offset + bundle_command.bundle.payload_len,
                .insert_bundle => |bundle_command| bundle_command.bundle.payload_offset + bundle_command.bundle.payload_len,
                else => 0,
            };
        }

        fn rebaseCommandPayload(self: *const Self, command: *Command, delta: usize) void {
            _ = self;
            switch (command.*) {
                .spawn_bundle => |*bundle_command| bundle_command.bundle.payload_offset -= @intCast(delta),
                .insert_bundle => |*bundle_command| bundle_command.bundle.payload_offset -= @intCast(delta),
                else => {},
            }
        }

        fn recountPendingSpawns(self: *Self) void {
            var spawn_count: u32 = 0;
            for (self.commands.itemsConst()) |command| {
                switch (command) {
                    .spawn_empty, .spawn_bundle => spawn_count += 1,
                    else => {},
                }
            }
            self.pending_spawns = spawn_count;
        }

        fn truncatePayloadBytes(self: *Self, target_len: usize) void {
            while (self.payload_bytes.len() > target_len) {
                _ = self.payload_bytes.pop();
            }
        }

        fn assertInvariants(self: *const Self) void {
            if (!std.debug.runtime_safety) return;
            assert(self.commands.len() <= self.config.command_buffer_entries_max);
            assert(self.payload_bytes.len() <= self.config.command_buffer_payload_bytes_max);

            var spawn_count: u32 = 0;
            for (self.commands.itemsConst()) |command| {
                switch (command) {
                    .spawn_empty => spawn_count += 1,
                    .spawn_bundle => |bundle_command| {
                        spawn_count += 1;
                        assert(bundle_command.bundle.payload_offset + bundle_command.bundle.payload_len <= self.payload_bytes.len());
                    },
                    .insert_bundle => |bundle_command| {
                        assert(bundle_command.bundle.payload_offset + bundle_command.bundle.payload_len <= self.payload_bytes.len());
                    },
                    else => {},
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

fn tupleFields(comptime TupleType: type, comptime err: []const u8) []const std.builtin.Type.StructField {
    const info = @typeInfo(TupleType);
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

test "command buffer stores bundle inserts as one command with compact payload bytes" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Buffer = CommandBuffer(.{ Position, Velocity });

    var buffer = try Buffer.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 8,
        .chunk_rows_max = 4,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer buffer.deinit();

    try buffer.stageInsertBundle(.{ .index = 1, .generation = 1 }, .{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
    });

    try testing.expectEqual(@as(u32, 1), buffer.len());
    try testing.expectEqual(@as(u32, 0), buffer.pendingSpawnCount());
}

test "command buffer applies bundle spawns and inserts in order" {
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
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 512,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    var buffer = try Buffer.init(testing.allocator, world.config);
    defer buffer.deinit();

    const existing = try world.spawn();
    try buffer.stageInsertBundle(existing, .{
        Position{ .x = 10, .y = 20 },
        Velocity{ .x = 30, .y = 40 },
    });
    try buffer.stageSpawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Tag{},
    });

    var spawned: [1]entity_mod.Entity = undefined;
    const result = try buffer.apply(&world, spawned[0..]);

    try testing.expectEqual(@as(u32, 2), result.commands_applied);
    try testing.expectEqual(@as(u32, 1), result.spawned_count);
    try testing.expectEqual(@as(f32, 10), world.componentPtrConst(existing, Position).?.x);
    try testing.expect(world.hasComponent(existing, Velocity));
    try testing.expect(world.hasComponent(spawned[0], Position));
    try testing.expect(world.hasComponent(spawned[0], Tag));
}

test "command buffer failed spawn bundle staging rolls payload bytes back" {
    const Position = struct { x: f32, y: f32 };
    const Buffer = CommandBuffer(.{Position});

    var buffer = try Buffer.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .command_buffer_entries_max = 1,
        .command_buffer_payload_bytes_max = 128,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer buffer.deinit();

    try buffer.stageDespawn(.{ .index = 0, .generation = 1 });
    try testing.expectEqual(@as(usize, 0), buffer.payload_bytes.len());

    try testing.expectError(error.NoSpaceLeft, buffer.stageSpawnBundle(.{
        Position{ .x = 1, .y = 2 },
    }));
    try testing.expectEqual(@as(u32, 1), buffer.len());
    try testing.expectEqual(@as(u32, 0), buffer.pendingSpawnCount());
    try testing.expectEqual(@as(usize, 0), buffer.payload_bytes.len());
}

test "command buffer failed insert bundle staging preserves existing payload bytes" {
    const Position = struct { x: f32, y: f32 };
    const Buffer = CommandBuffer(.{Position});

    var buffer = try Buffer.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .command_buffer_entries_max = 1,
        .command_buffer_payload_bytes_max = 128,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer buffer.deinit();

    try buffer.stageSpawnBundle(.{
        Position{ .x = 1, .y = 2 },
    });
    const payload_len_before = buffer.payload_bytes.len();

    try testing.expectError(error.NoSpaceLeft, buffer.stageInsertBundle(.{ .index = 0, .generation = 1 }, .{
        Position{ .x = 3, .y = 4 },
    }));
    try testing.expectEqual(@as(u32, 1), buffer.len());
    try testing.expectEqual(@as(u32, 1), buffer.pendingSpawnCount());
    try testing.expectEqual(payload_len_before, buffer.payload_bytes.len());
}
