const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 128,
    .measure_iterations = 8192,
    .sample_count = 8,
};

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { value: f32 };
const World = static_ecs.World(.{ Position, Velocity, Health });
const Buffer = static_ecs.CommandBuffer(.{ Position, Velocity, Health });

const entity_count: u32 = 1024;

const ComponentPtrContext = struct {
    world: *World,
    entity: static_ecs.Entity,
    sink: f32 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *ComponentPtrContext = @ptrCast(@alignCast(context_ptr));
        const position = context.world.componentPtrConst(context.entity, Position).?;
        context.sink = bench.case.blackBox(position.x + position.y);
        assert(context.sink > 0);
    }
};

const HasComponentContext = struct {
    world: *World,
    entity: static_ecs.Entity,
    sink: u32 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *HasComponentContext = @ptrCast(@alignCast(context_ptr));
        const has_position = context.world.hasComponent(context.entity, Position);
        const has_velocity = context.world.hasComponent(context.entity, Velocity);
        context.sink = bench.case.blackBox(@as(u32, @intFromBool(has_position and has_velocity)));
        assert(context.sink == 1);
    }
};

const IteratorStartupContext = struct {
    world: *World,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *IteratorStartupContext = @ptrCast(@alignCast(context_ptr));
        var view = context.world.view(.{
            static_ecs.Read(Position),
            static_ecs.Read(Velocity),
        });
        var it = view.iterator();
        const batch = it.next().?;
        const first_position = batch.read(Position)[0];
        context.sink = bench.case.blackBox(@as(u64, batch.len()) + @as(u64, @intFromFloat(first_position.x)));
        assert(batch.len() != 0);
        assert(context.sink != 0);
    }
};

const StageSpawnBundleContext = struct {
    buffer: *Buffer,
    sink: u32 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *StageSpawnBundleContext = @ptrCast(@alignCast(context_ptr));
        context.buffer.stageSpawnBundle(.{
            Position{ .x = 1, .y = 2 },
            Velocity{ .x = 3, .y = 4 },
        }) catch unreachable;
        context.sink = bench.case.blackBox(context.buffer.pendingSpawnCount());
        assert(context.sink == 1);
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
    var output_dir = try support.openOutputDir(io, "micro_hotpaths_baselines");
    defer output_dir.close(io);

    var world = try initWorld(std.heap.page_allocator);
    defer world.deinit();
    var buffer = try Buffer.init(std.heap.page_allocator, world.config);
    defer buffer.deinit();

    const tracked_entity = try findTrackedEntity(&world);

    var ptr_context = ComponentPtrContext{ .world = &world, .entity = tracked_entity };
    var has_context = HasComponentContext{ .world = &world, .entity = tracked_entity };
    var iterator_context = IteratorStartupContext{ .world = &world };
    var stage_context = StageSpawnBundleContext{ .buffer = &buffer };

    var case_storage: [4]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_micro_hotpaths_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "component_ptr_const_hit",
        .tags = &[_][]const u8{ "static_ecs", "micro", "lookup", "baseline" },
        .context = &ptr_context,
        .run_fn = ComponentPtrContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "has_component_hit",
        .tags = &[_][]const u8{ "static_ecs", "micro", "lookup", "baseline" },
        .context = &has_context,
        .run_fn = HasComponentContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "iterator_startup_first_batch_dense",
        .tags = &[_][]const u8{ "static_ecs", "micro", "iterator", "baseline" },
        .context = &iterator_context,
        .run_fn = IteratorStartupContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "command_buffer_stage_spawn_bundle_single",
        .tags = &[_][]const u8{ "static_ecs", "micro", "command_buffer", "baseline" },
        .context = &stage_context,
        .run_fn = StageSpawnBundleContext.run,
    }));

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "micro_hotpaths_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "micro", "hotpaths", "baseline" },
    });
}

fn initWorld(allocator: std.mem.Allocator) !World {
    var world = try World.init(allocator, .{
        .entities_max = entity_count,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 32,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = 32,
        .command_buffer_payload_bytes_max = 2048,
        .empty_chunk_retained_max = 1,
        .budget = null,
    });

    var index: u32 = 0;
    while (index < entity_count) : (index += 1) {
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(index + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(index + 1) },
            Health{ .value = @floatFromInt((index % 32) + 1) },
        });
    }
    return world;
}

fn findTrackedEntity(world: *World) !static_ecs.Entity {
    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
    });
    var it = view.iterator();
    const batch = it.next() orelse return error.InvalidPreflight;
    const entity = batch.entities()[0];
    if (!world.hasComponent(entity, Health)) return error.InvalidPreflight;
    return entity;
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();

    const entity = try findTrackedEntity(&world);
    if (world.componentPtrConst(entity, Position).?.x <= 0) return error.InvalidPreflight;
    if (!world.hasComponent(entity, Velocity)) return error.InvalidPreflight;

    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
    });
    var it = view.iterator();
    const batch = it.next() orelse return error.InvalidPreflight;
    if (batch.len() == 0) return error.InvalidPreflight;

    var buffer = try Buffer.init(allocator, world.config);
    defer buffer.deinit();
    try buffer.stageSpawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
    });
    if (buffer.pendingSpawnCount() != 1) return error.InvalidPreflight;
}
