const std = @import("std");
const static_scheduling = @import("static_scheduling");
const static_testing = @import("static_testing");

const bench = static_testing.bench;
const topo = static_scheduling.topo;
const Wheel = static_scheduling.timer_wheel.TimerWheel(u32);

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 8,
    .measure_iterations = 1024,
    .sample_count = 8,
};

const small_edges = [_]topo.Edge{
    .{ .from = 0, .to = 2 },
    .{ .from = 1, .to = 2 },
    .{ .from = 2, .to = 3 },
    .{ .from = 2, .to = 4 },
    .{ .from = 3, .to = 5 },
    .{ .from = 4, .to = 5 },
};

const medium_edges = [_]topo.Edge{
    .{ .from = 0, .to = 4 },
    .{ .from = 0, .to = 5 },
    .{ .from = 1, .to = 5 },
    .{ .from = 1, .to = 6 },
    .{ .from = 2, .to = 6 },
    .{ .from = 2, .to = 7 },
    .{ .from = 3, .to = 7 },
    .{ .from = 3, .to = 8 },
    .{ .from = 4, .to = 9 },
    .{ .from = 5, .to = 9 },
    .{ .from = 5, .to = 10 },
    .{ .from = 6, .to = 10 },
    .{ .from = 6, .to = 11 },
    .{ .from = 7, .to = 11 },
    .{ .from = 7, .to = 12 },
    .{ .from = 8, .to = 12 },
    .{ .from = 9, .to = 13 },
    .{ .from = 10, .to = 13 },
    .{ .from = 10, .to = 14 },
    .{ .from = 11, .to = 14 },
    .{ .from = 11, .to = 15 },
    .{ .from = 12, .to = 15 },
};

const CaseOp = enum {
    task_graph_small_plan,
    task_graph_medium_plan,
    timer_wheel_schedule_cancel,
    timer_wheel_tick_due_batch,
};

const PlanningBenchContext = struct {
    name: []const u8,
    op: CaseOp,
    node_count: usize = 0,
    edges: []const topo.Edge = &.{},
    storage: [24_576]u8 = undefined,
    sink_u64: u64 = 0,
    sink_u32: u32 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *PlanningBenchContext = @ptrCast(@alignCast(context_ptr));
        var fba = std.heap.FixedBufferAllocator.init(&context.storage);
        const allocator = fba.allocator();

        switch (context.op) {
            .task_graph_small_plan, .task_graph_medium_plan => {
                var graph = static_scheduling.task_graph.TaskGraph.init(allocator, context.node_count);
                defer graph.deinit();
                for (context.edges) |edge| {
                    graph.addDependency(@intCast(edge.from), @intCast(edge.to)) catch unreachable;
                }
                var plan = graph.planDeterministic(allocator) catch unreachable;
                defer plan.deinit();
                context.sink_u64 = bench.case.blackBox(plan.order.len);
            },
            .timer_wheel_schedule_cancel => {
                var wheel = Wheel.init(allocator, .{
                    .buckets = 16,
                    .entries_max = 16,
                }) catch unreachable;
                defer wheel.deinit();
                var ids: [16]static_scheduling.timer_wheel.TimerId = undefined;
                for (&ids, 0..) |*id, index| {
                    id.* = wheel.schedule(@intCast(index + 1), @intCast(index % 4)) catch unreachable;
                }
                var total: u32 = 0;
                for (ids, 0..) |id, index| {
                    if ((index & 1) != 0) continue;
                    total +%= wheel.cancel(id) catch unreachable;
                }
                context.sink_u32 = bench.case.blackBox(total);
            },
            .timer_wheel_tick_due_batch => {
                var wheel = Wheel.init(allocator, .{
                    .buckets = 16,
                    .entries_max = 16,
                }) catch unreachable;
                defer wheel.deinit();
                for (0..16) |index| {
                    _ = wheel.schedule(@intCast(index + 1), 0) catch unreachable;
                }
                var drained: [16]u32 = undefined;
                const count = wheel.tick(&drained) catch unreachable;
                var total: u32 = 0;
                for (drained[0..count]) |value| total +%= value;
                context.sink_u32 = bench.case.blackBox(total);
            },
        }
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();
    const output_dir_path = ".zig-cache/static_scheduling/benchmarks/planning_baselines";
    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer output_dir.close(io);

    var contexts = [_]PlanningBenchContext{
        .{
            .name = "task_graph_small_plan",
            .op = .task_graph_small_plan,
            .node_count = 6,
            .edges = &small_edges,
        },
        .{
            .name = "task_graph_medium_plan",
            .op = .task_graph_medium_plan,
            .node_count = 16,
            .edges = &medium_edges,
        },
        .{
            .name = "timer_wheel_schedule_cancel",
            .op = .timer_wheel_schedule_cancel,
        },
        .{
            .name = "timer_wheel_tick_due_batch",
            .op = .timer_wheel_tick_due_batch,
        },
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_scheduling_planning_baselines",
        .config = bench_config,
    });

    inline for (&contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_scheduling", "planning", "baseline" },
            .context = context,
            .run_fn = PlanningBenchContext.run,
        }));
    }

    var sample_storage: [contexts.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [contexts.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_scheduling planning baselines ==\n", .{});
    var stats_storage: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [4096]u8 = undefined;
    var read_source_buffer: [4096]u8 = undefined;
    var read_parse_buffer: [16_384]u8 = undefined;
    var comparisons: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [32_768]u8 = undefined;
    var history_record_buffer: [16_384]u8 = undefined;
    var history_frame_buffer: [16_384]u8 = undefined;
    var history_output_buffer: [32_768]u8 = undefined;
    var history_file_buffer: [32_768]u8 = undefined;
    var history_cases: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var history_names: [2048]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&aw.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .compare_config = .{
            .thresholds = .{
                .median_ratio_ppm = 300_000,
                .p95_ratio_ppm = 400_000,
            },
        },
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
            .package_name = "static_scheduling",
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
    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{out.items});
}

fn validateSemanticPreflight() void {
    var graph = static_scheduling.task_graph.TaskGraph.init(std.heap.page_allocator, 6);
    defer graph.deinit();
    for (small_edges) |edge| {
        graph.addDependency(@intCast(edge.from), @intCast(edge.to)) catch unreachable;
    }
    var plan = graph.planDeterministic(std.heap.page_allocator) catch unreachable;
    defer plan.deinit();
    std.debug.assert(plan.order.len == 6);
    std.debug.assert(plan.order[0] == 0);

    var wheel = Wheel.init(std.heap.page_allocator, .{
        .buckets = 8,
        .entries_max = 8,
    }) catch unreachable;
    defer wheel.deinit();
    const id = wheel.schedule(11, 0) catch unreachable;
    std.debug.assert((wheel.cancel(id) catch unreachable) == 11);
    _ = wheel.schedule(21, 0) catch unreachable;
    _ = wheel.schedule(22, 0) catch unreachable;
    var drained: [8]u32 = undefined;
    const count = wheel.tick(&drained) catch unreachable;
    std.debug.assert(count == 2);
    std.debug.assert(drained[0] == 21);
    std.debug.assert(drained[1] == 22);
}
