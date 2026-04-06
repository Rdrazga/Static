const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const testing = std.testing;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;

const Position = struct { x: f32, y: f32 };
const Tag = struct {};
const World = static_ecs.World(.{ Position, Tag });
const CommandBuffer = static_ecs.CommandBuffer(.{ Position, Tag });

const slot_count: usize = 3;
const command_capacity: usize = 8;

const ActionTag = enum(u32) {
    queue_spawn = 1,
    queue_despawn = 2,
    queue_insert_position = 3,
    queue_remove_position = 4,
    queue_insert_tag = 5,
    queue_remove_tag = 6,
    apply = 7,
};

const violations = [_]checker.Violation{
    .{
        .code = "static_ecs.command_buffer_model",
        .message = "command buffer sequence diverged from the bounded ECS reference model",
    },
};

const PendingOp = union(enum) {
    spawn: u8,
    despawn: u8,
    insert_position: struct {
        slot: u8,
        value: Position,
    },
    remove_position: u8,
    insert_tag: u8,
    remove_tag: u8,
};

const SlotState = struct {
    entity: ?static_ecs.Entity = null,
    position_present: bool = false,
    position: Position = .{ .x = 0, .y = 0 },
    tag_present: bool = false,

    fn clear(self: *@This()) void {
        self.* = .{};
        assert(self.entity == null);
        assert(!self.position_present);
        assert(!self.tag_present);
    }

    fn live(self: *const @This()) bool {
        return self.entity != null;
    }
};

const ShadowKind = enum(u8) {
    empty,
    live,
    reserved_spawn,
};

const ShadowSlot = struct {
    kind: ShadowKind = .empty,
    position_present: bool = false,
    position: Position = .{ .x = 0, .y = 0 },
    tag_present: bool = false,

    fn syncFromActual(self: *@This(), actual: SlotState) void {
        self.kind = if (actual.live()) .live else .empty;
        self.position_present = actual.position_present;
        self.position = actual.position;
        self.tag_present = actual.tag_present;
    }
};

const Context = struct {
    world: World = undefined,
    world_initialized: bool = false,
    command_buffer: CommandBuffer = undefined,
    command_buffer_initialized: bool = false,
    slots: [slot_count]SlotState = [_]SlotState{.{}} ** slot_count,
    shadow_slots: [slot_count]ShadowSlot = [_]ShadowSlot{.{}} ** slot_count,
    pending_ops: [command_capacity]PendingOp = undefined,
    pending_len: usize = 0,
    pending_spawn_count: usize = 0,

    fn resetState(self: *@This()) void {
        if (self.command_buffer_initialized) {
            self.command_buffer.deinit();
            self.command_buffer_initialized = false;
        }
        if (self.world_initialized) {
            self.world.deinit();
            self.world_initialized = false;
        }

        self.world = World.init(testing.allocator, .{
            .entities_max = slot_count,
            .archetypes_max = 8,
            .components_per_archetype_max = 4,
            .chunks_max = 8,
            .chunk_rows_max = 4,
            .command_buffer_entries_max = command_capacity,
            .command_buffer_payload_bytes_max = 256,
            .empty_chunk_retained_max = 0,
            .budget = null,
        }) catch |err| panic("resetState: World.init failed: {s}", .{@errorName(err)});
        self.world_initialized = true;

        self.command_buffer = self.world.initCommandBuffer(testing.allocator) catch |err|
            panic("resetState: World.initCommandBuffer failed: {s}", .{@errorName(err)});
        self.command_buffer_initialized = true;

        for (&self.slots) |*slot| slot.clear();
        self.pending_len = 0;
        self.pending_spawn_count = 0;
        self.syncShadowFromActual();
        assert(self.command_buffer.isEmpty());
        assert(self.world.entityCount() == 0);
    }

    fn validate(self: *@This()) checker.CheckResult {
        assert(self.world_initialized);
        assert(self.command_buffer_initialized);
        assert(self.pending_len == self.command_buffer.len());
        assert(self.pending_spawn_count == self.command_buffer.pendingSpawnCount());

        var digest: u128 = @as(u128, self.world.entityCount());
        var live_count: u32 = 0;

        for (self.slots, 0..) |slot, index| {
            const shadow = self.shadow_slots[index];
            if (slot.entity) |entity| {
                live_count += 1;
                if (!self.world.contains(entity)) {
                    return checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(digest));
                }
                if (self.world.hasComponent(entity, Position) != slot.position_present) {
                    return checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(digest));
                }
                if (self.world.hasComponent(entity, Tag) != slot.tag_present) {
                    return checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(digest));
                }
                if (slot.position_present) {
                    const actual = self.world.componentPtrConst(entity, Position) orelse {
                        return checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(digest));
                    };
                    if (actual.x != slot.position.x or actual.y != slot.position.y) {
                        return checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(digest));
                    }
                } else if (self.world.componentPtrConst(entity, Position) != null) {
                    return checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(digest));
                }
                digest ^= (@as(u128, entity.index) << 32) ^ (@as(u128, entity.generation) << 64);
                digest ^= (@as(u128, @intFromBool(slot.position_present)) << 1);
                digest ^= (@as(u128, @intFromBool(slot.tag_present)) << 2);
            }

            switch (shadow.kind) {
                .empty => {
                    if (slot.live() and self.pending_len == 0) unreachable;
                },
                .live => {
                    if (!slot.live()) {
                        return checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(digest));
                    }
                },
                .reserved_spawn => {},
            }
        }

        if (live_count != self.world.entityCount()) {
            return checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(digest));
        }
        return checker.CheckResult.pass(checker.CheckpointDigest.init(digest));
    }

    fn queueSpawn(self: *@This(), slot_index: usize) checker.CheckResult {
        if (self.command_buffer.len() >= command_capacity) return self.validate();
        if (self.shadow_slots[slot_index].kind != .empty) return self.validate();

        self.command_buffer.stageSpawn() catch return checker.CheckResult.fail(&violations, null);
        self.pending_ops[self.pending_len] = .{ .spawn = @intCast(slot_index) };
        self.pending_len += 1;
        self.pending_spawn_count += 1;
        self.shadow_slots[slot_index] = .{ .kind = .reserved_spawn };
        return self.validate();
    }

    fn queueDespawn(self: *@This(), slot_index: usize) checker.CheckResult {
        if (self.command_buffer.len() >= command_capacity) return self.validate();
        if (self.shadow_slots[slot_index].kind != .live) return self.validate();

        const entity = self.slots[slot_index].entity orelse return self.validate();
        self.command_buffer.stageDespawn(entity) catch return checker.CheckResult.fail(&violations, null);
        self.pending_ops[self.pending_len] = .{ .despawn = @intCast(slot_index) };
        self.pending_len += 1;
        self.shadow_slots[slot_index] = .{};
        return self.validate();
    }

    fn queueInsertPosition(self: *@This(), slot_index: usize, position: Position) checker.CheckResult {
        if (self.command_buffer.len() >= command_capacity) return self.validate();
        if (self.shadow_slots[slot_index].kind != .live) return self.validate();

        const entity = self.slots[slot_index].entity orelse return self.validate();
        self.command_buffer.stageInsert(entity, position) catch return checker.CheckResult.fail(&violations, null);
        self.pending_ops[self.pending_len] = .{
            .insert_position = .{
                .slot = @intCast(slot_index),
                .value = position,
            },
        };
        self.pending_len += 1;
        self.shadow_slots[slot_index].position_present = true;
        self.shadow_slots[slot_index].position = position;
        return self.validate();
    }

    fn queueRemovePosition(self: *@This(), slot_index: usize) checker.CheckResult {
        if (self.command_buffer.len() >= command_capacity) return self.validate();
        if (self.shadow_slots[slot_index].kind != .live) return self.validate();
        if (!self.shadow_slots[slot_index].position_present) return self.validate();

        const entity = self.slots[slot_index].entity orelse return self.validate();
        self.command_buffer.stageRemove(entity, Position) catch return checker.CheckResult.fail(&violations, null);
        self.pending_ops[self.pending_len] = .{ .remove_position = @intCast(slot_index) };
        self.pending_len += 1;
        self.shadow_slots[slot_index].position_present = false;
        self.shadow_slots[slot_index].position = .{ .x = 0, .y = 0 };
        return self.validate();
    }

    fn queueInsertTag(self: *@This(), slot_index: usize) checker.CheckResult {
        if (self.command_buffer.len() >= command_capacity) return self.validate();
        if (self.shadow_slots[slot_index].kind != .live) return self.validate();

        const entity = self.slots[slot_index].entity orelse return self.validate();
        self.command_buffer.stageInsert(entity, Tag{}) catch return checker.CheckResult.fail(&violations, null);
        self.pending_ops[self.pending_len] = .{ .insert_tag = @intCast(slot_index) };
        self.pending_len += 1;
        self.shadow_slots[slot_index].tag_present = true;
        return self.validate();
    }

    fn queueRemoveTag(self: *@This(), slot_index: usize) checker.CheckResult {
        if (self.command_buffer.len() >= command_capacity) return self.validate();
        if (self.shadow_slots[slot_index].kind != .live) return self.validate();
        if (!self.shadow_slots[slot_index].tag_present) return self.validate();

        const entity = self.slots[slot_index].entity orelse return self.validate();
        self.command_buffer.stageRemove(entity, Tag) catch return checker.CheckResult.fail(&violations, null);
        self.pending_ops[self.pending_len] = .{ .remove_tag = @intCast(slot_index) };
        self.pending_len += 1;
        self.shadow_slots[slot_index].tag_present = false;
        return self.validate();
    }

    fn apply(self: *@This()) checker.CheckResult {
        if (self.pending_len == 0) return self.validate();

        var spawned_entities: [slot_count]static_ecs.Entity = undefined;
        const result = self.command_buffer.apply(&self.world, spawned_entities[0..self.pending_spawn_count]) catch {
            return checker.CheckResult.fail(&violations, null);
        };
        if (result.commands_applied != self.pending_len) {
            return checker.CheckResult.fail(&violations, null);
        }
        if (result.spawned_count != self.pending_spawn_count) {
            return checker.CheckResult.fail(&violations, null);
        }

        var spawned_index: usize = 0;
        for (self.pending_ops[0..self.pending_len]) |op| {
            switch (op) {
                .spawn => |slot_index| {
                    const slot = &self.slots[slot_index];
                    slot.* = .{
                        .entity = spawned_entities[spawned_index],
                    };
                    spawned_index += 1;
                },
                .despawn => |slot_index| {
                    self.slots[slot_index].clear();
                },
                .insert_position => |insert_op| {
                    const slot = &self.slots[insert_op.slot];
                    if (!slot.live()) return checker.CheckResult.fail(&violations, null);
                    slot.position_present = true;
                    slot.position = insert_op.value;
                },
                .remove_position => |slot_index| {
                    const slot = &self.slots[slot_index];
                    if (!slot.live()) return checker.CheckResult.fail(&violations, null);
                    slot.position_present = false;
                    slot.position = .{ .x = 0, .y = 0 };
                },
                .insert_tag => |slot_index| {
                    const slot = &self.slots[slot_index];
                    if (!slot.live()) return checker.CheckResult.fail(&violations, null);
                    slot.tag_present = true;
                },
                .remove_tag => |slot_index| {
                    const slot = &self.slots[slot_index];
                    if (!slot.live()) return checker.CheckResult.fail(&violations, null);
                    slot.tag_present = false;
                },
            }
        }

        self.pending_len = 0;
        self.pending_spawn_count = 0;
        self.syncShadowFromActual();
        return self.validate();
    }

    fn syncShadowFromActual(self: *@This()) void {
        for (self.slots, 0..) |slot, index| {
            self.shadow_slots[index].syncFromActual(slot);
        }
    }
};

test "command buffer runtime sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer {
        if (context.command_buffer_initialized) context.command_buffer.deinit();
        if (context.world_initialized) context.world.deinit();
    }

    var action_storage: [24]model.RecordedAction = undefined;
    var reduction_scratch: [24]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_ecs",
            .run_name = "command_buffer_runtime_sequences",
            .base_seed = .init(0x4543_532d_434d_4421),
            .build_mode = .debug,
            .case_count_max = 96,
            .action_count_max = action_storage.len,
        },
        .target = Target{
            .context = &context,
            .reset_fn = reset,
            .next_action_fn = nextAction,
            .step_fn = step,
            .finish_fn = finish,
            .describe_action_fn = describe,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    try testing.expectEqual(@as(u32, 96), summary.executed_case_count);
    try testing.expect(summary.failed_case == null);
}

fn reset(context_ptr: *anyopaque, _: identity.RunIdentity) error{}!void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.resetState();
}

fn nextAction(_: *anyopaque, _: identity.RunIdentity, _: u32, action_seed: seed_mod.Seed) error{}!model.RecordedAction {
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x4543_532d_4d4f_444c);
    const random = prng.random();
    const tag: ActionTag = switch (random.uintLessThan(u32, 7)) {
        0 => .queue_spawn,
        1 => .queue_despawn,
        2 => .queue_insert_position,
        3 => .queue_remove_position,
        4 => .queue_insert_tag,
        5 => .queue_remove_tag,
        else => .apply,
    };
    return .{
        .tag = @intFromEnum(tag),
        .value = random.int(u64),
    };
}

fn step(context_ptr: *anyopaque, _: identity.RunIdentity, _: u32, action: model.RecordedAction) error{}!model.ModelStep {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const tag: ActionTag = @enumFromInt(action.tag);
    const slot_index: usize = @intCast(action.value % slot_count);
    const result = switch (tag) {
        .queue_spawn => context.queueSpawn(slot_index),
        .queue_despawn => context.queueDespawn(slot_index),
        .queue_insert_position => context.queueInsertPosition(slot_index, positionFromValue(action.value)),
        .queue_remove_position => context.queueRemovePosition(slot_index),
        .queue_insert_tag => context.queueInsertTag(slot_index),
        .queue_remove_tag => context.queueRemoveTag(slot_index),
        .apply => context.apply(),
    };
    return .{ .check_result = result };
}

fn finish(context_ptr: *anyopaque, _: identity.RunIdentity, _: u32) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    _ = context.apply();
    return context.validate();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .queue_spawn => "queue_spawn",
            .queue_despawn => "queue_despawn",
            .queue_insert_position => "queue_insert_position",
            .queue_remove_position => "queue_remove_position",
            .queue_insert_tag => "queue_insert_tag",
            .queue_remove_tag => "queue_remove_tag",
            .apply => "apply",
        },
    };
}

fn positionFromValue(value: u64) Position {
    const low: u16 = @truncate(value);
    const high: u16 = @truncate(value >> 16);
    return .{
        .x = @as(f32, @floatFromInt(low % 97)),
        .y = @as(f32, @floatFromInt(high % 89)),
    };
}
