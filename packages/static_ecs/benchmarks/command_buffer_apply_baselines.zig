const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const bench_config = support.default_benchmark_config;

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Tag = struct {};
const World = static_ecs.World(.{ Position, Velocity, Tag });
const Buffer = static_ecs.CommandBuffer(.{ Position, Velocity, Tag });

const command_count: u32 = 256;
const spawn_only_count: u32 = command_count;
const insert_only_count: u32 = command_count;
const mixed_spawn_count: u32 = command_count / 3;
const mixed_insert_count: u32 = command_count / 3;
const mixed_remove_count: u32 = command_count - mixed_spawn_count - mixed_insert_count;

const SpawnApplyContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SpawnApplyContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();
        var buffer = world.initCommandBuffer(context.allocator) catch unreachable;
        defer buffer.deinit();

        var index: u32 = 0;
        while (index < spawn_only_count) : (index += 1) {
            buffer.stageSpawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Tag{},
            }) catch unreachable;
        }

        var spawned: [spawn_only_count]static_ecs.Entity = undefined;
        const result = buffer.apply(&world, spawned[0..]) catch unreachable;
        context.sink = bench.case.blackBox(@as(u64, result.spawned_count) + world.entityCount());
        assert(result.spawned_count == spawn_only_count);
        assert(world.hasComponent(spawned[spawn_only_count - 1], Tag));
    }
};

const InsertApplyContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *InsertApplyContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();
        var buffer = world.initCommandBuffer(context.allocator) catch unreachable;
        defer buffer.deinit();
        var entities: [insert_only_count]static_ecs.Entity = undefined;
        initEmptyEntities(&world, entities[0..]) catch unreachable;

        for (entities, 0..) |entity, index| {
            buffer.stageInsertBundle(entity, .{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
            }) catch unreachable;
        }

        var no_spawned: [0]static_ecs.Entity = .{};
        const result = buffer.apply(&world, no_spawned[0..]) catch unreachable;
        context.sink = bench.case.blackBox(@as(u64, result.commands_applied) + world.entityCount());
        assert(result.spawned_count == 0);
        assert(world.hasComponent(entities[insert_only_count - 1], Velocity));
    }
};

const MixedApplyContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *MixedApplyContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();
        var buffer = world.initCommandBuffer(context.allocator) catch unreachable;
        defer buffer.deinit();
        var insert_entities: [mixed_insert_count]static_ecs.Entity = undefined;
        var remove_entities: [mixed_remove_count]static_ecs.Entity = undefined;
        initEmptyEntities(&world, insert_entities[0..]) catch unreachable;
        initTaggedEntities(&world, remove_entities[0..]) catch unreachable;

        const max_count = @max(mixed_spawn_count, @max(mixed_insert_count, mixed_remove_count));
        var index: u32 = 0;
        while (index < max_count) : (index += 1) {
            if (index < mixed_spawn_count) {
                buffer.stageSpawnBundle(.{
                    Position{ .x = @floatFromInt(index), .y = 1 },
                    Tag{},
                }) catch unreachable;
            }
            if (index < mixed_insert_count) {
                buffer.stageInsertBundle(insert_entities[index], .{
                    Position{ .x = @floatFromInt(index), .y = 1 },
                    Velocity{ .x = 2, .y = @floatFromInt(index) },
                }) catch unreachable;
            }
            if (index < mixed_remove_count) {
                buffer.stageRemove(remove_entities[index], Tag) catch unreachable;
            }
        }

        var spawned: [mixed_spawn_count]static_ecs.Entity = undefined;
        const result = buffer.apply(&world, spawned[0..]) catch unreachable;
        context.sink = bench.case.blackBox(@as(u64, result.commands_applied) + world.entityCount());
        assert(result.spawned_count == mixed_spawn_count);
        assert(!world.hasComponent(remove_entities[mixed_remove_count - 1], Tag));
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "command_buffer_staged_apply_baselines");
    defer output_dir.close(io);

    var spawn_context = SpawnApplyContext{ .allocator = std.heap.page_allocator };
    var insert_context = InsertApplyContext{ .allocator = std.heap.page_allocator };
    var mixed_context = MixedApplyContext{ .allocator = std.heap.page_allocator };
    var case_storage: [3]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_command_buffer_staged_apply_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "spawn_bundle_stage_and_apply",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "staged_apply", "baseline" },
        .context = &spawn_context,
        .run_fn = SpawnApplyContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "insert_bundle_stage_and_apply",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "staged_apply", "baseline" },
        .context = &insert_context,
        .run_fn = InsertApplyContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "mixed_spawn_insert_remove_stage_and_apply",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "staged_apply", "baseline" },
        .context = &mixed_context,
        .run_fn = MixedApplyContext.run,
    }));

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "command_buffer_staged_apply_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "command_buffer", "staged_apply", "baseline" },
    });
}

fn initWorld(allocator: std.mem.Allocator) !World {
    return World.init(allocator, .{
        .entities_max = command_count * 2,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 64,
        .chunk_rows_max = 32,
        .command_buffer_entries_max = command_count * 2,
        .command_buffer_payload_bytes_max = command_count * 160,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });
}

fn initEmptyEntities(world: *World, entities_out: []static_ecs.Entity) !void {
    for (entities_out) |*entity| {
        entity.* = try world.spawn();
    }
}

fn initTaggedEntities(world: *World, entities_out: []static_ecs.Entity) !void {
    for (entities_out, 0..) |*entity, index| {
        entity.* = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(index), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(index) },
            Tag{},
        });
    }
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    try validateSpawnApplyPreflight(allocator);
    try validateInsertApplyPreflight(allocator);
    try validateMixedApplyPreflight(allocator);
}

fn validateSpawnApplyPreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();
    var buffer = try world.initCommandBuffer(allocator);
    defer buffer.deinit();

    try buffer.stageSpawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
        Tag{},
    });
    var spawned: [1]static_ecs.Entity = undefined;
    const result = try buffer.apply(&world, spawned[0..]);
    if (result.spawned_count != 1) return error.InvalidPreflight;
    if (!world.hasComponent(spawned[0], Tag)) return error.InvalidPreflight;
}

fn validateInsertApplyPreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();
    var buffer = try world.initCommandBuffer(allocator);
    defer buffer.deinit();

    const entity = try world.spawn();
    try buffer.stageInsertBundle(entity, .{
        Position{ .x = 5, .y = 6 },
        Velocity{ .x = 7, .y = 8 },
    });
    var no_spawned: [0]static_ecs.Entity = .{};
    _ = try buffer.apply(&world, no_spawned[0..]);
    if (!world.hasComponent(entity, Position)) return error.InvalidPreflight;
    if (!world.hasComponent(entity, Velocity)) return error.InvalidPreflight;
}

fn validateMixedApplyPreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();
    var buffer = try world.initCommandBuffer(allocator);
    defer buffer.deinit();

    const insert_entity = try world.spawn();
    const remove_entity = try world.spawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
        Tag{},
    });
    try buffer.stageSpawnBundle(.{
        Position{ .x = 9, .y = 10 },
        Tag{},
    });
    try buffer.stageInsertBundle(insert_entity, .{
        Position{ .x = 11, .y = 12 },
        Velocity{ .x = 13, .y = 14 },
    });
    try buffer.stageRemove(remove_entity, Tag);

    var spawned: [1]static_ecs.Entity = undefined;
    const result = try buffer.apply(&world, spawned[0..]);
    if (result.spawned_count != 1) return error.InvalidPreflight;
    if (!world.hasComponent(insert_entity, Velocity)) return error.InvalidPreflight;
    if (world.hasComponent(remove_entity, Tag)) return error.InvalidPreflight;
}
