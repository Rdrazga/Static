const std = @import("std");
const assert = std.debug.assert;
const static_ecs = @import("static_ecs");
const static_memory = @import("static_memory");
const static_testing = @import("static_testing");
const support = @import("support.zig");
const bundle_codec = static_ecs.bundle_codec;

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 4096,
    .sample_count = 8,
};

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { value: f32 };

const Components = .{ Position, Velocity, Health };
const World = static_ecs.World(Components);
const Slab = static_memory.slab.Slab;

const typed_bundle = .{
    Position{ .x = 10, .y = 20 },
    Velocity{ .x = 1, .y = 2 },
    Health{ .value = 100 },
};

const encoded_bundle_len: comptime_int = bundle_codec.encodedBundleSizeForType(Components, @TypeOf(typed_bundle));

const Context = struct {
    slab: ?Slab,
    world: World,
    encoded_bytes: [encoded_bundle_len]u8,
    entry_count: u32,
    sink: u32 = 0,

    fn initPage() !Context {
        var context = Context{
            .slab = null,
            .world = try initWorld(std.heap.page_allocator),
            .encoded_bytes = undefined,
            .entry_count = 0,
        };
        errdefer context.world.deinit();
        context.entry_count = bundle_codec.encodeBundleTuple(Components, typed_bundle, context.encoded_bytes[0..]);
        try context.prime();
        return context;
    }

    fn initSlab() !Context {
        var slab = try Slab.init(std.heap.page_allocator, .{
            .class_sizes = &[_]u32{ 32, 64, 128, 256 },
            .class_counts = &[_]u32{ 64, 64, 32, 16 },
            .allow_large_fallback = true,
        });
        errdefer slab.deinit();

        var context = Context{
            .slab = slab,
            .world = undefined,
            .encoded_bytes = undefined,
            .entry_count = 0,
        };
        errdefer if (context.slab) |*owned_slab| owned_slab.deinit();

        const allocator = if (context.slab) |*owned_slab| owned_slab.allocator() else unreachable;
        context.world = try initWorld(allocator);
        errdefer context.world.deinit();

        context.entry_count = bundle_codec.encodeBundleTuple(Components, typed_bundle, context.encoded_bytes[0..]);
        try context.prime();
        return context;
    }

    fn deinit(self: *Context) void {
        self.world.deinit();
        if (self.slab) |*slab| slab.deinit();
        self.* = undefined;
    }

    fn prime(self: *Context) !void {
        const entity = try self.world.spawnBundle(typed_bundle);
        try self.world.despawn(entity);
        assert(self.world.entityCount() == 0);
    }

    fn runTyped(context_ptr: *anyopaque) void {
        const context: *Context = @ptrCast(@alignCast(context_ptr));
        const entity = context.world.spawnBundle(typed_bundle) catch unreachable;
        context.sink +%= bench.case.blackBox(entity.index);
        context.world.despawn(entity) catch unreachable;
        assert(context.world.entityCount() == 0);
    }

    fn runEncoded(context_ptr: *anyopaque) void {
        const context: *Context = @ptrCast(@alignCast(context_ptr));
        const entity = context.world.spawnBundleFromEncoded(context.encoded_bytes[0..], context.entry_count) catch unreachable;
        context.sink +%= bench.case.blackBox(entity.index);
        context.world.despawn(entity) catch unreachable;
        assert(context.world.entityCount() == 0);
    }
};

pub fn main() !void {
    try validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "allocator_strategy_baselines");
    defer output_dir.close(io);

    var page_context = try Context.initPage();
    defer page_context.deinit();
    var slab_context = try Context.initSlab();
    defer slab_context.deinit();

    var case_storage: [4]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_ecs_allocator_strategy_baselines",
        .config = bench_config,
    });

    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "typed_spawn_despawn_page_allocator",
        .tags = &[_][]const u8{ "static_ecs", "allocator", "typed", "page" },
        .context = &page_context,
        .run_fn = Context.runTyped,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "typed_spawn_despawn_slab_allocator",
        .tags = &[_][]const u8{ "static_ecs", "allocator", "typed", "slab" },
        .context = &slab_context,
        .run_fn = Context.runTyped,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "encoded_spawn_despawn_page_allocator",
        .tags = &[_][]const u8{ "static_ecs", "allocator", "encoded", "page" },
        .context = &page_context,
        .run_fn = Context.runEncoded,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "encoded_spawn_despawn_slab_allocator",
        .tags = &[_][]const u8{ "static_ecs", "allocator", "encoded", "slab" },
        .context = &slab_context,
        .run_fn = Context.runEncoded,
    }));

    var sample_storage: [bench_config.sample_count * case_storage.len]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_storage.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(&group, &sample_storage, &case_result_storage);

    try support.writeGroupReport(case_storage.len, "allocator_strategy_baselines", run_result, io, output_dir, .{
        .environment_tags = &[_][]const u8{ "static_ecs", "allocator", "strategy", "baseline" },
    });
}

fn initWorld(allocator: std.mem.Allocator) !World {
    return World.init(allocator, .{
        .entities_max = 8,
        .archetypes_max = 4,
        .components_per_archetype_max = 3,
        .chunks_max = 4,
        .chunk_rows_max = 8,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 512,
        .empty_chunk_retained_max = 1,
        .budget = null,
    });
}

fn validateSemanticPreflight() !void {
    var page_context = try Context.initPage();
    defer page_context.deinit();
    var slab_context = try Context.initSlab();
    defer slab_context.deinit();

    Context.runTyped(&page_context);
    Context.runTyped(&slab_context);
    Context.runEncoded(&page_context);
    Context.runEncoded(&slab_context);

    if (page_context.world.entityCount() != 0) return error.InvalidPreflight;
    if (slab_context.world.entityCount() != 0) return error.InvalidPreflight;
    if (page_context.entry_count == 0) return error.InvalidPreflight;
    if (slab_context.entry_count != page_context.entry_count) return error.InvalidPreflight;
}
