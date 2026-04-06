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

const ApplyContext = struct {
    allocator: std.mem.Allocator,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *ApplyContext = @ptrCast(@alignCast(context_ptr));
        var world = initWorld(context.allocator) catch unreachable;
        defer world.deinit();
        var buffer = world.initCommandBuffer(context.allocator) catch unreachable;
        defer buffer.deinit();

        var index: u32 = 0;
        while (index < command_count) : (index += 1) {
            if (index % 2 == 0) {
                buffer.stageSpawnBundle(.{
                    Position{ .x = @floatFromInt(index), .y = 1 },
                    Tag{},
                }) catch unreachable;
            } else {
                const entity = world.spawn() catch unreachable;
                buffer.stageInsertBundle(entity, .{
                    Position{ .x = @floatFromInt(index), .y = 1 },
                    Velocity{ .x = 2, .y = @floatFromInt(index) },
                }) catch unreachable;
            }
        }

        var spawned: [command_count]static_ecs.Entity = undefined;
        const result = buffer.apply(&world, spawned[0..]) catch unreachable;
        context.sink = bench.case.blackBox(@as(u64, result.spawned_count) + world.entityCount());
        assert(context.sink >= command_count);
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "command_buffer_apply_baselines");
    defer output_dir.close(io);

    var context = ApplyContext{ .allocator = std.heap.page_allocator };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_command_buffer_apply_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "mixed_bundle_apply",
        .tags = &[_][]const u8{ "static_ecs", "command_buffer", "apply", "baseline" },
        .context = &context,
        .run_fn = ApplyContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(run_result, io, output_dir, support.default_environment_note);
}

fn initWorld(allocator: std.mem.Allocator) !World {
    return World.init(allocator, .{
        .entities_max = command_count * 2,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 64,
        .chunk_rows_max = 32,
        .command_buffer_entries_max = command_count * 2,
        .command_buffer_payload_bytes_max = command_count * 128,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();
    var buffer = try world.initCommandBuffer(allocator);
    defer buffer.deinit();

    try buffer.stageSpawnBundle(.{
        Position{ .x = 1, .y = 2 },
        Tag{},
    });
    var spawned: [1]static_ecs.Entity = undefined;
    const result = try buffer.apply(&world, spawned[0..]);
    if (result.spawned_count != 1) return error.InvalidPreflight;
    if (!world.hasComponent(spawned[0], Position)) return error.InvalidPreflight;
    if (!world.hasComponent(spawned[0], Tag)) return error.InvalidPreflight;
}
