//! `static_spatial` BVH build/query baseline benchmarks.
//!
//! Measures one deterministic non-incremental `BVH` geometry set across build
//! and the canonical query surfaces admitted by the active plan.

const std = @import("std");
const static_spatial = @import("static_spatial");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const benchmark_name = "bvh_query_baselines";
const item_count: usize = 64;
const grid_dim: usize = 4;
const cell_min_offset: f32 = 0.1;
const cell_max_offset: f32 = 0.4;
const bench_config = support.default_benchmark_config;

const IntBVH = static_spatial.BVH(u32);
const RayHit = IntBVH.RayHit;

const BuildContext = struct {
    items: []const IntBVH.Item,
};

const QueryAABBContext = struct {
    bvh: *const IntBVH,
};

const QueryRayContext = struct {
    bvh: *const IntBVH,
};

const QueryRaySortedContext = struct {
    bvh: *const IntBVH,
};

const QueryFrustumContext = struct {
    bvh: *const IntBVH,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try validateSemanticPreflight(allocator);

    var items: [item_count]IntBVH.Item = undefined;
    fillGeometry(&items);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, benchmark_name);
    defer output_dir.close(io);

    var bvh = try IntBVH.build(std.heap.page_allocator, &items, .{
        .strategy = .middle,
        .max_leaf_items = 4,
    });
    defer bvh.deinit(std.heap.page_allocator);

    var build_context = BuildContext{ .items = &items };
    var query_aabb_context = QueryAABBContext{ .bvh = &bvh };
    var query_ray_context = QueryRayContext{ .bvh = &bvh };
    var query_ray_sorted_context = QueryRaySortedContext{ .bvh = &bvh };
    var query_frustum_context = QueryFrustumContext{ .bvh = &bvh };

    var case_storage: [5]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_spatial_bvh_query_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "build_bvh",
        .tags = &[_][]const u8{ "static_spatial", "bvh", "build", "baseline" },
        .context = &build_context,
        .run_fn = runBuild,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "query_aabb",
        .tags = &[_][]const u8{ "static_spatial", "bvh", "query", "aabb", "baseline" },
        .context = &query_aabb_context,
        .run_fn = runQueryAABB,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "query_ray",
        .tags = &[_][]const u8{ "static_spatial", "bvh", "query", "ray", "baseline" },
        .context = &query_ray_context,
        .run_fn = runQueryRay,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "query_ray_sorted",
        .tags = &[_][]const u8{ "static_spatial", "bvh", "query", "ray_sorted", "baseline" },
        .context = &query_ray_sorted_context,
        .run_fn = runQueryRaySorted,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "query_frustum",
        .tags = &[_][]const u8{ "static_spatial", "bvh", "query", "frustum", "baseline" },
        .context = &query_frustum_context,
        .run_fn = runQueryFrustum,
    }));

    var sample_storage: [bench_config.sample_count * 5]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [5]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    var stats_storage: [5]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [4096]u8 = undefined;
    var read_source_buffer: [4096]u8 = undefined;
    var read_parse_buffer: [16_384]u8 = undefined;
    var comparisons: [10]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [32_768]u8 = undefined;
    var history_record_buffer: [16_384]u8 = undefined;
    var history_frame_buffer: [16_384]u8 = undefined;
    var history_output_buffer: [32_768]u8 = undefined;
    var history_file_buffer: [32_768]u8 = undefined;
    var history_cases: [5]bench.stats.BenchmarkStats = undefined;
    var history_names: [2048]u8 = undefined;
    var history_tags: [8][]const u8 = undefined;
    var history_comparisons: [10]bench.baseline.BaselineCaseComparison = undefined;
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();

    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&aw.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .compare_config = support.default_compare_config,
        .enforce_gate = false,
        .stats_storage = &stats_storage,
        .baseline_document_buffer = &baseline_document_buffer,
        .read_buffers = .{
            .source_buffer = &read_source_buffer,
            .parse_buffer = &read_parse_buffer,
        },
        .comparison_storage = &comparisons,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_spatial",
            .environment_note = support.default_environment_note,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_names,
                .tag_storage = &history_tags,
            },
            .comparison_storage = &history_comparisons,
        },
    });

    var report = aw.toArrayList();
    defer report.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{report.items});
}

fn runBuild(context_ptr: *anyopaque) void {
    const context: *const BuildContext = @ptrCast(@alignCast(context_ptr));
    var bvh = IntBVH.build(
        std.heap.page_allocator,
        context.items,
        .{
            .strategy = .middle,
            .max_leaf_items = 4,
        },
    ) catch unreachable;
    defer bvh.deinit(std.heap.page_allocator);

    std.debug.assert(bvh.items.len == context.items.len);
    std.debug.assert(bvh.nodes.len > 0);
    _ = bench.case.blackBox(@as(u32, @intCast(bvh.nodes.len)));
}

fn runQueryAABB(context_ptr: *anyopaque) void {
    const context: *const QueryAABBContext = @ptrCast(@alignCast(context_ptr));
    const query = spatialAABBQuery();
    var hits: [item_count]u32 = undefined;
    const count = context.bvh.queryAABB(query, &hits);
    std.debug.assert(count > 0);
    _ = bench.case.blackBox(count);
}

fn runQueryRay(context_ptr: *anyopaque) void {
    const context: *const QueryRayContext = @ptrCast(@alignCast(context_ptr));
    const ray = spatialRayQuery();
    var hits: [item_count]u32 = undefined;
    const count = context.bvh.queryRay(ray, &hits);
    std.debug.assert(count > 0);
    _ = bench.case.blackBox(count);
}

fn runQueryRaySorted(context_ptr: *anyopaque) void {
    const context: *const QueryRaySortedContext = @ptrCast(@alignCast(context_ptr));
    const ray = spatialRayQuery();
    var hits: [item_count]RayHit = undefined;
    const count = context.bvh.queryRaySorted(ray, &hits);
    var sink: f32 = @floatFromInt(count);
    var i: usize = 0;
    while (i < @min(@as(usize, @intCast(count)), hits.len)) : (i += 1) {
        sink += hits[i].t + @as(f32, @floatFromInt(hits[i].value));
    }
    std.debug.assert(count > 0);
    _ = bench.case.blackBox(sink);
}

fn runQueryFrustum(context_ptr: *anyopaque) void {
    const context: *const QueryFrustumContext = @ptrCast(@alignCast(context_ptr));
    const frustum = spatialFrustumQuery();
    var hits: [item_count]u32 = undefined;
    const count = context.bvh.queryFrustum(frustum, &hits);
    std.debug.assert(count > 0);
    _ = bench.case.blackBox(count);
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var items: [item_count]IntBVH.Item = undefined;
    fillGeometry(&items);

    var bvh = try IntBVH.build(allocator, &items, .{
        .strategy = .middle,
        .max_leaf_items = 4,
    });
    defer bvh.deinit(allocator);

    var aabb_hits: [item_count]u32 = undefined;
    const aabb_count = bvh.queryAABB(spatialAABBQuery(), &aabb_hits);
    if (aabb_count != 27) return error.BenchmarkContractViolation;

    var ray_hits: [item_count]u32 = undefined;
    const ray_count = bvh.queryRay(spatialRayQuery(), &ray_hits);
    if (ray_count != 4) return error.BenchmarkContractViolation;
    var seen: [4]bool = .{ false, false, false, false };
    for (ray_hits[0..ray_count]) |value| {
        if (value > 3) return error.BenchmarkContractViolation;
        seen[value] = true;
    }
    for (seen) |found| {
        if (!found) return error.BenchmarkContractViolation;
    }

    var sorted_hits: [item_count]RayHit = undefined;
    const sorted_count = bvh.queryRaySorted(spatialRayQuery(), &sorted_hits);
    if (sorted_count != 4) return error.BenchmarkContractViolation;
    var index: usize = 0;
    while (index < @as(usize, @intCast(sorted_count))) : (index += 1) {
        if (sorted_hits[index].value != @as(u32, @intCast(index))) {
            return error.BenchmarkContractViolation;
        }
        if (index > 0 and sorted_hits[index - 1].t > sorted_hits[index].t) {
            return error.BenchmarkContractViolation;
        }
    }

    var frustum_hits: [item_count]u32 = undefined;
    const frustum_count = bvh.queryFrustum(spatialFrustumQuery(), &frustum_hits);
    if (frustum_count != 18) return error.BenchmarkContractViolation;
}

fn fillGeometry(items: *[item_count]IntBVH.Item) void {
    var index: usize = 0;
    var z: usize = 0;
    while (z < grid_dim) : (z += 1) {
        var y: usize = 0;
        while (y < grid_dim) : (y += 1) {
            var x: usize = 0;
            while (x < grid_dim) : (x += 1) {
                const min_x = @as(f32, @floatFromInt(x)) + cell_min_offset;
                const min_y = @as(f32, @floatFromInt(y)) + cell_min_offset;
                const min_z = @as(f32, @floatFromInt(z)) + cell_min_offset;
                items[index] = .{
                    .bounds = static_spatial.AABB3.init(
                        min_x,
                        min_y,
                        min_z,
                        min_x + cell_max_offset - cell_min_offset,
                        min_y + cell_max_offset - cell_min_offset,
                        min_z + cell_max_offset - cell_min_offset,
                    ),
                    .value = @as(u32, @intCast(x + y * grid_dim + z * grid_dim * grid_dim)),
                };
                index += 1;
            }
        }
    }
    std.debug.assert(index == item_count);
}

fn spatialAABBQuery() static_spatial.AABB3 {
    return static_spatial.AABB3.init(0.0, 0.0, 0.0, 2.6, 2.6, 2.6);
}

fn spatialRayQuery() static_spatial.Ray3 {
    return static_spatial.Ray3.init(-1.0, 0.25, 0.25, 1.0, 0.0, 0.0);
}

fn spatialFrustumQuery() static_spatial.Frustum {
    return .{
        .planes = .{
            .{ .normal_x = 1.0, .normal_y = 0.0, .normal_z = 0.0, .d = 0.0 },
            .{ .normal_x = -1.0, .normal_y = 0.0, .normal_z = 0.0, .d = 1.6 },
            .{ .normal_x = 0.0, .normal_y = 1.0, .normal_z = 0.0, .d = 0.0 },
            .{ .normal_x = 0.0, .normal_y = -1.0, .normal_z = 0.0, .d = 2.6 },
            .{ .normal_x = 0.0, .normal_y = 0.0, .normal_z = 1.0, .d = 0.0 },
            .{ .normal_x = 0.0, .normal_y = 0.0, .normal_z = -1.0, .d = 2.6 },
        },
    };
}
