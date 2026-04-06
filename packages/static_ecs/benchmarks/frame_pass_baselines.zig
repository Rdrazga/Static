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

const FrameContext = struct {
    world: *World,
    passes_to_run: u8,
    expected_entity_count: u32,
    expected_archetype_count_min: u32,
    sink: f64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *FrameContext = @ptrCast(@alignCast(context_ptr));
        context.sink = bench.case.blackBox(runFramePasses(context.world, context.passes_to_run));
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
    var output_dir = try support.openOutputDir(io, "frame_pass_baselines");
    defer output_dir.close(io);

    var dense_small = try initDenseFrameWorld(std.heap.page_allocator, 4096);
    defer dense_small.deinit();
    var dense_small_many = try initDenseFrameWorld(std.heap.page_allocator, 4096);
    defer dense_small_many.deinit();
    var fragmented_medium = try initFragmentedFrameWorld(std.heap.page_allocator, 16384, 8);
    defer fragmented_medium.deinit();
    var fragmented_large = try initFragmentedFrameWorld(std.heap.page_allocator, 16384, 16);
    defer fragmented_large.deinit();

    var contexts = [_]FrameContext{
        .{ .world = &dense_small, .passes_to_run = 1, .expected_entity_count = 4096, .expected_archetype_count_min = 2 },
        .{ .world = &dense_small_many, .passes_to_run = 4, .expected_entity_count = 4096, .expected_archetype_count_min = 2 },
        .{ .world = &fragmented_medium, .passes_to_run = 4, .expected_entity_count = 16384, .expected_archetype_count_min = 9 },
        .{ .world = &fragmented_large, .passes_to_run = 8, .expected_entity_count = 16384, .expected_archetype_count_min = 17 },
    };
    const case_names = [_][]const u8{
        "1_pass_4k_entities_1_archetype",
        "4_passes_4k_entities_1_archetype",
        "4_passes_16k_entities_8_archetypes",
        "8_passes_16k_entities_16_archetypes",
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_frame_pass_baselines",
        .config = bench_config,
    });
    inline for (&contexts, case_names) |*context, case_name| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = case_name,
            .tags = &[_][]const u8{ "static_ecs", "frame", "systems", "baseline" },
            .context = context,
            .run_fn = FrameContext.run,
        }));
    }

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "frame_pass_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "frame", "systems", "baseline" },
    });
}

fn runFramePasses(world: *World, passes_to_run: u8) f64 {
    var total: f64 = 0;
    if (passes_to_run >= 1) runMovement(world, &total);
    if (passes_to_run >= 2) runAcceleration(world, &total);
    if (passes_to_run >= 3) runRecovery(world, &total);
    if (passes_to_run >= 4) runVisibility(world, &total);
    if (passes_to_run >= 5) runBoost(world, &total);
    if (passes_to_run >= 6) runDebuff(world, &total);
    if (passes_to_run >= 7) runScore(world, &total);
    if (passes_to_run >= 8) runExposure(world, &total);
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
    var world = try initDenseFrameWorld(allocator, 128);
    defer world.deinit();

    var before_view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
    });
    var before_it = before_view.iterator();
    const before_batch = before_it.next() orelse return error.InvalidPreflight;
    const tracked_entity = before_batch.entities()[0];
    const before_x = world.componentPtrConst(tracked_entity, Position).?.x;
    const total = runFramePasses(&world, 4);
    if (!std.math.isFinite(total)) return error.InvalidPreflight;

    var view = world.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
    });
    var it = view.iterator();
    const batch = it.next() orelse return error.InvalidPreflight;
    if (batch.read(Position)[0].x == before_x) return error.InvalidPreflight;

    var fragmented = try initFragmentedFrameWorld(allocator, 256, 16);
    defer fragmented.deinit();
    if (fragmented.archetypeCount() < 17) return error.InvalidPreflight;
}
