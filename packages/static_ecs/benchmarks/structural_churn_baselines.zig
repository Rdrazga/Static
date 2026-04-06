const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const bench_config = support.default_benchmark_config;

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

    var case_storage: [2]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_structural_churn_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "spawn_then_scalar_insert",
        .tags = &[_][]const u8{ "static_ecs", "structural", "scalar", "baseline" },
        .context = &scalar_context,
        .run_fn = SpawnScalarContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "spawn_bundle_fused",
        .tags = &[_][]const u8{ "static_ecs", "structural", "bundle", "baseline" },
        .context = &bundle_context,
        .run_fn = SpawnBundleContext.run,
    }));

    var sample_storage: [bench_config.sample_count * 2]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [2]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(run_result, io, output_dir, support.default_environment_note);
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

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();

    const entity = try world.spawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
        Health{ .value = 5 },
    });
    if (world.componentPtrConst(entity, Velocity).?.x != 3) return error.InvalidPreflight;
}
