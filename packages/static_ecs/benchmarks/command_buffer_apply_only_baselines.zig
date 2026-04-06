const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config: bench.config.BenchmarkConfig = .{
    .mode = .full,
    .warmup_iterations = 16,
    .measure_iterations = 1,
    .sample_count = 32,
};

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

const SpawnApplyOnlyContext = struct {
    allocator: std.mem.Allocator,
    world: World = undefined,
    buffer: Buffer = undefined,
    world_ready: bool = false,
    sink: u64 = 0,
    spawned: [spawn_only_count]static_ecs.Entity = undefined,

    fn prepare(context_ptr: *anyopaque, phase: bench.case.BenchmarkRunPhase, run_index: u32) void {
        _ = phase;
        _ = run_index;
        const context: *SpawnApplyOnlyContext = @ptrCast(@alignCast(context_ptr));
        context.resetWorldAndBuffer() catch unreachable;

        var index: u32 = 0;
        while (index < spawn_only_count) : (index += 1) {
            context.buffer.stageSpawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Tag{},
            }) catch unreachable;
        }

        assert(context.buffer.pendingSpawnCount() == spawn_only_count);
        assert(context.world.entityCount() == 0);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *SpawnApplyOnlyContext = @ptrCast(@alignCast(context_ptr));
        assert(context.world_ready);

        const result = context.buffer.apply(&context.world, context.spawned[0..]) catch unreachable;
        context.sink = bench.case.blackBox(@as(u64, result.spawned_count) + context.world.entityCount());
        assert(result.spawned_count == spawn_only_count);
        assert(context.buffer.isEmpty());
        assert(context.world.hasComponent(context.spawned[spawn_only_count - 1], Tag));
    }

    fn deinit(context: *SpawnApplyOnlyContext) void {
        if (!context.world_ready) return;
        context.buffer.deinit();
        context.world.deinit();
        context.world_ready = false;
    }

    fn resetWorldAndBuffer(context: *SpawnApplyOnlyContext) !void {
        context.deinit();
        context.world = try initWorld(context.allocator);
        context.buffer = try context.world.initCommandBuffer(context.allocator);
        context.world_ready = true;
    }
};

const InsertApplyOnlyContext = struct {
    allocator: std.mem.Allocator,
    world: World = undefined,
    buffer: Buffer = undefined,
    world_ready: bool = false,
    sink: u64 = 0,
    entities: [insert_only_count]static_ecs.Entity = undefined,
    no_spawned: [0]static_ecs.Entity = .{},

    fn prepare(context_ptr: *anyopaque, phase: bench.case.BenchmarkRunPhase, run_index: u32) void {
        _ = phase;
        _ = run_index;
        const context: *InsertApplyOnlyContext = @ptrCast(@alignCast(context_ptr));
        context.resetWorldAndBuffer() catch unreachable;
        initEmptyEntities(&context.world, context.entities[0..]) catch unreachable;

        for (context.entities, 0..) |entity, index| {
            context.buffer.stageInsertBundle(entity, .{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
            }) catch unreachable;
        }

        assert(context.buffer.pendingSpawnCount() == 0);
        assert(context.world.entityCount() == insert_only_count);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *InsertApplyOnlyContext = @ptrCast(@alignCast(context_ptr));
        assert(context.world_ready);

        const result = context.buffer.apply(&context.world, context.no_spawned[0..]) catch unreachable;
        context.sink = bench.case.blackBox(@as(u64, result.commands_applied) + context.world.entityCount());
        assert(result.spawned_count == 0);
        assert(context.buffer.isEmpty());
        assert(context.world.hasComponent(context.entities[insert_only_count - 1], Velocity));
    }

    fn deinit(context: *InsertApplyOnlyContext) void {
        if (!context.world_ready) return;
        context.buffer.deinit();
        context.world.deinit();
        context.world_ready = false;
    }

    fn resetWorldAndBuffer(context: *InsertApplyOnlyContext) !void {
        context.deinit();
        context.world = try initWorld(context.allocator);
        context.buffer = try context.world.initCommandBuffer(context.allocator);
        context.world_ready = true;
    }
};

const MixedApplyOnlyContext = struct {
    allocator: std.mem.Allocator,
    world: World = undefined,
    buffer: Buffer = undefined,
    world_ready: bool = false,
    sink: u64 = 0,
    insert_entities: [mixed_insert_count]static_ecs.Entity = undefined,
    remove_entities: [mixed_remove_count]static_ecs.Entity = undefined,
    spawned: [mixed_spawn_count]static_ecs.Entity = undefined,

    fn prepare(context_ptr: *anyopaque, phase: bench.case.BenchmarkRunPhase, run_index: u32) void {
        _ = phase;
        _ = run_index;
        const context: *MixedApplyOnlyContext = @ptrCast(@alignCast(context_ptr));
        context.resetWorldAndBuffer() catch unreachable;
        initEmptyEntities(&context.world, context.insert_entities[0..]) catch unreachable;
        initTaggedEntities(&context.world, context.remove_entities[0..]) catch unreachable;

        const max_count = @max(mixed_spawn_count, @max(mixed_insert_count, mixed_remove_count));
        var index: u32 = 0;
        while (index < max_count) : (index += 1) {
            if (index < mixed_spawn_count) {
                context.buffer.stageSpawnBundle(.{
                    Position{ .x = @floatFromInt(index), .y = 1 },
                    Tag{},
                }) catch unreachable;
            }
            if (index < mixed_insert_count) {
                context.buffer.stageInsertBundle(context.insert_entities[index], .{
                    Position{ .x = @floatFromInt(index), .y = 1 },
                    Velocity{ .x = 2, .y = @floatFromInt(index) },
                }) catch unreachable;
            }
            if (index < mixed_remove_count) {
                context.buffer.stageRemove(context.remove_entities[index], Tag) catch unreachable;
            }
        }

        assert(context.buffer.pendingSpawnCount() == mixed_spawn_count);
        assert(context.world.entityCount() == mixed_insert_count + mixed_remove_count);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *MixedApplyOnlyContext = @ptrCast(@alignCast(context_ptr));
        assert(context.world_ready);

        const result = context.buffer.apply(&context.world, context.spawned[0..]) catch unreachable;
        context.sink = bench.case.blackBox(@as(u64, result.commands_applied) + context.world.entityCount());
        assert(result.spawned_count == mixed_spawn_count);
        assert(context.buffer.isEmpty());
        assert(!context.world.hasComponent(context.remove_entities[mixed_remove_count - 1], Tag));
    }

    fn deinit(context: *MixedApplyOnlyContext) void {
        if (!context.world_ready) return;
        context.buffer.deinit();
        context.world.deinit();
        context.world_ready = false;
    }

    fn resetWorldAndBuffer(context: *MixedApplyOnlyContext) !void {
        context.deinit();
        context.world = try initWorld(context.allocator);
        context.buffer = try context.world.initCommandBuffer(context.allocator);
        context.world_ready = true;
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "command_buffer_apply_only_baselines");
    defer output_dir.close(io);

    var spawn_context = SpawnApplyOnlyContext{ .allocator = std.heap.page_allocator };
    defer spawn_context.deinit();
    var insert_context = InsertApplyOnlyContext{ .allocator = std.heap.page_allocator };
    defer insert_context.deinit();
    var mixed_context = MixedApplyOnlyContext{ .allocator = std.heap.page_allocator };
    defer mixed_context.deinit();

    var case_storage: [3]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_command_buffer_apply_only_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "spawn_bundle_apply_only",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "apply_only", "baseline" },
        .context = &spawn_context,
        .run_fn = SpawnApplyOnlyContext.run,
        .prepare_context = &spawn_context,
        .prepare_fn = SpawnApplyOnlyContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "insert_bundle_apply_only",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "apply_only", "baseline" },
        .context = &insert_context,
        .run_fn = InsertApplyOnlyContext.run,
        .prepare_context = &insert_context,
        .prepare_fn = InsertApplyOnlyContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "mixed_spawn_insert_remove_apply_only",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "apply_only", "baseline" },
        .context = &mixed_context,
        .run_fn = MixedApplyOnlyContext.run,
        .prepare_context = &mixed_context,
        .prepare_fn = MixedApplyOnlyContext.prepare,
    }));

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "command_buffer_apply_only_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "command_buffer", "apply_only", "baseline" },
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
    var spawn_context = SpawnApplyOnlyContext{ .allocator = allocator };
    defer spawn_context.deinit();
    SpawnApplyOnlyContext.prepare(&spawn_context, .warmup, 0);
    SpawnApplyOnlyContext.run(&spawn_context);

    var insert_context = InsertApplyOnlyContext{ .allocator = allocator };
    defer insert_context.deinit();
    InsertApplyOnlyContext.prepare(&insert_context, .warmup, 0);
    InsertApplyOnlyContext.run(&insert_context);

    var mixed_context = MixedApplyOnlyContext{ .allocator = allocator };
    defer mixed_context.deinit();
    MixedApplyOnlyContext.prepare(&mixed_context, .warmup, 0);
    MixedApplyOnlyContext.run(&mixed_context);
}
