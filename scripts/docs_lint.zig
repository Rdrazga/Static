const std = @import("std");

const max_file_bytes: usize = 1024 * 1024;
const max_agents_lines: u32 = 80;

const Failure = error{DocsLintFailed};

const Linter = struct {
    failure_count: u32 = 0,

    fn fail(
        self: *Linter,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.failure_count += 1;
        std.debug.print("docs-lint: " ++ format ++ "\n", args);
    }
};

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var linter: Linter = .{};

    const agents = try readFile(arena, init.io, "AGENTS.md");
    checkMaxLines(&linter, "AGENTS.md", agents, max_agents_lines);
    checkContains(&linter, "AGENTS.md", agents, "`README.md`");
    checkContains(&linter, "AGENTS.md", agents, "`docs/reference/zig_coding_rules.md`");
    checkContains(&linter, "AGENTS.md", agents, "`zig build harness`");
    checkContains(&linter, "AGENTS.md", agents, "`packages/static_testing/README.md`");
    checkContains(&linter, "AGENTS.md", agents, "`packages/static_testing/AGENTS.md`");

    const readme = try readFile(arena, init.io, "README.md");
    checkContains(&linter, "README.md", readme, "`AGENTS.md`");
    checkContains(&linter, "README.md", readme, "`docs/architecture.md`");
    checkContains(&linter, "README.md", readme, "`docs/plans/README.md`");
    checkContains(&linter, "README.md", readme, "`zig build harness`");
    checkContains(&linter, "README.md", readme, "`packages/static_testing/README.md`");
    checkContains(&linter, "README.md", readme, "`packages/static_testing/AGENTS.md`");
    _ = try readFile(arena, init.io, "packages/static_testing/README.md");
    _ = try readFile(arena, init.io, "packages/static_testing/AGENTS.md");

    const architecture = try readFile(arena, init.io, "docs/architecture.md");
    checkContains(&linter, "docs/architecture.md", architecture, "`static_testing`");
    const docs_map = try readFile(arena, init.io, "docs/README.md");
    checkContains(&linter, "docs/README.md", docs_map, "`design/`");
    checkContains(&linter, "docs/README.md", docs_map, "`decisions/`");
    checkContains(&linter, "docs/README.md", docs_map, "`plans/`");
    checkContains(&linter, "docs/README.md", docs_map, "`reference/`");
    checkContains(&linter, "docs/README.md", docs_map, "`sketches/`");

    const plans = try readFile(arena, init.io, "docs/plans/README.md");
    checkContains(&linter, "docs/plans/README.md", plans, "`docs/plans/active/`");
    checkContains(
        &linter,
        "docs/plans/README.md",
        plans,
        "`docs/plans/active/README.md`",
    );
    checkContains(&linter, "docs/plans/README.md", plans, "`docs/plans/completed/`");
    const active_plans = try readFile(arena, init.io, "docs/plans/active/README.md");
    checkContains(
        &linter,
        "docs/plans/active/README.md",
        active_plans,
        "`workspace_operations.md`",
    );
    checkContains(
        &linter,
        "docs/plans/active/README.md",
        active_plans,
        "`packages/`",
    );
    _ = try readFile(arena, init.io, "docs/plans/active/workspace_operations.md");
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_package_completion_2026-03-24.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_swarm_runner_orchestration_2026-03-24.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_artifact_formats_and_storage_2026-03-24.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_benchmark_baselines_2026-03-23.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_benchmark_history_and_environment_metadata_2026-03-23.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_causality_and_provenance_tracing_2026-03-23.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_state_machine_harness_2026-03-23.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/deterministic_subsystem_simulators.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_replay_failure_bundles_2026-03-23.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_schedule_exploration_2026-03-24.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/system_e2e_deterministic_harness.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/repair_liveness_execution.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/static_testing_temporal_property_assertions_2026-03-23.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/sketches/archive/static_testing_artifact_format_strategy_2026-03-18.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/sketches/archive/static_testing_feature_sketch_swarm_runner_orchestration_2026-03-16.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/sketches/archive/static_testing_swarm_runner_module_api_2026-03-16.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/sketches/archive/static_testing_tigerbeetle_vopr_gap_review_2026-03-21.md",
    );

    const design = try readFile(arena, init.io, "docs/design/README.md");
    checkContains(&linter, "docs/design/README.md", design, "`01_api_consistency.md`");
    checkContains(
        &linter,
        "docs/design/README.md",
        design,
        "`10_io_concurrency_runtime_architecture.md`",
    );

    const decisions = try readFile(arena, init.io, "docs/decisions/README.md");
    checkContains(
        &linter,
        "docs/decisions/README.md",
        decisions,
        "`2026-03-06_bits_serial_boundary.md`",
    );

    const sketches = try readFile(arena, init.io, "docs/sketches/README.md");
    checkContains(&linter, "docs/sketches/README.md", sketches, "`archive/`");

    const reference = try readFile(arena, init.io, "docs/reference/README.md");
    checkContains(&linter, "docs/reference/README.md", reference, "`zig_coding_rules.md`");
    checkContains(
        &linter,
        "docs/reference/README.md",
        reference,
        "`zig_coding_rules/design_and_safety.md`",
    );
    checkContains(
        &linter,
        "docs/reference/README.md",
        reference,
        "`zig_coding_rules/testing_and_docs.md`",
    );

    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/harness_engineering_repo_alignment_2026-03-16.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/plans/completed/zig_coding_rules_domain_split_2026-03-16.md",
    );
    const rules_index = try readFile(
        arena,
        init.io,
        "docs/reference/zig_coding_rules.md",
    );
    checkContains(
        &linter,
        "docs/reference/zig_coding_rules.md",
        rules_index,
        "`docs/reference/zig_coding_rules/design_and_safety.md`",
    );
    checkContains(
        &linter,
        "docs/reference/zig_coding_rules.md",
        rules_index,
        "`docs/reference/zig_coding_rules/repo_workflow.md`",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/reference/zig_coding_rules/design_and_safety.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/reference/zig_coding_rules/performance.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/reference/zig_coding_rules/api_and_style.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/reference/zig_coding_rules/repo_workflow.md",
    );
    _ = try readFile(
        arena,
        init.io,
        "docs/reference/zig_coding_rules/testing_and_docs.md",
    );

    if (linter.failure_count != 0) {
        return Failure.DocsLintFailed;
    }
}

fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    std.debug.assert(path.len != 0);
    return try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_bytes),
    );
}

fn checkContains(
    linter: *Linter,
    path: []const u8,
    content: []const u8,
    needle: []const u8,
) void {
    std.debug.assert(path.len != 0);
    std.debug.assert(needle.len != 0);

    if (std.mem.indexOf(u8, content, needle) == null) {
        linter.fail("{s} is missing required text: {s}", .{ path, needle });
    }
}

fn checkMaxLines(
    linter: *Linter,
    path: []const u8,
    content: []const u8,
    line_count_max: u32,
) void {
    std.debug.assert(path.len != 0);
    std.debug.assert(line_count_max > 0);

    const line_count: u32 = countLines(content);
    if (line_count > line_count_max) {
        linter.fail(
            "{s} has {d} lines but the maximum is {d}",
            .{ path, line_count, line_count_max },
        );
    }
}

fn countLines(content: []const u8) u32 {
    if (content.len == 0) {
        return 0;
    }

    var line_count: u32 = 1;
    for (content) |byte| {
        if (byte == '\n') {
            line_count += 1;
        }
    }
    return line_count;
}
