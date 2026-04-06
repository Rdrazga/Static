const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 16,
    .measure_iterations = 256,
    .sample_count = 8,
};

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Acceleration = struct { x: f32, y: f32 };
const Health = struct { value: f32 };
const Sleeping = struct {};
const Hidden = struct {};
const Boost = struct {};
const Debuff = struct {};

const World = static_ecs.World(.{
    Position,
    Velocity,
    Acceleration,
    Health,
    Sleeping,
    Hidden,
    Boost,
    Debuff,
});

const BranchContext = struct {
    world: *World,
    systems_to_run: u8,
    expected_entity_count: u32,
    expected_archetype_count_min: u32,
    sink: f64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *BranchContext = @ptrCast(@alignCast(context_ptr));
        context.sink = bench.case.blackBox(runBranchHeavySystems(context.world, context.systems_to_run));
        assert(std.math.isFinite(context.sink));
        assert(context.world.entityCount() == context.expected_entity_count);
        assert(context.world.archetypeCount() >= context.expected_archetype_count_min);
    }
};

const WriteContext = struct {
    world: *World,
    systems_to_run: u8,
    expected_entity_count: u32,
    expected_archetype_count_min: u32,
    sink: f64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *WriteContext = @ptrCast(@alignCast(context_ptr));
        context.sink = bench.case.blackBox(runWriteHeavySystems(context.world, context.systems_to_run));
        assert(std.math.isFinite(context.sink));
        assert(context.world.entityCount() == context.expected_entity_count);
        assert(context.world.archetypeCount() >= context.expected_archetype_count_min);
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "frame_workload_baselines");
    defer output_dir.close(io);

    var branch_medium = try initFragmentedFrameWorld(std.heap.page_allocator, 8192, 8);
    defer branch_medium.deinit();
    var branch_large = try initFragmentedFrameWorld(std.heap.page_allocator, 16384, 16);
    defer branch_large.deinit();
    var write_dense = try initDenseFrameWorld(std.heap.page_allocator, 4096);
    defer write_dense.deinit();
    var write_fragmented = try initFragmentedFrameWorld(std.heap.page_allocator, 16384, 8);
    defer write_fragmented.deinit();

    var branch_medium_context = BranchContext{
        .world = &branch_medium,
        .systems_to_run = 4,
        .expected_entity_count = 8192,
        .expected_archetype_count_min = 9,
    };
    var branch_large_context = BranchContext{
        .world = &branch_large,
        .systems_to_run = 8,
        .expected_entity_count = 16384,
        .expected_archetype_count_min = 17,
    };
    var write_dense_context = WriteContext{
        .world = &write_dense,
        .systems_to_run = 4,
        .expected_entity_count = 4096,
        .expected_archetype_count_min = 2,
    };
    var write_fragmented_context = WriteContext{
        .world = &write_fragmented,
        .systems_to_run = 8,
        .expected_entity_count = 16384,
        .expected_archetype_count_min = 9,
    };

    var case_storage: [4]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_frame_workload_baselines",
        .config = bench_config,
    });

    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "branch_heavy_4_systems_8k_entities_8_archetypes",
        .tags = &[_][]const u8{ "static_ecs", "frame", "branch", "baseline" },
        .context = &branch_medium_context,
        .run_fn = BranchContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "branch_heavy_8_systems_16k_entities_16_archetypes",
        .tags = &[_][]const u8{ "static_ecs", "frame", "branch", "baseline" },
        .context = &branch_large_context,
        .run_fn = BranchContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "write_heavy_4_systems_4k_entities_1_archetype",
        .tags = &[_][]const u8{ "static_ecs", "frame", "write", "baseline" },
        .context = &write_dense_context,
        .run_fn = WriteContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "write_heavy_8_systems_16k_entities_8_archetypes",
        .tags = &[_][]const u8{ "static_ecs", "frame", "write", "baseline" },
        .context = &write_fragmented_context,
        .run_fn = WriteContext.run,
    }));

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "frame_workload_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "frame", "workload", "baseline" },
    });
}

fn runBranchHeavySystems(world: *World, systems_to_run: u8) f64 {
    var total: f64 = 0;
    if (systems_to_run >= 1) runVisibility(world, &total);
    if (systems_to_run >= 2) runThreatScan(world, &total);
    if (systems_to_run >= 3) runScore(world, &total);
    if (systems_to_run >= 4) runExposure(world, &total);
    if (systems_to_run >= 5) runThreatScan(world, &total);
    if (systems_to_run >= 6) runVisibility(world, &total);
    if (systems_to_run >= 7) runScore(world, &total);
    if (systems_to_run >= 8) runExposure(world, &total);
    return total;
}

fn runWriteHeavySystems(world: *World, systems_to_run: u8) f64 {
    var total: f64 = 0;
    if (systems_to_run >= 1) runMovement(world, &total);
    if (systems_to_run >= 2) runAcceleration(world, &total);
    if (systems_to_run >= 3) runRecovery(world, &total);
    if (systems_to_run >= 4) runBoost(world, &total);
    if (systems_to_run >= 5) runDebuff(world, &total);
    if (systems_to_run >= 6) runMovement(world, &total);
    if (systems_to_run >= 7) runAcceleration(world, &total);
    if (systems_to_run >= 8) runRecovery(world, &total);
    return total;
}

fn runMovement(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.Write(Position),
        static_ecs.Read(Velocity),
        static_ecs.Exclude(Sleeping),
    });
    var it = view.iterator();
    while (it.next()) |batch_const| {
        var batch = batch_const;
        const positions = batch.write(Position);
        const velocities = batch.read(Velocity);
        for (positions, velocities) |*position, velocity| {
            position.x += velocity.x * 0.016;
            position.y += velocity.y * 0.016;
            total.* += position.x;
        }
    }
}

fn runAcceleration(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.Write(Velocity),
        static_ecs.Read(Acceleration),
        static_ecs.Exclude(Sleeping),
    });
    var it = view.iterator();
    while (it.next()) |batch_const| {
        var batch = batch_const;
        const velocities = batch.write(Velocity);
        const accelerations = batch.read(Acceleration);
        for (velocities, accelerations) |*velocity, acceleration| {
            velocity.x += acceleration.x * 0.016;
            velocity.y += acceleration.y * 0.016;
            total.* += velocity.y;
        }
    }
}

fn runRecovery(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.OptionalWrite(Health),
        static_ecs.Exclude(Sleeping),
    });
    var it = view.iterator();
    while (it.next()) |batch_const| {
        var batch = batch_const;
        const health = batch.optionalWrite(Health) orelse continue;
        for (health) |*value| {
            value.value += 0.01;
            total.* += value.value;
        }
    }
}

fn runBoost(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.Write(Velocity),
        static_ecs.With(Boost),
        static_ecs.Exclude(Sleeping),
    });
    var it = view.iterator();
    while (it.next()) |batch_const| {
        var batch = batch_const;
        const velocities = batch.write(Velocity);
        for (velocities) |*velocity| {
            velocity.x *= 1.002;
            velocity.y *= 1.002;
            total.* += velocity.x;
        }
    }
}

fn runDebuff(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.OptionalWrite(Health),
        static_ecs.With(Debuff),
        static_ecs.Exclude(Sleeping),
    });
    var it = view.iterator();
    while (it.next()) |batch_const| {
        var batch = batch_const;
        const health = batch.optionalWrite(Health) orelse continue;
        for (health) |*value| {
            value.value -= 0.02;
            total.* += value.value;
        }
    }
}

fn runVisibility(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.Exclude(Hidden),
    });
    var it = view.iterator();
    while (it.next()) |batch| {
        const positions = batch.read(Position);
        for (positions) |position| {
            total.* += position.x + position.y;
        }
    }
}

fn runScore(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.OptionalRead(Health),
        static_ecs.With(Boost),
    });
    var it = view.iterator();
    while (it.next()) |batch| {
        const positions = batch.read(Position);
        const maybe_health = batch.optionalRead(Health);
        for (positions, 0..) |position, index| {
            total.* += position.x;
            if (maybe_health) |health| total.* += health[index].value;
        }
    }
}

fn runExposure(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.OptionalRead(Health),
        static_ecs.Exclude(Hidden),
    });
    var it = view.iterator();
    while (it.next()) |batch| {
        const positions = batch.read(Position);
        const maybe_health = batch.optionalRead(Health);
        for (positions, 0..) |position, index| {
            total.* += position.y;
            if (maybe_health) |health| total.* += health[index].value * 0.1;
        }
    }
}

fn runThreatScan(world: *World, total: *f64) void {
    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.OptionalRead(Health),
        static_ecs.OptionalRead(Velocity),
        static_ecs.Exclude(Sleeping),
    });
    var it = view.iterator();
    while (it.next()) |batch| {
        const positions = batch.read(Position);
        const maybe_health = batch.optionalRead(Health);
        const maybe_velocity = batch.optionalRead(Velocity);
        for (positions, 0..) |position, index| {
            var score = position.x + position.y;
            if (maybe_health) |health| {
                if (health[index].value < 50) {
                    score += 1.5;
                } else {
                    score += 0.25;
                }
            }
            if (maybe_velocity) |velocity| {
                if (velocity[index].x > velocity[index].y) {
                    score += velocity[index].x * 0.1;
                } else {
                    score += velocity[index].y * 0.05;
                }
            }
            total.* += score;
        }
    }
}

fn initDenseFrameWorld(allocator: std.mem.Allocator, entity_count: u32) !World {
    var world = try initWorld(allocator, entity_count, 4);
    var index: u32 = 0;
    while (index < entity_count) : (index += 1) {
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(index), .y = 1 },
            Velocity{ .x = 2, .y = 3 },
            Acceleration{ .x = 0.1, .y = 0.2 },
            Health{ .value = 100 },
        });
    }
    return world;
}

fn initFragmentedFrameWorld(allocator: std.mem.Allocator, entity_count: u32, archetype_count: u8) !World {
    const archetypes_max: u32 = if (archetype_count <= 8) 12 else 20;
    var world = try initWorld(allocator, entity_count, archetypes_max);
    var index: u32 = 0;
    while (index < entity_count) : (index += 1) {
        const pattern = if (archetype_count <= 8) index % 8 else index % 16;
        switch (pattern) {
            0 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
            }),
            1 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Health{ .value = 100 },
            }),
            2 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Hidden{},
            }),
            3 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Sleeping{},
            }),
            4 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Boost{},
            }),
            5 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Health{ .value = 100 },
                Debuff{},
            }),
            6 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Health{ .value = 100 },
                Boost{},
            }),
            7 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Hidden{},
                Debuff{},
            }),
            8 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Hidden{},
                Sleeping{},
            }),
            9 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Health{ .value = 100 },
                Hidden{},
                Sleeping{},
            }),
            10 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Boost{},
                Debuff{},
            }),
            11 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Health{ .value = 100 },
                Hidden{},
                Boost{},
            }),
            12 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Health{ .value = 100 },
                Sleeping{},
                Boost{},
            }),
            13 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Health{ .value = 100 },
                Sleeping{},
                Debuff{},
            }),
            14 => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Hidden{},
                Boost{},
                Debuff{},
            }),
            else => _ = try world.spawnBundle(.{
                Position{ .x = @floatFromInt(index), .y = 1 },
                Velocity{ .x = 2, .y = 3 },
                Acceleration{ .x = 0.1, .y = 0.2 },
                Health{ .value = 100 },
                Hidden{},
                Sleeping{},
                Boost{},
            }),
        }
    }
    return world;
}

fn initWorld(allocator: std.mem.Allocator, entity_count: u32, archetypes_max: u32) !World {
    return World.init(allocator, .{
        .entities_max = entity_count,
        .archetypes_max = archetypes_max,
        .components_per_archetype_max = 8,
        .chunks_max = 256,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = entity_count,
        .command_buffer_payload_bytes_max = entity_count * 128,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var branch_world = try initFragmentedFrameWorld(allocator, 256, 16);
    defer branch_world.deinit();
    const branch_total = runBranchHeavySystems(&branch_world, 8);
    if (!std.math.isFinite(branch_total)) return error.InvalidPreflight;
    if (branch_world.archetypeCount() < 17) return error.InvalidPreflight;

    var write_world = try initDenseFrameWorld(allocator, 256);
    defer write_world.deinit();
    var view = write_world.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
    });
    var before_it = view.iterator();
    const before_batch = before_it.next() orelse return error.InvalidPreflight;
    const tracked = before_batch.entities()[0];
    const before_x = write_world.componentPtrConst(tracked, Position).?.x;
    const write_total = runWriteHeavySystems(&write_world, 4);
    if (!std.math.isFinite(write_total)) return error.InvalidPreflight;
    if (write_world.componentPtrConst(tracked, Position).?.x == before_x) return error.InvalidPreflight;
}
