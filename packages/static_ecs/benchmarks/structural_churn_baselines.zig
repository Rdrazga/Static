const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 8,
    .measure_iterations = 64,
    .sample_count = 8,
};

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { value: i32 };
const World = static_ecs.World(.{ Position, Velocity, Health });

const entity_count: u32 = 256;

const SpawnScalarContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SpawnScalarContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();

        var count: u32 = 0;
        while (count < entity_count) : (count += 1) {
            const entity = world.spawn() catch unreachable;
            world.insert(entity, Position{ .x = @floatFromInt(count), .y = 1 }) catch unreachable;
            world.insert(entity, Velocity{ .x = 2, .y = @floatFromInt(count) }) catch unreachable;
            world.insert(entity, Health{ .value = @intCast(count) }) catch unreachable;
        }

        context.sink = bench.case.blackBox(@as(u64, world.entityCount()));
        assert(context.sink == entity_count);
        assert(world.chunkCount() != 0);
    }
};

const SpawnBundleContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SpawnBundleContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();

        var count: u32 = 0;
        while (count < entity_count) : (count += 1) {
            _ = world.spawnBundle(.{
                Position{ .x = @floatFromInt(count), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(count) },
                Health{ .value = @intCast(count) },
            }) catch unreachable;
        }

        context.sink = bench.case.blackBox(@as(u64, world.entityCount()));
        assert(context.sink == entity_count);
        assert(world.chunkCount() != 0);
    }
};

const InsertScalarContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *InsertScalarContext = @ptrCast(@alignCast(context_ptr));
        var entities: [entity_count]static_ecs.Entity = undefined;
        var world = initPositionOnlyWorld(context.allocator, entities[0..]) catch unreachable;
        defer world.deinit();

        for (entities, 0..) |entity, index| {
            world.insert(entity, Velocity{ .x = 2, .y = @floatFromInt(index) }) catch unreachable;
            world.insert(entity, Health{ .value = @intCast(index) }) catch unreachable;
        }

        context.sink = bench.case.blackBox(@as(u64, world.entityCount()) + world.chunkCount());
        assert(context.sink >= entity_count);
        assert(world.hasComponent(entities[entity_count - 1], Health));
    }
};

const InsertBundleContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *InsertBundleContext = @ptrCast(@alignCast(context_ptr));
        var entities: [entity_count]static_ecs.Entity = undefined;
        var world = initPositionOnlyWorld(context.allocator, entities[0..]) catch unreachable;
        defer world.deinit();

        for (entities, 0..) |entity, index| {
            world.insertBundle(entity, .{
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Health{ .value = @intCast(index) },
            }) catch unreachable;
        }

        context.sink = bench.case.blackBox(@as(u64, world.entityCount()) + world.chunkCount());
        assert(context.sink >= entity_count);
        assert(world.hasComponent(entities[entity_count - 1], Health));
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "structural_churn_baselines");
    defer output_dir.close(io);

    var scalar_context = SpawnScalarContext{ .allocator = std.heap.page_allocator };
    var bundle_context = SpawnBundleContext{ .allocator = std.heap.page_allocator };
    var insert_scalar_context = InsertScalarContext{ .allocator = std.heap.page_allocator };
    var insert_bundle_context = InsertBundleContext{ .allocator = std.heap.page_allocator };

    var case_storage: [4]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_structural_churn_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "spawn_then_scalar_insert",
        .tags = &[_][]const u8{ "static_ecs", "structural", "spawn", "scalar" },
        .context = &scalar_context,
        .run_fn = SpawnScalarContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "spawn_bundle_fused",
        .tags = &[_][]const u8{ "static_ecs", "structural", "spawn", "bundle" },
        .context = &bundle_context,
        .run_fn = SpawnBundleContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "live_entities_scalar_transition",
        .tags = &[_][]const u8{ "static_ecs", "structural", "live", "scalar" },
        .context = &insert_scalar_context,
        .run_fn = InsertScalarContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "live_entities_bundle_transition",
        .tags = &[_][]const u8{ "static_ecs", "structural", "live", "bundle" },
        .context = &insert_bundle_context,
        .run_fn = InsertBundleContext.run,
    }));

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "structural_churn_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "structural", "churn", "baseline" },
    });
}

fn initWorld(allocator: std.mem.Allocator) !World {
    return World.init(allocator, .{
        .entities_max = entity_count,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 64,
        .chunk_rows_max = 32,
        .command_buffer_entries_max = entity_count * 4,
        .command_buffer_payload_bytes_max = entity_count * 128,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });
}

fn initPositionOnlyWorld(allocator: std.mem.Allocator, entities_out: []static_ecs.Entity) !World {
    assert(entities_out.len == entity_count);

    var world = try initWorld(allocator);
    for (entities_out, 0..) |*entity, index| {
        entity.* = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(index), .y = 1 },
        });
    }
    return world;
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var spawn_world = try initWorld(allocator);
    defer spawn_world.deinit();

    const spawned = try spawn_world.spawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
        Health{ .value = 5 },
    });
    if (spawn_world.componentPtrConst(spawned, Velocity).?.x != 3) return error.InvalidPreflight;

    var live_entities: [entity_count]static_ecs.Entity = undefined;
    var live_world = try initPositionOnlyWorld(allocator, live_entities[0..]);
    defer live_world.deinit();

    try live_world.insertBundle(live_entities[0], .{
        Velocity{ .x = 7, .y = 8 },
        Health{ .value = 9 },
    });
    if (!live_world.hasComponent(live_entities[0], Velocity)) return error.InvalidPreflight;
    if (!live_world.hasComponent(live_entities[0], Health)) return error.InvalidPreflight;
}
