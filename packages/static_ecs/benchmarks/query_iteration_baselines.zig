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
const Tag = struct {};
const World = static_ecs.World(.{ Position, Velocity, Health, Tag });

const entity_count: u32 = 2048;

const IterationContext = struct {
    world: *World,
    sink: f64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *IterationContext = @ptrCast(@alignCast(context_ptr));
        var view = context.world.view(.{
            static_ecs.Read(Position),
            static_ecs.Read(Velocity),
            static_ecs.OptionalRead(Health),
            static_ecs.Exclude(Tag),
        });
        var it = view.iterator();
        var total: f64 = 0;
        while (it.next()) |batch| {
            const positions = batch.read(Position);
            const velocities = batch.read(Velocity);
            const maybe_health = batch.optionalRead(Health);
            for (positions, velocities, 0..) |position, velocity, index| {
                total += position.x + velocity.y;
                if (maybe_health) |health| {
                    total += @as(f64, @floatFromInt(health[index].value));
                }
            }
        }
        context.sink = bench.case.blackBox(total);
        assert(context.sink > 0);
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "query_iteration_baselines");
    defer output_dir.close(io);

    var world = try initWorld(std.heap.page_allocator);
    defer world.deinit();

    var context = IterationContext{ .world = &world };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_query_iteration_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "position_velocity_optional_health",
        .tags = &[_][]const u8{ "static_ecs", "query", "iteration", "baseline" },
        .context = &context,
        .run_fn = IterationContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(run_result, io, output_dir, support.default_environment_note);
}

fn initWorld(allocator: std.mem.Allocator) !World {
    var world = try World.init(allocator, .{
        .entities_max = entity_count,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 64,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = entity_count,
        .command_buffer_payload_bytes_max = entity_count * 64,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });

    var index: u32 = 0;
    while (index < entity_count) : (index += 1) {
        if (index % 4 == 0) {
            _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Health{ .value = @intCast(index) },
            });
        } else if (index % 4 == 1) {
            _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
            });
        } else if (index % 4 == 2) {
            _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Tag{},
            });
        } else {
            _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Health{ .value = @intCast(index) },
                Tag{},
            });
        }
    }
    return world;
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator);
    defer world.deinit();

    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
        static_ecs.OptionalRead(Health),
        static_ecs.Exclude(Tag),
    });
    var it = view.iterator();
    var counted: usize = 0;
    while (it.next()) |batch| counted += batch.len();
    if (counted != entity_count / 2) return error.InvalidPreflight;
}
