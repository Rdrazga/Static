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
const Stamina = struct { value: f32 };
const Team = struct { value: u16 };
const Tag = struct {};
const Frozen = struct {};

const DenseWorld = static_ecs.World(.{ Position, Velocity });
const MixedWorld = static_ecs.World(.{ Position, Velocity, Health, Tag });
const FragmentedWorld = static_ecs.World(.{ Position, Velocity, Health, Stamina, Team, Tag, Frozen });

const dense_entity_count: u32 = 4096;
const mixed_entity_count: u32 = 2048;
const fragmented_entity_count: u32 = 4096;
const fragmented_match_count: usize = fragmented_entity_count / 8 * 5;

const DenseIterationContext = struct {
    world: *DenseWorld,
    sink: f64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *DenseIterationContext = @ptrCast(@alignCast(context_ptr));
        var view = context.world.view(.{
            static_ecs.Read(Position),
            static_ecs.Read(Velocity),
        });
        var it = view.iterator();
        var total: f64 = 0;
        var counted: usize = 0;
        while (it.next()) |batch| {
            const positions = batch.read(Position);
            const velocities = batch.read(Velocity);
            counted += batch.len();
            for (positions, velocities) |position, velocity| {
                total += position.x + velocity.y;
            }
        }
        context.sink = bench.case.blackBox(total);
        assert(counted == dense_entity_count);
        assert(context.sink > 0);
    }
};

const MixedIterationContext = struct {
    world: *MixedWorld,
    sink: f64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *MixedIterationContext = @ptrCast(@alignCast(context_ptr));
        var view = context.world.view(.{
            static_ecs.Read(Position),
            static_ecs.Read(Velocity),
            static_ecs.OptionalRead(Health),
            static_ecs.Exclude(Tag),
        });
        var it = view.iterator();
        var total: f64 = 0;
        var counted: usize = 0;
        while (it.next()) |batch| {
            const positions = batch.read(Position);
            const velocities = batch.read(Velocity);
            const maybe_health = batch.optionalRead(Health);
            counted += batch.len();
            for (positions, velocities, 0..) |position, velocity, index| {
                total += position.x + velocity.y;
                if (maybe_health) |health| {
                    total += @as(f64, @floatFromInt(health[index].value));
                }
            }
        }
        context.sink = bench.case.blackBox(total);
        assert(counted == mixed_entity_count / 2);
        assert(context.sink > 0);
    }
};

const FragmentedIterationContext = struct {
    world: *FragmentedWorld,
    sink: f64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *FragmentedIterationContext = @ptrCast(@alignCast(context_ptr));
        var view = context.world.view(.{
            static_ecs.Read(Position),
            static_ecs.Read(Velocity),
            static_ecs.OptionalRead(Health),
            static_ecs.OptionalRead(Stamina),
            static_ecs.Exclude(Tag),
            static_ecs.Exclude(Frozen),
        });
        var it = view.iterator();
        var total: f64 = 0;
        var counted: usize = 0;
        while (it.next()) |batch| {
            const positions = batch.read(Position);
            const velocities = batch.read(Velocity);
            const maybe_health = batch.optionalRead(Health);
            const maybe_stamina = batch.optionalRead(Stamina);
            counted += batch.len();
            for (positions, velocities, 0..) |position, velocity, index| {
                total += position.x + velocity.y;
                if (maybe_health) |health| {
                    total += @as(f64, @floatFromInt(health[index].value));
                }
                if (maybe_stamina) |stamina| {
                    total += stamina[index].value;
                }
            }
        }
        context.sink = bench.case.blackBox(total);
        assert(counted == fragmented_match_count);
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

    var dense_world = try initDenseWorld(std.heap.page_allocator);
    defer dense_world.deinit();
    var mixed_world = try initMixedWorld(std.heap.page_allocator);
    defer mixed_world.deinit();
    var fragmented_world = try initFragmentedWorld(std.heap.page_allocator);
    defer fragmented_world.deinit();

    var dense_context = DenseIterationContext{ .world = &dense_world };
    var mixed_context = MixedIterationContext{ .world = &mixed_world };
    var fragmented_context = FragmentedIterationContext{ .world = &fragmented_world };

    var case_storage: [3]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_query_iteration_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "dense_required_reads_single_archetype",
        .tags = &[_][]const u8{ "static_ecs", "query", "dense", "baseline" },
        .context = &dense_context,
        .run_fn = DenseIterationContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "mixed_optional_health_exclude_tag",
        .tags = &[_][]const u8{ "static_ecs", "query", "mixed", "baseline" },
        .context = &mixed_context,
        .run_fn = MixedIterationContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "fragmented_optional_exclude_scan",
        .tags = &[_][]const u8{ "static_ecs", "query", "fragmented", "baseline" },
        .context = &fragmented_context,
        .run_fn = FragmentedIterationContext.run,
    }));

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "query_iteration_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "query", "iteration", "baseline" },
    });
}

fn initDenseWorld(allocator: std.mem.Allocator) !DenseWorld {
    var world = try DenseWorld.init(allocator, .{
        .entities_max = dense_entity_count,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 96,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = dense_entity_count,
        .command_buffer_payload_bytes_max = dense_entity_count * 32,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });

    var index: u32 = 0;
    while (index < dense_entity_count) : (index += 1) {
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(index), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(index) },
        });
    }
    return world;
}

fn initMixedWorld(allocator: std.mem.Allocator) !MixedWorld {
    var world = try MixedWorld.init(allocator, .{
        .entities_max = mixed_entity_count,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 64,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = mixed_entity_count,
        .command_buffer_payload_bytes_max = mixed_entity_count * 64,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });

    var index: u32 = 0;
    while (index < mixed_entity_count) : (index += 1) {
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

fn initFragmentedWorld(allocator: std.mem.Allocator) !FragmentedWorld {
    var world = try FragmentedWorld.init(allocator, .{
        .entities_max = fragmented_entity_count,
        .archetypes_max = 16,
        .components_per_archetype_max = 7,
        .chunks_max = 128,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = fragmented_entity_count,
        .command_buffer_payload_bytes_max = fragmented_entity_count * 96,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });

    var index: u32 = 0;
    while (index < fragmented_entity_count) : (index += 1) {
        switch (index % 8) {
            0 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
            }),
            1 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Health{ .value = @intCast(index) },
            }),
            2 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Stamina{ .value = @floatFromInt(index % 11) },
            }),
            3 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Health{ .value = @intCast(index) },
                Stamina{ .value = @floatFromInt(index % 11) },
            }),
            4 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Tag{},
            }),
            5 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Health{ .value = @intCast(index) },
                Tag{},
            }),
            6 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Frozen{},
            }),
            else => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = @floatFromInt(index) },
                Health{ .value = @intCast(index) },
                Stamina{ .value = @floatFromInt(index % 11) },
                Team{ .value = @intCast(index % 4) },
            }),
        }
    }
    return world;
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    try validateDensePreflight(allocator);
    try validateMixedPreflight(allocator);
    try validateFragmentedPreflight(allocator);
}

fn validateDensePreflight(allocator: std.mem.Allocator) !void {
    var world = try initDenseWorld(allocator);
    defer world.deinit();

    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
    });
    var it = view.iterator();
    var counted: usize = 0;
    while (it.next()) |batch| counted += batch.len();
    if (counted != dense_entity_count) return error.InvalidPreflight;
}

fn validateMixedPreflight(allocator: std.mem.Allocator) !void {
    var world = try initMixedWorld(allocator);
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
    if (counted != mixed_entity_count / 2) return error.InvalidPreflight;
}

fn validateFragmentedPreflight(allocator: std.mem.Allocator) !void {
    var world = try initFragmentedWorld(allocator);
    defer world.deinit();

    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
        static_ecs.OptionalRead(Health),
        static_ecs.OptionalRead(Stamina),
        static_ecs.Exclude(Tag),
        static_ecs.Exclude(Frozen),
    });
    var it = view.iterator();
    var counted: usize = 0;
    var batch_count: usize = 0;
    while (it.next()) |batch| {
        counted += batch.len();
        batch_count += 1;
    }
    if (counted != fragmented_match_count) return error.InvalidPreflight;
    if (batch_count < 5) return error.InvalidPreflight;
}
