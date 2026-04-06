const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 1024,
    .sample_count = 8,
};

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { value: f32 };
const Stamina = struct { value: f32 };
const Team = struct { value: u16 };
const Tag = struct {};
const Frozen = struct {};
const World = static_ecs.World(.{ Position, Velocity, Health, Stamina, Team, Tag, Frozen });

const ScaleContext = struct {
    world: *World,
    expected_match_count: usize,
    expected_archetype_count_min: u32,
    sink: f64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *ScaleContext = @ptrCast(@alignCast(context_ptr));
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
                if (maybe_health) |health| total += health[index].value;
                if (maybe_stamina) |stamina| total += stamina[index].value;
            }
        }
        context.sink = bench.case.blackBox(total);
        assert(counted == context.expected_match_count);
        assert(context.world.archetypeCount() >= context.expected_archetype_count_min);
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
    var output_dir = try support.openOutputDir(io, "query_scale_baselines");
    defer output_dir.close(io);

    var dense_small = try initDenseWorld(std.heap.page_allocator, 1024);
    defer dense_small.deinit();
    var dense_large = try initDenseWorld(std.heap.page_allocator, 16384);
    defer dense_large.deinit();
    var fragmented_eight = try initFragmentedEightArchetypeWorld(std.heap.page_allocator, 16384);
    defer fragmented_eight.deinit();
    var fragmented_sixteen = try initFragmentedSixteenArchetypeWorld(std.heap.page_allocator, 16384);
    defer fragmented_sixteen.deinit();

    var contexts = [_]ScaleContext{
        .{ .world = &dense_small, .expected_match_count = 1024, .expected_archetype_count_min = 2 },
        .{ .world = &dense_large, .expected_match_count = 16384, .expected_archetype_count_min = 2 },
        .{ .world = &fragmented_eight, .expected_match_count = 16384, .expected_archetype_count_min = 9 },
        .{ .world = &fragmented_sixteen, .expected_match_count = 8192, .expected_archetype_count_min = 17 },
    };
    const case_names = [_][]const u8{
        "dense_1k_entities_1_archetype",
        "dense_16k_entities_1_archetype",
        "fragmented_16k_entities_8_archetypes",
        "fragmented_16k_entities_16_archetypes",
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_query_scale_baselines",
        .config = bench_config,
    });
    inline for (&contexts, case_names) |*context, case_name| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = case_name,
            .tags = &[_][]const u8{ "static_ecs", "query", "scale", "baseline" },
            .context = context,
            .run_fn = ScaleContext.run,
        }));
    }

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "query_scale_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "query", "scale", "baseline" },
    });
}

fn initDenseWorld(allocator: std.mem.Allocator, entity_count: u32) !World {
    var world = try initWorld(allocator, entity_count, 4);
    var index: u32 = 0;
    while (index < entity_count) : (index += 1) {
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(index + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(index + 1) },
        });
    }
    return world;
}

fn initFragmentedEightArchetypeWorld(allocator: std.mem.Allocator, entity_count: u32) !World {
    var world = try initWorld(allocator, entity_count, 12);
    var index: u32 = 0;
    while (index < entity_count) : (index += 1) {
        const pattern = index % 8;
        switch (pattern) {
            0 => _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) } }),
            1 => _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 } }),
            2 => _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Stamina{ .value = 20 } }),
            3 => _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Team{ .value = @intCast(index % 4) } }),
            4 => _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Stamina{ .value = 20 } }),
            5 => _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Team{ .value = @intCast(index % 4) } }),
            6 => _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Stamina{ .value = 20 }, Team{ .value = @intCast(index % 4) } }),
            else => _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Stamina{ .value = 20 }, Team{ .value = @intCast(index % 4) } }),
        }
    }
    return world;
}

fn initFragmentedSixteenArchetypeWorld(allocator: std.mem.Allocator, entity_count: u32) !World {
    var world = try initWorld(allocator, entity_count, 20);
    var index: u32 = 0;
    while (index < entity_count) : (index += 1) {
        const pattern: u4 = @intCast(index % 16);
        const include_health = (pattern & 0b0001) != 0;
        const include_stamina = (pattern & 0b0010) != 0;
        const include_team = (pattern & 0b0100) != 0;
        const include_tag = (pattern & 0b1000) != 0;

        if (include_health and include_stamina and include_team and include_tag) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Stamina{ .value = 20 }, Team{ .value = @intCast(index % 4) }, Tag{} });
        } else if (include_health and include_stamina and include_team) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Stamina{ .value = 20 }, Team{ .value = @intCast(index % 4) } });
        } else if (include_health and include_stamina and include_tag) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Stamina{ .value = 20 }, Tag{} });
        } else if (include_health and include_team and include_tag) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Team{ .value = @intCast(index % 4) }, Tag{} });
        } else if (include_stamina and include_team and include_tag) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Stamina{ .value = 20 }, Team{ .value = @intCast(index % 4) }, Tag{} });
        } else if (include_health and include_stamina) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Stamina{ .value = 20 } });
        } else if (include_health and include_team) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Team{ .value = @intCast(index % 4) } });
        } else if (include_health and include_tag) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 }, Tag{} });
        } else if (include_stamina and include_team) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Stamina{ .value = 20 }, Team{ .value = @intCast(index % 4) } });
        } else if (include_stamina and include_tag) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Stamina{ .value = 20 }, Tag{} });
        } else if (include_team and include_tag) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Team{ .value = @intCast(index % 4) }, Tag{} });
        } else if (include_health) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Health{ .value = 10 } });
        } else if (include_stamina) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Stamina{ .value = 20 } });
        } else if (include_team) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Team{ .value = @intCast(index % 4) } });
        } else if (include_tag) {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) }, Tag{} });
        } else {
            _ = try world.spawnBundle(.{ Position{ .x = @floatFromInt(index + 1), .y = 1 }, Velocity{ .x = 2, .y = @floatFromInt(index + 1) } });
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
        .command_buffer_payload_bytes_max = entity_count * 96,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var dense = try initDenseWorld(allocator, 1024);
    defer dense.deinit();
    if (dense.entityCount() != 1024) return error.InvalidPreflight;

    var fragmented = try initFragmentedSixteenArchetypeWorld(allocator, 1600);
    defer fragmented.deinit();
    var view = fragmented.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
        static_ecs.OptionalRead(Health),
        static_ecs.OptionalRead(Stamina),
        static_ecs.Exclude(Tag),
        static_ecs.Exclude(Frozen),
    });
    var it = view.iterator();
    var counted: usize = 0;
    while (it.next()) |batch| counted += batch.len();
    if (counted != 800) return error.InvalidPreflight;
    if (fragmented.archetypeCount() < 17) return error.InvalidPreflight;
}
