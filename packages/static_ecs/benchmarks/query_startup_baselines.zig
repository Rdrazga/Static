const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const startup_benchmark_config: bench.config.BenchmarkConfig = .{
    .mode = .full,
    .warmup_iterations = 64,
    .measure_iterations = 8192,
    .sample_count = 8,
};

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { value: i32 };
const Team = struct { value: u16 };
const Tag = struct {};
const Frozen = struct {};

const DenseWorld = static_ecs.World(.{ Position, Velocity });
const SparseWorld = static_ecs.World(.{ Position, Velocity, Health, Team, Tag });
const ZeroWorld = static_ecs.World(.{ Position, Velocity, Tag, Frozen });

const entities_per_archetype: u32 = 256;
const first_batch_len: usize = 64;
const sparse_matching_archetypes: u32 = 2;
const sparse_total_archetypes: u32 = 6;

const DenseStartupContext = struct {
    world: *DenseWorld,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *DenseStartupContext = @ptrCast(@alignCast(context_ptr));
        var view = context.world.view(.{
            static_ecs.Read(Position),
            static_ecs.Read(Velocity),
        });
        var it = view.iterator();
        const batch = it.next().?;
        context.sink = bench.case.blackBox(@as(u64, batch.len()) + @as(u64, @intFromFloat(batch.read(Position)[0].x)));
        assert(batch.len() == first_batch_len);
        assert(context.sink > 0);
    }
};

const SparseLateMatchStartupContext = struct {
    world: *SparseWorld,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SparseLateMatchStartupContext = @ptrCast(@alignCast(context_ptr));
        var view = context.world.view(.{
            static_ecs.Read(Position),
            static_ecs.Read(Velocity),
            static_ecs.Read(Health),
            static_ecs.Exclude(Tag),
        });
        var it = view.iterator();
        const batch = it.next().?;
        context.sink = bench.case.blackBox(@as(u64, batch.len()) + @as(u64, batch.entities()[0].index));
        assert(batch.len() == first_batch_len);
        assert(context.sink > 0);
    }
};

const ZeroMatchStartupContext = struct {
    world: *ZeroWorld,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *ZeroMatchStartupContext = @ptrCast(@alignCast(context_ptr));
        var view = context.world.view(.{
            static_ecs.Read(Position),
            static_ecs.Read(Velocity),
            static_ecs.With(Frozen),
            static_ecs.Exclude(Tag),
        });
        var it = view.iterator();
        const batch = it.next();
        context.sink = bench.case.blackBox(@as(u64, @intFromBool(batch == null)));
        assert(batch == null);
        assert(context.sink == 1);
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "query_startup_baselines");
    defer output_dir.close(io);

    var dense_world = try initDenseWorld(std.heap.page_allocator);
    defer dense_world.deinit();
    var sparse_world = try initSparseLateMatchWorld(std.heap.page_allocator);
    defer sparse_world.deinit();
    var zero_world = try initZeroMatchWorld(std.heap.page_allocator);
    defer zero_world.deinit();

    var dense_context = DenseStartupContext{ .world = &dense_world };
    var sparse_context = SparseLateMatchStartupContext{ .world = &sparse_world };
    var zero_context = ZeroMatchStartupContext{ .world = &zero_world };

    var case_storage: [3]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_query_startup_baselines",
        .config = startup_benchmark_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "dense_first_match_startup",
        .tags = &[_][]const u8{ "static_ecs", "query", "startup", "baseline" },
        .context = &dense_context,
        .run_fn = DenseStartupContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "sparse_late_match_startup",
        .tags = &[_][]const u8{ "static_ecs", "query", "startup", "baseline" },
        .context = &sparse_context,
        .run_fn = SparseLateMatchStartupContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "zero_match_startup",
        .tags = &[_][]const u8{ "static_ecs", "query", "startup", "baseline" },
        .context = &zero_context,
        .run_fn = ZeroMatchStartupContext.run,
    }));

    var sample_storage: [startup_benchmark_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "query_startup_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "query", "startup", "baseline" },
    });
}

fn initDenseWorld(allocator: std.mem.Allocator) !DenseWorld {
    var world = try initDenseWorldConfig(allocator, entities_per_archetype + 64, 8);
    var index: u32 = 0;
    while (index < entities_per_archetype) : (index += 1) {
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(index + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(index + 1) },
        });
    }
    return world;
}

fn initSparseLateMatchWorld(allocator: std.mem.Allocator) !SparseWorld {
    var world = try initSparseWorldConfig(allocator, entities_per_archetype * sparse_total_archetypes + 128, 32);
    try spawnSparseArchetypePositionVelocity(&world, 0);
    try spawnSparseArchetypePositionVelocityTag(&world, 1);
    try spawnSparseArchetypePositionVelocityTeam(&world, 2);
    try spawnSparseArchetypePositionVelocityTeamTag(&world, 3);
    try spawnSparseArchetypePositionVelocityHealth(&world, 4);
    try spawnSparseArchetypePositionVelocityHealthTeam(&world, 5);
    return world;
}

fn initZeroMatchWorld(allocator: std.mem.Allocator) !ZeroWorld {
    var world = try initZeroWorldConfig(allocator, entities_per_archetype * 4 + 64, 8);
    var row: u32 = 0;
    while (row < entities_per_archetype * 2) : (row += 1) {
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(row + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(row + 1) },
        });
    }
    row = 0;
    while (row < entities_per_archetype * 2) : (row += 1) {
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(row + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(row + 1) },
            Tag{},
        });
    }
    return world;
}

fn initDenseWorldConfig(allocator: std.mem.Allocator, entity_count: u32, archetypes_max: u32) !DenseWorld {
    return DenseWorld.init(allocator, .{
        .entities_max = entity_count,
        .archetypes_max = archetypes_max,
        .components_per_archetype_max = 6,
        .chunks_max = 24,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = entity_count,
        .command_buffer_payload_bytes_max = entity_count * 48,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });
}

fn initSparseWorldConfig(allocator: std.mem.Allocator, entity_count: u32, archetypes_max: u32) !SparseWorld {
    return SparseWorld.init(allocator, .{
        .entities_max = entity_count,
        .archetypes_max = archetypes_max,
        .components_per_archetype_max = 8,
        .chunks_max = 256,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = entity_count,
        .command_buffer_payload_bytes_max = entity_count * 64,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });
}

fn initZeroWorldConfig(allocator: std.mem.Allocator, entity_count: u32, archetypes_max: u32) !ZeroWorld {
    return ZeroWorld.init(allocator, .{
        .entities_max = entity_count,
        .archetypes_max = archetypes_max,
        .components_per_archetype_max = 6,
        .chunks_max = 24,
        .chunk_rows_max = 64,
        .command_buffer_entries_max = entity_count,
        .command_buffer_payload_bytes_max = entity_count * 56,
        .empty_chunk_retained_max = 2,
        .budget = null,
    });
}

fn spawnSparseArchetypePositionVelocity(world: *SparseWorld, archetype_index: u32) !void {
    var row: u32 = 0;
    while (row < entities_per_archetype) : (row += 1) {
        const base = row + archetype_index * entities_per_archetype;
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(base + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(base + 1) },
        });
    }
}

fn spawnSparseArchetypePositionVelocityTag(world: *SparseWorld, archetype_index: u32) !void {
    var row: u32 = 0;
    while (row < entities_per_archetype) : (row += 1) {
        const base = row + archetype_index * entities_per_archetype;
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(base + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(base + 1) },
            Tag{},
        });
    }
}

fn spawnSparseArchetypePositionVelocityTeam(world: *SparseWorld, archetype_index: u32) !void {
    var row: u32 = 0;
    while (row < entities_per_archetype) : (row += 1) {
        const base = row + archetype_index * entities_per_archetype;
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(base + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(base + 1) },
            Team{ .value = @intCast(base % 4) },
        });
    }
}

fn spawnSparseArchetypePositionVelocityTeamTag(world: *SparseWorld, archetype_index: u32) !void {
    var row: u32 = 0;
    while (row < entities_per_archetype) : (row += 1) {
        const base = row + archetype_index * entities_per_archetype;
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(base + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(base + 1) },
            Team{ .value = @intCast(base % 4) },
            Tag{},
        });
    }
}

fn spawnSparseArchetypePositionVelocityHealth(world: *SparseWorld, archetype_index: u32) !void {
    var row: u32 = 0;
    while (row < entities_per_archetype) : (row += 1) {
        const base = row + archetype_index * entities_per_archetype;
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(base + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(base + 1) },
            Health{ .value = @intCast(base) },
        });
    }
}

fn spawnSparseArchetypePositionVelocityHealthTeam(world: *SparseWorld, archetype_index: u32) !void {
    var row: u32 = 0;
    while (row < entities_per_archetype) : (row += 1) {
        const base = row + archetype_index * entities_per_archetype;
        _ = try world.spawnBundle(.{
            Position{ .x = @floatFromInt(base + 1), .y = 1 },
            Velocity{ .x = 2, .y = @floatFromInt(base + 1) },
            Health{ .value = @intCast(base) },
            Team{ .value = @intCast(base % 4) },
        });
    }
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var dense = try initDenseWorld(allocator);
    defer dense.deinit();
    var dense_view = dense.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
    });
    var dense_it = dense_view.iterator();
    if ((dense_it.next() orelse return error.DenseMissingBatch).len() != first_batch_len) return error.DenseWrongBatchLen;

    var sparse = try initSparseLateMatchWorld(allocator);
    defer sparse.deinit();
    var sparse_view = sparse.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
        static_ecs.Read(Health),
        static_ecs.Exclude(Tag),
    });
    var sparse_it = sparse_view.iterator();
    const sparse_batch = sparse_it.next() orelse return error.SparseMissingBatch;
    if (sparse_batch.len() != first_batch_len) return error.SparseWrongBatchLen;
    var sparse_total: usize = sparse_batch.len();
    while (sparse_it.next()) |batch| sparse_total += batch.len();
    if (sparse_total != entities_per_archetype * sparse_matching_archetypes) return error.SparseWrongTotal;

    var zero = try initZeroMatchWorld(allocator);
    defer zero.deinit();
    var zero_view = zero.view(.{
        static_ecs.Read(Position),
        static_ecs.Read(Velocity),
        static_ecs.With(Frozen),
        static_ecs.Exclude(Tag),
    });
    var zero_it = zero_view.iterator();
    if (zero_it.next() != null) return error.ZeroMatchedUnexpectedly;
}
