const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_scheduling = @import("static_scheduling");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const corpus = static_testing.testing.corpus;
const fuzz_runner = static_testing.testing.fuzz_runner;
const identity = static_testing.testing.identity;
const replay_artifact = static_testing.testing.replay_artifact;
const replay_runner = static_testing.testing.replay_runner;
const seed_mod = static_testing.testing.seed;
const trace = static_testing.testing.trace;

const topo = static_scheduling.topo;

const deterministic_violation = [_]checker.Violation{
    .{
        .code = "task_graph_deterministic",
        .message = "task graph planning changed when the edge insertion order changed",
    },
};

const order_violation = [_]checker.Violation{
    .{
        .code = "task_graph_order",
        .message = "task graph plan violated one or more dependency edges",
    },
};

const cycle_violation = [_]checker.Violation{
    .{
        .code = "task_graph_cycle",
        .message = "task graph cycle handling diverged from the generated graph shape",
    },
};

const GraphCase = struct {
    node_count: u32,
    edge_count: usize,
    cyclic: bool,
    edges: [24]topo.Edge,
};

const Evaluation = struct {
    violations: ?[]const checker.Violation,
    checkpoint_digest: checker.CheckpointDigest,

    fn toCheckResult(self: Evaluation) checker.CheckResult {
        if (self.violations) |violations| {
            return checker.CheckResult.fail(violations, self.checkpoint_digest);
        }
        return checker.CheckResult.pass(self.checkpoint_digest);
    }
};

const TaskGraphTargetContext = struct {
    fn run(
        context_ptr: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const context: *const TaskGraphTargetContext = @ptrCast(@alignCast(context_ptr));
        _ = context;
        const generated = buildGraphCase(run_identity.seed.value);
        const evaluation = evaluateGraphCase(generated);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity, generated),
            .check_result = evaluation.toCheckResult(),
        };
    }

    fn replay(
        context_ptr: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution {
        const context: *const TaskGraphTargetContext = @ptrCast(@alignCast(context_ptr));
        _ = context;
        const generated = buildGraphCase(artifact.identity.seed.value);
        const evaluation = evaluateGraphCase(generated);
        return .{
            .trace_metadata = makeTraceMetadata(artifact.identity, generated),
            .check_result = evaluation.toCheckResult(),
        };
    }
};

test "task graph replay-backed campaigns preserve deterministic plan invariants" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const config = fuzz_runner.FuzzConfig{
        .package_name = "static_scheduling",
        .run_name = "task_graph_invariants",
        .base_seed = .{ .value = 0x17b4_2026_0000_3201 },
        .build_mode = .debug,
        .case_count_max = 128,
    };

    var target_context = TaskGraphTargetContext{};
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const runner = Runner{
        .config = config,
        .target = .{
            .context = &target_context,
            .run_fn = TaskGraphTargetContext.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_scheduling_task_graph" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    };

    const summary = try runner.run();
    try expectNoFailureOrReplay(
        io,
        tmp_dir.dir,
        summary,
        &target_context,
        TaskGraphTargetContext.replay,
    );
    try testing.expectEqual(config.case_count_max, summary.executed_case_count);
}

fn buildGraphCase(seed_value: u64) GraphCase {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x4b16_a351_7700_22c1);
    const random = prng.random();

    var graph_case = GraphCase{
        .node_count = 2 + random.uintLessThan(u32, 7),
        .edge_count = 0,
        .cyclic = (seed_value & 1) == 1,
        .edges = undefined,
    };

    if (graph_case.cyclic) {
        var node_index: u32 = 0;
        while (node_index + 1 < graph_case.node_count) : (node_index += 1) {
            graph_case.edges[graph_case.edge_count] = .{
                .from = node_index,
                .to = node_index + 1,
            };
            graph_case.edge_count += 1;
        }
        graph_case.edges[graph_case.edge_count] = .{
            .from = graph_case.node_count - 1,
            .to = 0,
        };
        graph_case.edge_count += 1;
        return graph_case;
    }

    var from: u32 = 0;
    while (from < graph_case.node_count and graph_case.edge_count < graph_case.edges.len) : (from += 1) {
        var to = from + 1;
        while (to < graph_case.node_count and graph_case.edge_count < graph_case.edges.len) : (to += 1) {
            if (!random.boolean()) continue;
            graph_case.edges[graph_case.edge_count] = .{
                .from = from,
                .to = to,
            };
            graph_case.edge_count += 1;
        }
    }

    return graph_case;
}

fn evaluateGraphCase(graph_case: GraphCase) Evaluation {
    var original_result = planGraph(graph_case, false) catch |err| switch (err) {
        error.CycleDetected => {
            if (graph_case.cyclic) return passEvaluation(graph_case);
            return failEvaluation(&cycle_violation, graph_case);
        },
        else => unreachable,
    };
    defer original_result.plan.deinit();

    var shuffled_result = planGraph(graph_case, true) catch |err| switch (err) {
        error.CycleDetected => return failEvaluation(&cycle_violation, graph_case),
        else => unreachable,
    };
    defer shuffled_result.plan.deinit();

    if (graph_case.cyclic) return failEvaluation(&cycle_violation, graph_case);
    if (!std.mem.eql(usize, original_result.plan.order, shuffled_result.plan.order)) {
        return failEvaluation(&deterministic_violation, graph_case);
    }
    if (!respectsEdges(graph_case, original_result.plan.order)) {
        return failEvaluation(&order_violation, graph_case);
    }
    return passEvaluation(graph_case);
}

const PlanResult = struct {
    plan: static_scheduling.task_graph.Plan,
};

fn planGraph(graph_case: GraphCase, shuffle_edges: bool) topo.TopoError!PlanResult {
    var graph = static_scheduling.task_graph.TaskGraph.init(testing.allocator, graph_case.node_count);
    defer graph.deinit();

    var edges: [24]topo.Edge = undefined;
    @memcpy(edges[0..graph_case.edge_count], graph_case.edges[0..graph_case.edge_count]);
    if (shuffle_edges) shuffleEdges(edges[0..graph_case.edge_count], graph_case);

    for (edges[0..graph_case.edge_count]) |edge| {
        try graph.addDependency(@intCast(edge.from), @intCast(edge.to));
    }

    return .{
        .plan = try graph.planDeterministic(testing.allocator),
    };
}

fn shuffleEdges(edges: []topo.Edge, graph_case: GraphCase) void {
    if (edges.len <= 1) return;
    var prng = std.Random.DefaultPrng.init(
        (@as(u64, graph_case.node_count) << 32) ^
            (@as(u64, @intCast(graph_case.edge_count)) << 1) ^
            0x9a37_4c01_51bf_8821,
    );
    const random = prng.random();
    var index = edges.len;
    while (index > 1) {
        index -= 1;
        const swap_index = random.uintLessThan(usize, index + 1);
        std.mem.swap(topo.Edge, &edges[index], &edges[swap_index]);
    }
}

fn respectsEdges(graph_case: GraphCase, order: []const usize) bool {
    if (order.len != graph_case.node_count) return false;
    var positions: [8]usize = [_]usize{0} ** 8;
    assert(graph_case.node_count <= positions.len);
    for (order, 0..) |node, position| {
        positions[node] = position;
    }
    for (graph_case.edges[0..graph_case.edge_count]) |edge| {
        if (positions[edge.from] >= positions[edge.to]) return false;
    }
    return true;
}

fn passEvaluation(graph_case: GraphCase) Evaluation {
    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(
            (@as(u128, graph_case.node_count) << 64) | graph_case.edge_count,
        ),
    };
}

fn failEvaluation(
    violations: []const checker.Violation,
    graph_case: GraphCase,
) Evaluation {
    return .{
        .violations = violations,
        .checkpoint_digest = checker.CheckpointDigest.init(
            (@as(u128, graph_case.node_count) << 64) | graph_case.edge_count,
        ),
    };
}

fn makeTraceMetadata(run_identity: identity.RunIdentity, graph_case: GraphCase) trace.TraceMetadata {
    return .{
        .event_count = @intCast(graph_case.edge_count),
        .truncated = false,
        .has_range = true,
        .first_sequence_no = run_identity.case_index,
        .last_sequence_no = run_identity.case_index,
        .first_timestamp_ns = graph_case.edge_count,
        .last_timestamp_ns = graph_case.edge_count,
    };
}

fn expectNoFailureOrReplay(
    io: std.Io,
    dir: std.Io.Dir,
    summary: fuzz_runner.FuzzRunSummary,
    replay_context: *TaskGraphTargetContext,
    replay_fn: *const fn (
        context: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution,
) !void {
    if (summary.failed_case) |failed_case| {
        try testing.expect(failed_case.persisted_entry_name != null);

        var read_buffer: [512]u8 = undefined;
        const entry = try corpus.readCorpusEntry(
            io,
            dir,
            failed_case.persisted_entry_name.?,
            &read_buffer,
        );

        const outcome = try replay_runner.runReplay(
            error{},
            read_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))],
            .{
                .context = replay_context,
                .run_fn = replay_fn,
            },
            .{
                .expected_identity_hash = entry.meta.identity_hash,
            },
        );
        try testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, outcome);

        std.debug.print("static_scheduling task graph regression persisted at {s}\n", .{
            failed_case.persisted_entry_name.?,
        });
        for (failed_case.check_result.violations) |violation| {
            std.debug.print("violation {s}: {s}\n", .{
                violation.code,
                violation.message,
            });
        }
        return error.TestUnexpectedResult;
    }
}
