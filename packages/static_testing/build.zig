// This package supports local validation with `zig build` from this directory
// and workspace-wide validation from the repository root.
const std = @import("std");
const assert = std.debug.assert;

const SmokeExample = enum {
    replay_roundtrip,
    bench_smoke,
    bench_baseline_compare,
    fuzz_seeded_runner,
    sim_timer_mailbox,
    system_storage_retry_flow,
    system_process_driver_flow,
    swarm_sim_runner,
};

const ExampleSpec = struct {
    name: []const u8,
    path: []const u8,
    needs_driver_echo: bool = false,
    smoke_role: ?SmokeExample = null,
};

const TestSteps = struct {
    run_unit_tests: *std.Build.Step,
    run_integration_tests: *std.Build.Step,
};

const ExampleSteps = struct {
    run_replay_roundtrip: *std.Build.Step,
    run_bench_smoke: *std.Build.Step,
    run_bench_baseline_compare: *std.Build.Step,
    run_fuzz_seeded_runner: *std.Build.Step,
    run_sim_timer_mailbox: *std.Build.Step,
    run_system_storage_retry_flow: *std.Build.Step,
    run_system_process_driver_flow: *std.Build.Step,
    run_swarm_sim_runner: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const single_threaded = b.option(
        bool,
        "single_threaded",
        "Disable thread-based behavior",
    ) orelse false;
    const enable_os_backends = b.option(
        bool,
        "enable_os_backends",
        "Enable OS-specific backends",
    ) orelse false;
    const enable_tracing = b.option(
        bool,
        "enable_tracing",
        "Enable tracing/instrumentation hooks",
    ) orelse false;

    const static_testing_mod = addStaticTestingModule(b, .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });

    const test_steps = addTestStep(b, .{
        .target = target,
        .optimize = optimize,
        .module = static_testing_mod,
    });
    const example_steps = addExampleStep(b, .{
        .target = target,
        .optimize = optimize,
        .module = static_testing_mod,
    });
    addBenchmarkStep(b, .{
        .target = target,
        .optimize = optimize,
        .module = static_testing_mod,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    addSmokeStep(b, test_steps, example_steps);
}

const ModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    single_threaded: bool,
    enable_os_backends: bool,
    enable_tracing: bool,
};

fn addStaticTestingModule(b: *std.Build, options: ModuleOptions) *std.Build.Module {
    const package_options = b.addOptions();
    package_options.addOption(bool, "single_threaded", options.single_threaded);
    package_options.addOption(bool, "enable_os_backends", options.enable_os_backends);
    package_options.addOption(bool, "enable_tracing", options.enable_tracing);
    package_options.addOption([]const u8, "static_package", "static_testing");
    const options_mod = package_options.createModule();

    const core_dep = b.dependency("static_core", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });
    const rng_dep = b.dependency("static_rng", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });
    const profile_dep = b.dependency("static_profile", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });
    const queues_dep = b.dependency("static_queues", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });
    const scheduling_dep = b.dependency("static_scheduling", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });
    const bits_dep = b.dependency("static_bits", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });
    const serial_dep = b.dependency("static_serial", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });

    return b.addModule("static_testing", .{
        .root_source_file = b.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_core", .module = core_dep.module("static_core") },
            .{ .name = "static_rng", .module = rng_dep.module("static_rng") },
            .{ .name = "static_profile", .module = profile_dep.module("static_profile") },
            .{ .name = "static_queues", .module = queues_dep.module("static_queues") },
            .{ .name = "static_scheduling", .module = scheduling_dep.module("static_scheduling") },
            .{ .name = "static_bits", .module = bits_dep.module("static_bits") },
            .{ .name = "static_serial", .module = serial_dep.module("static_serial") },
        },
    });
}

const TestStepOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
};

fn addTestStep(b: *std.Build, options: TestStepOptions) TestSteps {
    const unit_tests = b.addTest(.{ .root_module = options.module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const driver_echo_exe = b.addExecutable(.{
        .name = "static_testing_driver_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/support/driver_echo.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "static_testing", .module = options.module },
            },
        }),
    });

    const integration_test_options = b.addOptions();
    integration_test_options.addOptionPath("driver_echo_path", driver_echo_exe.getEmittedBin());

    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "static_testing", .module = options.module },
        },
    });
    integration_test_mod.addOptions(
        "static_testing_integration_options",
        integration_test_options,
    );

    const integration_tests = b.addTest(.{
        .root_module = integration_test_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(&driver_echo_exe.step);

    const integration_step = b.step("integration", "Run package integration tests");
    integration_step.dependOn(&run_integration_tests.step);

    const test_step = b.step("test", "Run package unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    return .{
        .run_unit_tests = &run_unit_tests.step,
        .run_integration_tests = &run_integration_tests.step,
    };
}

const ExampleStepOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
};

fn addExampleStep(b: *std.Build, options: ExampleStepOptions) ExampleSteps {
    const examples_step = b.step("examples", "Run package examples");
    const driver_echo_exe = b.addExecutable(.{
        .name = "static_testing_example_driver_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/support/driver_echo.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "static_testing", .module = options.module },
            },
        }),
    });
    const example_options = b.addOptions();
    example_options.addOptionPath("driver_echo_path", driver_echo_exe.getEmittedBin());
    const example_options_mod = example_options.createModule();

    const examples = [_]ExampleSpec{
        .{
            .name = "static_testing_replay_roundtrip",
            .path = "examples/replay_roundtrip.zig",
            .smoke_role = .replay_roundtrip,
        },
        .{
            .name = "static_testing_replay_runner_roundtrip",
            .path = "examples/replay_runner_roundtrip.zig",
        },
        .{
            .name = "static_testing_bench_smoke",
            .path = "examples/bench_smoke.zig",
            .smoke_role = .bench_smoke,
        },
        .{
            .name = "static_testing_process_bench_smoke",
            .path = "examples/process_bench_smoke.zig",
        },
        .{
            .name = "static_testing_process_driver_roundtrip",
            .path = "examples/process_driver_roundtrip.zig",
            .needs_driver_echo = true,
        },
        .{
            .name = "static_testing_corpus_roundtrip",
            .path = "examples/corpus_roundtrip.zig",
        },
        .{
            .name = "static_testing_trace_chrome_json",
            .path = "examples/trace_chrome_json.zig",
        },
        .{
            .name = "static_testing_driver_protocol_headers",
            .path = "examples/driver_protocol_headers.zig",
        },
        .{
            .name = "static_testing_sim_scheduler_replay",
            .path = "examples/sim_scheduler_replay.zig",
        },
        .{
            .name = "static_testing_sim_explore_portfolio",
            .path = "examples/sim_explore_portfolio.zig",
        },
        .{
            .name = "static_testing_sim_explore_pct_bias",
            .path = "examples/sim_explore_pct_bias.zig",
        },
        .{
            .name = "static_testing_ordered_effect_sequencer",
            .path = "examples/ordered_effect_sequencer.zig",
        },
        .{
            .name = "static_testing_sim_network_link",
            .path = "examples/sim_network_link.zig",
        },
        .{
            .name = "static_testing_sim_network_link_group_partition",
            .path = "examples/sim_network_link_group_partition.zig",
        },
        .{
            .name = "static_testing_sim_network_link_backlog_pressure",
            .path = "examples/sim_network_link_backlog_pressure.zig",
        },
        .{
            .name = "static_testing_sim_network_link_record_replay",
            .path = "examples/sim_network_link_record_replay.zig",
        },
        .{
            .name = "static_testing_sim_storage_lane",
            .path = "examples/sim_storage_lane.zig",
        },
        .{
            .name = "static_testing_sim_storage_durability",
            .path = "examples/sim_storage_durability.zig",
        },
        .{
            .name = "static_testing_sim_storage_durability_record_replay",
            .path = "examples/sim_storage_durability_record_replay.zig",
        },
        .{
            .name = "static_testing_sim_storage_durability_misdirected_write",
            .path = "examples/sim_storage_durability_misdirected_write.zig",
        },
        .{
            .name = "static_testing_sim_storage_durability_acknowledged_not_durable",
            .path = "examples/sim_storage_durability_acknowledged_not_durable.zig",
        },
        .{
            .name = "static_testing_sim_clock_drift",
            .path = "examples/sim_clock_drift.zig",
        },
        .{
            .name = "static_testing_sim_retry_queue",
            .path = "examples/sim_retry_queue.zig",
        },
        .{
            .name = "static_testing_sim_storage_retry_flow",
            .path = "examples/sim_storage_retry_flow.zig",
        },
        .{
            .name = "static_testing_system_storage_retry_flow",
            .path = "examples/system_storage_retry_flow.zig",
            .smoke_role = .system_storage_retry_flow,
        },
        .{
            .name = "static_testing_system_process_driver_flow",
            .path = "examples/system_process_driver_flow.zig",
            .needs_driver_echo = true,
            .smoke_role = .system_process_driver_flow,
        },
        .{
            .name = "static_testing_fuzz_seeded_runner",
            .path = "examples/fuzz_seeded_runner.zig",
            .smoke_role = .fuzz_seeded_runner,
        },
        .{
            .name = "static_testing_bench_export_formats",
            .path = "examples/bench_export_formats.zig",
        },
        .{
            .name = "static_testing_bench_baseline_compare",
            .path = "examples/bench_baseline_compare.zig",
            .smoke_role = .bench_baseline_compare,
        },
        .{
            .name = "static_testing_bench_stats_with_scratch",
            .path = "examples/bench_stats_with_scratch.zig",
        },
        .{
            .name = "static_testing_sim_timer_mailbox",
            .path = "examples/sim_timer_mailbox.zig",
            .smoke_role = .sim_timer_mailbox,
        },
        .{
            .name = "static_testing_swarm_sim_runner",
            .path = "examples/swarm_sim_runner.zig",
            .smoke_role = .swarm_sim_runner,
        },
        .{
            .name = "static_testing_repair_liveness_basic",
            .path = "examples/repair_liveness_basic.zig",
        },
        .{
            .name = "static_testing_model_state_machine",
            .path = "examples/model_state_machine.zig",
        },
        .{
            .name = "static_testing_model_sim_fixture",
            .path = "examples/model_sim_fixture.zig",
        },
        .{
            .name = "static_testing_model_temporal_assertions",
            .path = "examples/model_temporal_assertions.zig",
        },
        .{
            .name = "static_testing_model_protocol_state",
            .path = "examples/model_protocol_state.zig",
        },
        .{
            .name = "static_testing_sim_temporal_assertions",
            .path = "examples/sim_temporal_assertions.zig",
        },
    };

    var run_replay_roundtrip_step: ?*std.Build.Step = null;
    var run_bench_smoke_step: ?*std.Build.Step = null;
    var run_bench_baseline_compare_step: ?*std.Build.Step = null;
    var run_fuzz_seeded_runner_step: ?*std.Build.Step = null;
    var run_sim_timer_mailbox_step: ?*std.Build.Step = null;
    var run_system_storage_retry_flow_step: ?*std.Build.Step = null;
    var run_system_process_driver_flow_step: ?*std.Build.Step = null;
    var run_swarm_sim_runner_step: ?*std.Build.Step = null;

    for (examples) |example| {
        const root_module = if (example.needs_driver_echo)
            b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "static_testing", .module = options.module },
                    .{ .name = "static_testing_example_options", .module = example_options_mod },
                },
            })
        else
            b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "static_testing", .module = options.module },
                },
            });
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = root_module,
        });
        const run_example = b.addRunArtifact(exe);
        if (example.needs_driver_echo) {
            run_example.step.dependOn(&driver_echo_exe.step);
        }
        examples_step.dependOn(&run_example.step);

        if (example.smoke_role) |smoke_role| {
            switch (smoke_role) {
                .replay_roundtrip => run_replay_roundtrip_step = &run_example.step,
                .bench_smoke => run_bench_smoke_step = &run_example.step,
                .bench_baseline_compare => run_bench_baseline_compare_step = &run_example.step,
                .fuzz_seeded_runner => run_fuzz_seeded_runner_step = &run_example.step,
                .sim_timer_mailbox => run_sim_timer_mailbox_step = &run_example.step,
                .system_storage_retry_flow => run_system_storage_retry_flow_step = &run_example.step,
                .system_process_driver_flow => run_system_process_driver_flow_step = &run_example.step,
                .swarm_sim_runner => run_swarm_sim_runner_step = &run_example.step,
            }
        }
    }

    assert(run_replay_roundtrip_step != null);
    assert(run_bench_smoke_step != null);
    assert(run_bench_baseline_compare_step != null);
    assert(run_fuzz_seeded_runner_step != null);
    assert(run_sim_timer_mailbox_step != null);
    assert(run_system_storage_retry_flow_step != null);
    assert(run_system_process_driver_flow_step != null);
    assert(run_swarm_sim_runner_step != null);

    return .{
        .run_replay_roundtrip = run_replay_roundtrip_step.?,
        .run_bench_smoke = run_bench_smoke_step.?,
        .run_bench_baseline_compare = run_bench_baseline_compare_step.?,
        .run_fuzz_seeded_runner = run_fuzz_seeded_runner_step.?,
        .run_sim_timer_mailbox = run_sim_timer_mailbox_step.?,
        .run_system_storage_retry_flow = run_system_storage_retry_flow_step.?,
        .run_system_process_driver_flow = run_system_process_driver_flow_step.?,
        .run_swarm_sim_runner = run_swarm_sim_runner_step.?,
    };
}

fn addSmokeStep(
    b: *std.Build,
    test_steps: TestSteps,
    example_steps: ExampleSteps,
) void {
    const smoke_step = b.step("smoke", "Run package smoke validation");

    smoke_step.dependOn(test_steps.run_integration_tests);
    smoke_step.dependOn(example_steps.run_replay_roundtrip);
    smoke_step.dependOn(example_steps.run_bench_smoke);
    smoke_step.dependOn(example_steps.run_bench_baseline_compare);
    smoke_step.dependOn(example_steps.run_fuzz_seeded_runner);
    smoke_step.dependOn(example_steps.run_sim_timer_mailbox);
    smoke_step.dependOn(example_steps.run_system_storage_retry_flow);
    smoke_step.dependOn(example_steps.run_system_process_driver_flow);
    smoke_step.dependOn(example_steps.run_swarm_sim_runner);
}

const BenchmarkStepOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    single_threaded: bool,
    enable_os_backends: bool,
    enable_tracing: bool,
};

fn addBenchmarkStep(b: *std.Build, options: BenchmarkStepOptions) void {
    const scheduling_dep = b.dependency("static_scheduling", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });

    const benchmarks_step = b.step("bench", "Run package benchmarks");
    const benchmarks = [_]ExampleSpec{
        .{
            .name = "static_testing_bench_stats",
            .path = "benchmarks/stats.zig",
        },
        .{
            .name = "static_testing_bench_timer_queue",
            .path = "benchmarks/timer_queue.zig",
        },
        .{
            .name = "static_testing_bench_replay_artifact",
            .path = "benchmarks/replay_artifact.zig",
        },
        .{
            .name = "static_testing_bench_scheduler",
            .path = "benchmarks/scheduler.zig",
        },
    };

    for (benchmarks) |benchmark| {
        const root_module = b.createModule(.{
            .root_source_file = b.path(benchmark.path),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "static_testing", .module = options.module },
                .{ .name = "static_scheduling", .module = scheduling_dep.module("static_scheduling") },
            },
        });
        const exe = b.addExecutable(.{
            .name = benchmark.name,
            .root_module = root_module,
        });
        const run_benchmark = b.addRunArtifact(exe);
        benchmarks_step.dependOn(&run_benchmark.step);
    }
}
