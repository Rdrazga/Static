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

const SpawnSetupContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SpawnSetupContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();
        var buffer = world.initCommandBuffer(context.allocator) catch unreachable;
        defer buffer.deinit();

        context.sink = bench.case.blackBox(@as(u64, world.entityCount()) + buffer.pendingSpawnCount());
        assert(world.entityCount() == 0);
        assert(buffer.isEmpty());
    }
};

const InsertSetupContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *InsertSetupContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();
        var buffer = world.initCommandBuffer(context.allocator) catch unreachable;
        defer buffer.deinit();
        var entities: [insert_only_count]static_ecs.Entity = undefined;
        initEmptyEntities(&world, entities[0..]) catch unreachable;

        context.sink = bench.case.blackBox(@as(u64, world.entityCount()) + buffer.pendingSpawnCount());
        assert(world.entityCount() == insert_only_count);
        assert(!world.hasComponent(entities[insert_only_count - 1], Position));
    }
};

const MixedSetupContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *MixedSetupContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();
        var buffer = world.initCommandBuffer(context.allocator) catch unreachable;
        defer buffer.deinit();
        var insert_entities: [mixed_insert_count]static_ecs.Entity = undefined;
        var remove_entities: [mixed_remove_count]static_ecs.Entity = undefined;
        initEmptyEntities(&world, insert_entities[0..]) catch unreachable;
        initTaggedEntities(&world, remove_entities[0..]) catch unreachable;

        context.sink = bench.case.blackBox(@as(u64, world.entityCount()) + buffer.pendingSpawnCount());
        assert(world.entityCount() == mixed_insert_count + mixed_remove_count);
        assert(world.hasComponent(remove_entities[mixed_remove_count - 1], Tag));
    }
};

const SpawnStageContext = struct {
    buffer: *Buffer,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SpawnStageContext = @ptrCast(@alignCast(context_ptr));

        var index: u32 = 0;
        while (index < spawn_only_count) : (index += 1) {
            context.buffer.stageSpawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Tag{},
            }) catch unreachable;
        }

        context.sink = bench.case.blackBox(@as(u64, context.buffer.pendingSpawnCount()));
        assert(!context.buffer.isEmpty());
        assert(context.buffer.pendingSpawnCount() == spawn_only_count);
        context.buffer.clear();
        assert(context.buffer.isEmpty());
    }
};

const InsertStageContext = struct {
    buffer: *Buffer,
    entities: [insert_only_count]static_ecs.Entity,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *InsertStageContext = @ptrCast(@alignCast(context_ptr));

        for (context.entities, 0..) |entity, index| {
            context.buffer.stageInsertBundle(entity, .{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
            }) catch unreachable;
        }

        context.sink = bench.case.blackBox(@as(u64, @intFromBool(!context.buffer.isEmpty())));
        assert(!context.buffer.isEmpty());
        assert(context.buffer.pendingSpawnCount() == 0);
        context.buffer.clear();
        assert(context.buffer.isEmpty());
    }
};

const MixedStageContext = struct {
    buffer: *Buffer,
    insert_entities: [mixed_insert_count]static_ecs.Entity,
    remove_entities: [mixed_remove_count]static_ecs.Entity,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *MixedStageContext = @ptrCast(@alignCast(context_ptr));
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

        context.sink = bench.case.blackBox(@as(u64, context.buffer.pendingSpawnCount()));
        assert(!context.buffer.isEmpty());
        assert(context.buffer.pendingSpawnCount() == mixed_spawn_count);
        context.buffer.clear();
        assert(context.buffer.isEmpty());
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "command_buffer_phase_baselines");
    defer output_dir.close(io);

    var spawn_stage_world = try initWorld(std.heap.page_allocator);
    defer spawn_stage_world.deinit();
    var spawn_stage_buffer = try spawn_stage_world.initCommandBuffer(std.heap.page_allocator);
    defer spawn_stage_buffer.deinit();

    var insert_stage_world = try initWorld(std.heap.page_allocator);
    defer insert_stage_world.deinit();
    var insert_stage_buffer = try insert_stage_world.initCommandBuffer(std.heap.page_allocator);
    defer insert_stage_buffer.deinit();
    var insert_entities: [insert_only_count]static_ecs.Entity = undefined;
    try initEmptyEntities(&insert_stage_world, insert_entities[0..]);

    var mixed_stage_world = try initWorld(std.heap.page_allocator);
    defer mixed_stage_world.deinit();
    var mixed_stage_buffer = try mixed_stage_world.initCommandBuffer(std.heap.page_allocator);
    defer mixed_stage_buffer.deinit();
    var mixed_insert_entities: [mixed_insert_count]static_ecs.Entity = undefined;
    var mixed_remove_entities: [mixed_remove_count]static_ecs.Entity = undefined;
    try initEmptyEntities(&mixed_stage_world, mixed_insert_entities[0..]);
    try initTaggedEntities(&mixed_stage_world, mixed_remove_entities[0..]);

    var spawn_setup_context = SpawnSetupContext{ .allocator = std.heap.page_allocator };
    var insert_setup_context = InsertSetupContext{ .allocator = std.heap.page_allocator };
    var mixed_setup_context = MixedSetupContext{ .allocator = std.heap.page_allocator };
    var spawn_stage_context = SpawnStageContext{ .buffer = &spawn_stage_buffer };
    var insert_stage_context = InsertStageContext{
        .buffer = &insert_stage_buffer,
        .entities = insert_entities,
    };
    var mixed_stage_context = MixedStageContext{
        .buffer = &mixed_stage_buffer,
        .insert_entities = mixed_insert_entities,
        .remove_entities = mixed_remove_entities,
    };

    var case_storage: [6]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_command_buffer_phase_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "spawn_only_setup_world_and_buffer",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "setup", "baseline" },
        .context = &spawn_setup_context,
        .run_fn = SpawnSetupContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "insert_only_setup_world_buffer_and_entities",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "setup", "baseline" },
        .context = &insert_setup_context,
        .run_fn = InsertSetupContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "mixed_setup_world_buffer_and_entities",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "setup", "baseline" },
        .context = &mixed_setup_context,
        .run_fn = MixedSetupContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "spawn_only_stage_and_clear",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "stage", "baseline" },
        .context = &spawn_stage_context,
        .run_fn = SpawnStageContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "insert_only_stage_and_clear",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "stage", "baseline" },
        .context = &insert_stage_context,
        .run_fn = InsertStageContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "mixed_stage_and_clear",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "stage", "baseline" },
        .context = &mixed_stage_context,
        .run_fn = MixedStageContext.run,
    }));

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "command_buffer_phase_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "command_buffer", "phase", "baseline" },
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
    try validateSetupPreflight(allocator);
    try validateStagePreflight(allocator);
}

fn validateSetupPreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();
    var buffer = try world.initCommandBuffer(allocator);
    defer buffer.deinit();
    var insert_entities: [mixed_insert_count]static_ecs.Entity = undefined;
    var remove_entities: [mixed_remove_count]static_ecs.Entity = undefined;
    try initEmptyEntities(&world, insert_entities[0..]);
    try initTaggedEntities(&world, remove_entities[0..]);

    if (world.entityCount() != mixed_insert_count + mixed_remove_count) return error.InvalidPreflight;
    if (!buffer.isEmpty()) return error.InvalidPreflight;
    if (!world.hasComponent(remove_entities[mixed_remove_count - 1], Tag)) return error.InvalidPreflight;
}

fn validateStagePreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();
    var buffer = try world.initCommandBuffer(allocator);
    defer buffer.deinit();
    var insert_entities: [mixed_insert_count]static_ecs.Entity = undefined;
    var remove_entities: [mixed_remove_count]static_ecs.Entity = undefined;
    try initEmptyEntities(&world, insert_entities[0..]);
    try initTaggedEntities(&world, remove_entities[0..]);

    try buffer.stageSpawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Tag{},
    });
    try buffer.stageInsertBundle(insert_entities[0], .{
        Position{ .x = 3, .y = 4 },
        Velocity{ .x = 5, .y = 6 },
    });
    try buffer.stageRemove(remove_entities[0], Tag);

    if (buffer.isEmpty()) return error.InvalidPreflight;
    if (buffer.pendingSpawnCount() != 1) return error.InvalidPreflight;
    buffer.clear();
    if (!buffer.isEmpty()) return error.InvalidPreflight;
}
