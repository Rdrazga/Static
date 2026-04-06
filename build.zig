// Build strategy: workspace-only. All packages are built together from
// this root. Individual package builds (cd packages/static_foo && zig build)
// are not supported because the supported dependency wiring is defined at the
// workspace root, where sibling package imports and shared build options stay
// consistent across validation steps.
const std = @import("std");

const Options = struct {
    single_threaded: bool,
    enable_os_backends: bool,
    enable_tracing: bool,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts: Options = .{
        .single_threaded = b.option(
            bool,
            "single_threaded",
            "Disable thread-based behavior",
        ) orelse false,
        .enable_os_backends = b.option(
            bool,
            "enable_os_backends",
            "Enable OS-specific backends",
        ) orelse false,
        .enable_tracing = b.option(
            bool,
            "enable_tracing",
            "Enable tracing/instrumentation hooks",
        ) orelse false,
    };

    const build_options = b.addOptions();
    build_options.addOption(bool, "single_threaded", opts.single_threaded);
    build_options.addOption(bool, "enable_os_backends", opts.enable_os_backends);
    build_options.addOption(bool, "enable_tracing", opts.enable_tracing);
    build_options.addOption([]const u8, "static_package", "static_workspace");
    const build_options_mod = build_options.createModule();
    const mods = createWorkspaceModules(b, target, optimize, build_options_mod, true);
    const bench_mods = createWorkspaceModules(b, target, .ReleaseFast, build_options_mod, false);

    const docs_lint_step = addDocsLintStep(b);
    const tests_step = addAllTestsStep(b, mods);
    const check_step = addAllChecksStep(b, mods);
    const harness_step = addHarnessStep(b, target, optimize, mods);
    const examples_step = addAllExamplesStep(b, target, optimize, mods);
    // Benchmark step: benchmarks always compile at ReleaseFast because the
    // measurement is meaningless in Debug mode (assertions dominate runtime).
    const bench_step = addBenchStep(b, target, bench_mods);
    // test-release step: runs all unit tests under ReleaseSafe to catch
    // optimisation-mode differences (wrapping arithmetic, assert stripping, etc.).
    const test_release_step = addTestReleaseStep(b, mods);

    const ci_step = b.step("ci", "Run docs lint, tests, harness smoke, and build examples");
    ci_step.dependOn(docs_lint_step);
    ci_step.dependOn(tests_step);
    ci_step.dependOn(harness_step);
    ci_step.dependOn(examples_step);

    _ = bench_step;
    _ = test_release_step;
    _ = check_step;
}

fn addBenchStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mods: Modules,
) *std.Build.Step {
    const step = b.step("bench", "Build and run non-gating benchmark review workloads (ReleaseFast)");

    // Benchmark executables always compile at ReleaseFast. Measuring in Debug
    // mode is misleading: assertion overhead dominates and numbers cannot be
    // compared against production builds.
    const bench_optimize: std.builtin.OptimizeMode = .ReleaseFast;

    // Each entry describes one benchmark executable.
    const benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
        import_name: []const u8,
        import_mod: *std.Build.Module,
        extra_import_name: ?[]const u8 = null,
        extra_import_mod: ?*std.Build.Module = null,
    }{
        .{
            .name = "spsc_throughput",
            .src = "packages/static_queues/benchmarks/spsc_throughput.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "ring_buffer_throughput",
            .src = "packages/static_queues/benchmarks/ring_buffer_throughput.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "disruptor_throughput",
            .src = "packages/static_queues/benchmarks/disruptor_throughput.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "pool_alloc_free",
            .src = "packages/static_memory/benchmarks/pool_alloc_free.zig",
            .import_name = "static_memory",
            .import_mod = mods.static_memory,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "bvh_query_baselines",
            .src = "packages/static_spatial/benchmarks/bvh_query_baselines.zig",
            .import_name = "static_spatial",
            .import_mod = mods.static_spatial,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "flat_hash_map_lookup_insert_baselines",
            .src = "packages/static_collections/benchmarks/flat_hash_map_lookup_insert_baselines.zig",
            .import_name = "static_collections",
            .import_mod = mods.static_collections,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "query_iteration_baselines",
            .src = "packages/static_ecs/benchmarks/query_iteration_baselines.zig",
            .import_name = "static_ecs",
            .import_mod = mods.static_ecs,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "structural_churn_baselines",
            .src = "packages/static_ecs/benchmarks/structural_churn_baselines.zig",
            .import_name = "static_ecs",
            .import_mod = mods.static_ecs,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "command_buffer_staged_apply_baselines",
            .src = "packages/static_ecs/benchmarks/command_buffer_apply_baselines.zig",
            .import_name = "static_ecs",
            .import_mod = mods.static_ecs,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "command_buffer_phase_baselines",
            .src = "packages/static_ecs/benchmarks/command_buffer_phase_baselines.zig",
            .import_name = "static_ecs",
            .import_mod = mods.static_ecs,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "micro_hotpaths_baselines",
            .src = "packages/static_ecs/benchmarks/micro_hotpaths_baselines.zig",
            .import_name = "static_ecs",
            .import_mod = mods.static_ecs,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "query_scale_baselines",
            .src = "packages/static_ecs/benchmarks/query_scale_baselines.zig",
            .import_name = "static_ecs",
            .import_mod = mods.static_ecs,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
        .{
            .name = "frame_pass_baselines",
            .src = "packages/static_ecs/benchmarks/frame_pass_baselines.zig",
            .import_name = "static_ecs",
            .import_mod = mods.static_ecs,
            .extra_import_name = "static_testing",
            .extra_import_mod = mods.static_testing,
        },
    };

    for (benchmarks) |bm| {
        const Import = std.Build.Module.Import;
        var imports_buffer: [2]Import = undefined;
        imports_buffer[0] = .{ .name = bm.import_name, .module = bm.import_mod };
        var imports_len: usize = 1;
        if (bm.extra_import_name) |extra_import_name| {
            imports_buffer[1] = .{ .name = extra_import_name, .module = bm.extra_import_mod.? };
            imports_len = 2;
        }
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = imports_buffer[0..imports_len],
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
        const single_step = b.step(bm.name, b.fmt("Run benchmark {s}", .{bm.name}));
        single_step.dependOn(&run.step);
    }

    const static_io_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "buffer_pool_checkout_return",
            .src = "packages/static_io/benchmarks/buffer_pool_checkout_return.zig",
        },
        .{
            .name = "buffer_pool_bounded_churn",
            .src = "packages/static_io/benchmarks/buffer_pool_bounded_churn.zig",
        },
        .{
            .name = "runtime_submit_complete_roundtrip",
            .src = "packages/static_io/benchmarks/runtime_submit_complete_roundtrip.zig",
        },
        .{
            .name = "runtime_timeout_retry_roundtrip",
            .src = "packages/static_io/benchmarks/runtime_timeout_retry_roundtrip.zig",
        },
    };

    for (static_io_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_io", .module = mods.static_io },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_bits_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "byte_cursor_u32le_roundtrip",
            .src = "packages/static_bits/benchmarks/byte_cursor_u32le_roundtrip.zig",
        },
        .{
            .name = "varint_cursor_roundtrip",
            .src = "packages/static_bits/benchmarks/varint_cursor_roundtrip.zig",
        },
    };

    for (static_bits_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_bits", .module = mods.static_bits },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_serial_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "checksum_framed_payload_roundtrip",
            .src = "packages/static_serial/benchmarks/checksum_framed_payload_roundtrip.zig",
        },
        .{
            .name = "mixed_endian_message_roundtrip",
            .src = "packages/static_serial/benchmarks/mixed_endian_message_roundtrip.zig",
        },
    };

    for (static_serial_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_serial", .module = mods.static_serial },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_net_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "frame_encode_decode_throughput",
            .src = "packages/static_net/benchmarks/frame_encode_decode_throughput.zig",
        },
        .{
            .name = "frame_checksum_incremental_roundtrip",
            .src = "packages/static_net/benchmarks/frame_checksum_incremental_roundtrip.zig",
        },
    };

    for (static_net_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_net", .module = mods.static_net },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_net_native_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "endpoint_sockaddr_roundtrip",
            .src = "packages/static_net_native/benchmarks/endpoint_sockaddr_roundtrip.zig",
        },
    };

    for (static_net_native_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_net_native", .module = mods.static_net_native },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_string_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "text_validation_normalize",
            .src = "packages/static_string/benchmarks/text_validation_normalize.zig",
        },
        .{
            .name = "intern_pool_duplicate_lookup",
            .src = "packages/static_string/benchmarks/intern_pool_duplicate_lookup.zig",
        },
    };

    for (static_string_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_string", .module = mods.static_string },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_rng_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "static_rng_generator_next_throughput",
            .src = "packages/static_rng/benchmarks/generator_next_throughput.zig",
        },
        .{
            .name = "static_rng_distribution_shuffle_hotpaths",
            .src = "packages/static_rng/benchmarks/distribution_shuffle_hotpaths.zig",
        },
    };

    for (static_rng_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_rng", .module = mods.static_rng },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_hash_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "static_hash_byte_hash_baselines",
            .src = "packages/static_hash/benchmarks/byte_hash_baselines.zig",
        },
        .{
            .name = "static_hash_combine_baselines",
            .src = "packages/static_hash/benchmarks/combine_baselines.zig",
        },
        .{
            .name = "static_hash_fingerprint_baselines",
            .src = "packages/static_hash/benchmarks/fingerprint_baselines.zig",
        },
        .{
            .name = "static_hash_quality_samples",
            .src = "packages/static_hash/benchmarks/quality_samples.zig",
        },
        .{
            .name = "static_hash_structural_hash_baselines",
            .src = "packages/static_hash/benchmarks/structural_hash_baselines.zig",
        },
    };

    for (static_hash_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_hash", .module = mods.static_hash },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_sync_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "static_sync_fast_paths",
            .src = "packages/static_sync/benchmarks/fast_paths.zig",
        },
        .{
            .name = "static_sync_contention",
            .src = "packages/static_sync/benchmarks/contention_baselines.zig",
        },
    };

    for (static_sync_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_sync", .module = mods.static_sync },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    const static_scheduling_benchmarks = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{
            .name = "static_scheduling_planning_baselines",
            .src = "packages/static_scheduling/benchmarks/planning_baselines.zig",
        },
    };

    for (static_scheduling_benchmarks) |bm| {
        const exe = b.addExecutable(.{
            .name = bm.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bm.src),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "static_scheduling", .module = mods.static_scheduling },
                    .{ .name = "static_testing", .module = mods.static_testing },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        step.dependOn(&run.step);
    }

    return step;
}

fn addTestReleaseStep(b: *std.Build, mods: Modules) *std.Build.Step {
    // Run the same unit tests as `zig build test` but with ReleaseSafe. This
    // catches bugs that only surface under optimisation: wrapping arithmetic,
    // inlining revealing hidden aliasing, and code paths gated on builtin.mode.
    // Safety checks (bounds, overflow) are preserved by ReleaseSafe, unlike
    // ReleaseFast which strips them.
    const step = b.step("test-release", "Run all unit tests in ReleaseSafe mode");

    const release_modules = [_]struct { mod: *std.Build.Module }{
        .{ .mod = mods.static_core },
        .{ .mod = mods.static_bits },
        .{ .mod = mods.static_hash },
        .{ .mod = mods.static_memory },
        .{ .mod = mods.static_sync },
        .{ .mod = mods.static_collections },
        .{ .mod = mods.static_serial },
        .{ .mod = mods.static_net },
        .{ .mod = mods.static_net_native },
        .{ .mod = mods.static_queues },
        .{ .mod = mods.static_io },
        .{ .mod = mods.static_scheduling },
        .{ .mod = mods.static_profile },
        .{ .mod = mods.static_simd },
        .{ .mod = mods.static_meta },
        .{ .mod = mods.static_rng },
        .{ .mod = mods.static_string },
        .{ .mod = mods.static_spatial },
        .{ .mod = mods.static_math },
        .{ .mod = mods.static_testing },
    };

    for (release_modules) |rm| {
        // Build a fresh test executable from the same module but force
        // ReleaseSafe regardless of the -Doptimize flag provided by the user.
        const release_mod = b.createModule(.{
            .root_source_file = rm.mod.root_source_file.?,
            .target = rm.mod.resolved_target.?,
            .optimize = .ReleaseSafe,
        });
        // Propagate all imports from the original debug module so the
        // ReleaseSafe tests have access to the same dependencies.
        var import_iter = rm.mod.import_table.iterator();
        while (import_iter.next()) |entry| {
            release_mod.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
        const test_exe = b.addTest(.{ .root_module = release_mod });
        const run = b.addRunArtifact(test_exe);
        step.dependOn(&run.step);
    }

    return step;
}

fn addDocsLintStep(b: *std.Build) *std.Build.Step {
    const docs_lint = b.addSystemCommand(&.{ "zig", "run", "scripts/docs_lint.zig" });
    docs_lint.setCwd(b.path("."));

    const step = b.step("docs-lint", "Run docs lints");
    step.dependOn(&docs_lint.step);
    return step;
}

fn addHarnessStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mods: Modules,
) *std.Build.Step {
    const step = b.step("harness", "Run deterministic success-only harness smoke validation");

    const driver_echo_exe = b.addExecutable(.{
        .name = "workspace_static_testing_driver_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/static_testing/tests/support/driver_echo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "static_testing", .module = mods.static_testing },
            },
        }),
    });

    const integration_options = b.addOptions();
    integration_options.addOptionPath("driver_echo_path", driver_echo_exe.getEmittedBin());

    const integration_module = b.createModule(.{
        .root_source_file = b.path("packages/static_testing/tests/integration/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    integration_module.addOptions(
        "static_testing_integration_options",
        integration_options,
    );

    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(&driver_echo_exe.step);
    step.dependOn(&run_integration_tests.step);

    const static_testing_example_options = b.addOptions();
    static_testing_example_options.addOptionPath("driver_echo_path", driver_echo_exe.getEmittedBin());
    const static_testing_example_options_mod = static_testing_example_options.createModule();

    const harness_examples = [_]struct {
        path: []const u8,
        name: []const u8,
        needs_driver_echo: bool = false,
    }{
        .{
            .path = "packages/static_testing/examples/replay_roundtrip.zig",
            .name = "workspace_static_testing_replay_roundtrip",
        },
        .{
            .path = "packages/static_testing/examples/bench_smoke.zig",
            .name = "workspace_static_testing_bench_smoke",
        },
        .{
            .path = "packages/static_testing/examples/bench_baseline_compare.zig",
            .name = "workspace_static_testing_bench_baseline_compare",
        },
        .{
            .path = "packages/static_testing/examples/fuzz_seeded_runner.zig",
            .name = "workspace_static_testing_fuzz_seeded_runner",
        },
        .{
            .path = "packages/static_testing/examples/sim_timer_mailbox.zig",
            .name = "workspace_static_testing_sim_timer_mailbox",
        },
        .{
            .path = "packages/static_testing/examples/repair_liveness_basic.zig",
            .name = "workspace_static_testing_repair_liveness_basic",
        },
        .{
            .path = "packages/static_testing/examples/sim_storage_durability.zig",
            .name = "workspace_static_testing_sim_storage_durability",
        },
        .{
            .path = "packages/static_testing/examples/system_storage_retry_flow.zig",
            .name = "workspace_static_testing_system_storage_retry_flow",
        },
        .{
            .path = "packages/static_testing/examples/system_process_driver_flow.zig",
            .name = "workspace_static_testing_system_process_driver_flow",
            .needs_driver_echo = true,
        },
    };

    // Keep retained-failure demo examples on the `examples` surface so the
    // supported `harness` command remains a success-only smoke validation path.
    for (harness_examples) |example| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_module = if (example.needs_driver_echo)
                b.createModule(.{
                    .root_source_file = b.path(example.path),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "static_testing", .module = mods.static_testing },
                        .{ .name = "static_testing_example_options", .module = static_testing_example_options_mod },
                    },
                })
            else
                b.createModule(.{
                    .root_source_file = b.path(example.path),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "static_testing", .module = mods.static_testing },
                    },
                }),
        });
        const run_example = b.addRunArtifact(example_exe);
        if (example.needs_driver_echo) {
            run_example.step.dependOn(&driver_echo_exe.step);
        }
        step.dependOn(&run_example.step);
    }

    return step;
}

const Modules = struct {
    static_core: *std.Build.Module,
    static_bits: *std.Build.Module,
    static_hash: *std.Build.Module,
    static_memory: *std.Build.Module,
    static_sync: *std.Build.Module,
    static_collections: *std.Build.Module,
    static_ecs: *std.Build.Module,
    static_serial: *std.Build.Module,
    static_net: *std.Build.Module,
    static_net_native: *std.Build.Module,
    static_queues: *std.Build.Module,
    static_io: *std.Build.Module,
    static_scheduling: *std.Build.Module,
    static_profile: *std.Build.Module,
    static_simd: *std.Build.Module,
    static_meta: *std.Build.Module,
    static_rng: *std.Build.Module,
    static_string: *std.Build.Module,
    static_spatial: *std.Build.Module,
    static_math: *std.Build.Module,
    static_testing: *std.Build.Module,
};

fn createWorkspaceModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
    register_named_modules: bool,
) Modules {
    const static_core_mod = makeWorkspaceModule(b, "static_core", .{
        .root_source_file = b.path("packages/static_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
        },
    }, register_named_modules);

    const static_bits_mod = makeWorkspaceModule(b, "static_bits", .{
        .root_source_file = b.path("packages/static_bits/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
        },
    }, register_named_modules);

    const static_hash_mod = makeWorkspaceModule(b, "static_hash", .{
        .root_source_file = b.path("packages/static_hash/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
        },
    }, register_named_modules);

    const static_sync_mod = makeWorkspaceModule(b, "static_sync", .{
        .root_source_file = b.path("packages/static_sync/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
        },
    }, register_named_modules);

    const static_memory_mod = makeWorkspaceModule(b, "static_memory", .{
        .root_source_file = b.path("packages/static_memory/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_sync", .module = static_sync_mod },
        },
    }, register_named_modules);

    const static_collections_mod = makeWorkspaceModule(b, "static_collections", .{
        .root_source_file = b.path("packages/static_collections/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_memory", .module = static_memory_mod },
            .{ .name = "static_hash", .module = static_hash_mod },
        },
    }, register_named_modules);

    const static_ecs_mod = makeWorkspaceModule(b, "static_ecs", .{
        .root_source_file = b.path("packages/static_ecs/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_memory", .module = static_memory_mod },
            .{ .name = "static_collections", .module = static_collections_mod },
            .{ .name = "static_hash", .module = static_hash_mod },
        },
    }, register_named_modules);

    const static_serial_mod = makeWorkspaceModule(b, "static_serial", .{
        .root_source_file = b.path("packages/static_serial/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_bits", .module = static_bits_mod },
            .{ .name = "static_hash", .module = static_hash_mod },
        },
    }, register_named_modules);

    const static_net_mod = makeWorkspaceModule(b, "static_net", .{
        .root_source_file = b.path("packages/static_net/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_bits", .module = static_bits_mod },
            .{ .name = "static_serial", .module = static_serial_mod },
        },
    }, register_named_modules);

    const static_net_native_mod = makeWorkspaceModule(b, "static_net_native", .{
        .root_source_file = b.path("packages/static_net_native/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_net", .module = static_net_mod },
        },
    }, register_named_modules);

    const static_queues_mod = makeWorkspaceModule(b, "static_queues", .{
        .root_source_file = b.path("packages/static_queues/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_memory", .module = static_memory_mod },
            .{ .name = "static_collections", .module = static_collections_mod },
            .{ .name = "static_sync", .module = static_sync_mod },
        },
    }, register_named_modules);

    const static_io_mod = makeWorkspaceModule(b, "static_io", .{
        .root_source_file = b.path("packages/static_io/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_memory", .module = static_memory_mod },
            .{ .name = "static_queues", .module = static_queues_mod },
            .{ .name = "static_collections", .module = static_collections_mod },
            .{ .name = "static_net", .module = static_net_mod },
            .{ .name = "static_net_native", .module = static_net_native_mod },
            .{ .name = "static_sync", .module = static_sync_mod },
        },
    }, register_named_modules);

    const static_scheduling_mod = makeWorkspaceModule(b, "static_scheduling", .{
        .root_source_file = b.path("packages/static_scheduling/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_sync", .module = static_sync_mod },
            .{ .name = "static_collections", .module = static_collections_mod },
        },
    }, register_named_modules);

    const static_profile_mod = makeWorkspaceModule(b, "static_profile", .{
        .root_source_file = b.path("packages/static_profile/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
        },
    }, register_named_modules);

    const static_simd_mod = makeWorkspaceModule(b, "static_simd", .{
        .root_source_file = b.path("packages/static_simd/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
        },
    }, register_named_modules);

    const static_meta_mod = makeWorkspaceModule(b, "static_meta", .{
        .root_source_file = b.path("packages/static_meta/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_hash", .module = static_hash_mod },
        },
    }, register_named_modules);

    const static_rng_mod = makeWorkspaceModule(b, "static_rng", .{
        .root_source_file = b.path("packages/static_rng/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
        },
    }, register_named_modules);

    const static_string_mod = makeWorkspaceModule(b, "static_string", .{
        .root_source_file = b.path("packages/static_string/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_hash", .module = static_hash_mod },
        },
    }, register_named_modules);

    const static_spatial_mod = makeWorkspaceModule(b, "static_spatial", .{
        .root_source_file = b.path("packages/static_spatial/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
        },
    }, register_named_modules);

    const static_math_mod = makeWorkspaceModule(b, "static_math", .{
        .root_source_file = b.path("packages/static_math/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
        },
    }, register_named_modules);

    const static_testing_mod = makeWorkspaceModule(b, "static_testing", .{
        .root_source_file = b.path("packages/static_testing/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = build_options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_rng", .module = static_rng_mod },
            .{ .name = "static_profile", .module = static_profile_mod },
            .{ .name = "static_queues", .module = static_queues_mod },
            .{ .name = "static_scheduling", .module = static_scheduling_mod },
            .{ .name = "static_bits", .module = static_bits_mod },
            .{ .name = "static_serial", .module = static_serial_mod },
        },
    }, register_named_modules);

    return .{
        .static_core = static_core_mod,
        .static_bits = static_bits_mod,
        .static_hash = static_hash_mod,
        .static_memory = static_memory_mod,
        .static_sync = static_sync_mod,
        .static_collections = static_collections_mod,
        .static_ecs = static_ecs_mod,
        .static_serial = static_serial_mod,
        .static_net = static_net_mod,
        .static_net_native = static_net_native_mod,
        .static_queues = static_queues_mod,
        .static_io = static_io_mod,
        .static_scheduling = static_scheduling_mod,
        .static_profile = static_profile_mod,
        .static_simd = static_simd_mod,
        .static_meta = static_meta_mod,
        .static_rng = static_rng_mod,
        .static_string = static_string_mod,
        .static_spatial = static_spatial_mod,
        .static_math = static_math_mod,
        .static_testing = static_testing_mod,
    };
}

fn makeWorkspaceModule(
    b: *std.Build,
    name: []const u8,
    options: std.Build.Module.CreateOptions,
    register_named_module: bool,
) *std.Build.Module {
    if (register_named_module) return b.addModule(name, options);
    return b.createModule(options);
}

fn addAllTestsStep(b: *std.Build, mods: Modules) *std.Build.Step {
    const step = b.step("test", "Run all unit tests");

    const tests = [_]struct { mod: *std.Build.Module }{
        .{ .mod = mods.static_core },
        .{ .mod = mods.static_bits },
        .{ .mod = mods.static_hash },
        .{ .mod = mods.static_memory },
        .{ .mod = mods.static_sync },
        .{ .mod = mods.static_collections },
        .{ .mod = mods.static_ecs },
        .{ .mod = mods.static_serial },
        .{ .mod = mods.static_net },
        .{ .mod = mods.static_net_native },
        .{ .mod = mods.static_queues },
        .{ .mod = mods.static_io },
        .{ .mod = mods.static_scheduling },
        .{ .mod = mods.static_profile },
        .{ .mod = mods.static_simd },
        .{ .mod = mods.static_meta },
        .{ .mod = mods.static_rng },
        .{ .mod = mods.static_string },
        .{ .mod = mods.static_spatial },
        .{ .mod = mods.static_math },
        .{ .mod = mods.static_testing },
    };

    for (tests) |t| {
        const test_exe = b.addTest(.{ .root_module = t.mod });
        const run = b.addRunArtifact(test_exe);
        step.dependOn(&run.step);
    }

    const static_testing_driver_echo = b.addExecutable(.{
        .name = "static_testing_driver_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/static_testing/tests/support/driver_echo.zig"),
            .target = mods.static_core.resolved_target.?,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "static_testing", .module = mods.static_testing },
            },
        }),
    });
    const static_testing_integration_options = b.addOptions();
    static_testing_integration_options.addOptionPath(
        "driver_echo_path",
        static_testing_driver_echo.getEmittedBin(),
    );
    const static_testing_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_testing/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    static_testing_integration_mod.addOptions(
        "static_testing_integration_options",
        static_testing_integration_options,
    );
    const static_testing_integration_exe = b.addTest(.{ .root_module = static_testing_integration_mod });
    const run_static_testing_integration = b.addRunArtifact(static_testing_integration_exe);
    run_static_testing_integration.step.dependOn(&static_testing_driver_echo.step);
    step.dependOn(&run_static_testing_integration.step);

    const static_core_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_core/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_core", .module = mods.static_core },
        },
    });
    const static_core_integration_exe = b.addTest(.{ .root_module = static_core_integration_mod });
    const run_static_core_integration = b.addRunArtifact(static_core_integration_exe);
    step.dependOn(&run_static_core_integration.step);

    const static_hash_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_hash/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_hash", .module = mods.static_hash },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_hash_integration_exe = b.addTest(.{ .root_module = static_hash_integration_mod });
    const run_static_hash_integration = b.addRunArtifact(static_hash_integration_exe);
    step.dependOn(&run_static_hash_integration.step);

    const static_bits_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_bits/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_bits", .module = mods.static_bits },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_bits_integration_exe = b.addTest(.{ .root_module = static_bits_integration_mod });
    const run_static_bits_integration = b.addRunArtifact(static_bits_integration_exe);
    step.dependOn(&run_static_bits_integration.step);

    const static_serial_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_serial/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_serial", .module = mods.static_serial },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_serial_integration_exe = b.addTest(.{ .root_module = static_serial_integration_mod });
    const run_static_serial_integration = b.addRunArtifact(static_serial_integration_exe);
    step.dependOn(&run_static_serial_integration.step);

    const static_net_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_net/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_net", .module = mods.static_net },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_net_integration_exe = b.addTest(.{ .root_module = static_net_integration_mod });
    const run_static_net_integration = b.addRunArtifact(static_net_integration_exe);
    step.dependOn(&run_static_net_integration.step);

    const static_net_native_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_net_native/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_net_native", .module = mods.static_net_native },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_net_native_integration_exe = b.addTest(.{ .root_module = static_net_native_integration_mod });
    const run_static_net_native_integration = b.addRunArtifact(static_net_native_integration_exe);
    step.dependOn(&run_static_net_native_integration.step);

    const static_string_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_string/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_string", .module = mods.static_string },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_string_integration_exe = b.addTest(.{ .root_module = static_string_integration_mod });
    const run_static_string_integration = b.addRunArtifact(static_string_integration_exe);
    step.dependOn(&run_static_string_integration.step);

    const static_rng_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_rng/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_rng", .module = mods.static_rng },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_rng_integration_exe = b.addTest(.{ .root_module = static_rng_integration_mod });
    const run_static_rng_integration = b.addRunArtifact(static_rng_integration_exe);
    step.dependOn(&run_static_rng_integration.step);

    const static_profile_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_profile/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_profile", .module = mods.static_profile },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_profile_integration_exe = b.addTest(.{ .root_module = static_profile_integration_mod });
    const run_static_profile_integration = b.addRunArtifact(static_profile_integration_exe);
    step.dependOn(&run_static_profile_integration.step);

    const static_meta_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_meta/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_meta", .module = mods.static_meta },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_meta_integration_exe = b.addTest(.{ .root_module = static_meta_integration_mod });
    const run_static_meta_integration = b.addRunArtifact(static_meta_integration_exe);
    step.dependOn(&run_static_meta_integration.step);

    const static_memory_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_memory/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_memory", .module = mods.static_memory },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_memory_integration_exe = b.addTest(.{ .root_module = static_memory_integration_mod });
    const run_static_memory_integration = b.addRunArtifact(static_memory_integration_exe);
    step.dependOn(&run_static_memory_integration.step);

    const static_ecs_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_ecs/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_ecs", .module = mods.static_ecs },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_ecs_integration_exe = b.addTest(.{ .root_module = static_ecs_integration_mod });
    const run_static_ecs_integration = b.addRunArtifact(static_ecs_integration_exe);
    step.dependOn(&run_static_ecs_integration.step);

    const static_queues_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_queues/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_queues", .module = mods.static_queues },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_queues_integration_exe = b.addTest(.{ .root_module = static_queues_integration_mod });
    const run_static_queues_integration = b.addRunArtifact(static_queues_integration_exe);
    step.dependOn(&run_static_queues_integration.step);

    const static_collections_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_collections/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_collections", .module = mods.static_collections },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_collections_integration_exe = b.addTest(.{ .root_module = static_collections_integration_mod });
    const run_static_collections_integration = b.addRunArtifact(static_collections_integration_exe);
    step.dependOn(&run_static_collections_integration.step);

    const static_sync_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_sync/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_sync", .module = mods.static_sync },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_sync_integration_exe = b.addTest(.{ .root_module = static_sync_integration_mod });
    const run_static_sync_integration = b.addRunArtifact(static_sync_integration_exe);
    step.dependOn(&run_static_sync_integration.step);

    const static_scheduling_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_scheduling/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_scheduling", .module = mods.static_scheduling },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_scheduling_integration_exe = b.addTest(.{ .root_module = static_scheduling_integration_mod });
    const run_static_scheduling_integration = b.addRunArtifact(static_scheduling_integration_exe);
    step.dependOn(&run_static_scheduling_integration.step);

    const static_math_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_math/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_math", .module = mods.static_math },
        },
    });
    const static_math_integration_exe = b.addTest(.{ .root_module = static_math_integration_mod });
    const run_static_math_integration = b.addRunArtifact(static_math_integration_exe);
    step.dependOn(&run_static_math_integration.step);

    const static_simd_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_simd/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_simd", .module = mods.static_simd },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_simd_integration_exe = b.addTest(.{ .root_module = static_simd_integration_mod });
    const run_static_simd_integration = b.addRunArtifact(static_simd_integration_exe);
    step.dependOn(&run_static_simd_integration.step);

    const static_spatial_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_spatial/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_spatial", .module = mods.static_spatial },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_spatial_integration_exe = b.addTest(.{ .root_module = static_spatial_integration_mod });
    const run_static_spatial_integration = b.addRunArtifact(static_spatial_integration_exe);
    step.dependOn(&run_static_spatial_integration.step);

    const static_io_driver_runtime_echo = b.addExecutable(.{
        .name = "static_io_driver_runtime_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/static_io/tests/support/driver_runtime_echo.zig"),
            .target = mods.static_core.resolved_target.?,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "static_io", .module = mods.static_io },
                .{ .name = "static_testing", .module = mods.static_testing },
            },
        }),
    });
    const static_io_integration_options = b.addOptions();
    static_io_integration_options.addOptionPath(
        "driver_runtime_echo_path",
        static_io_driver_runtime_echo.getEmittedBin(),
    );
    const static_io_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_io/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_io", .module = mods.static_io },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    static_io_integration_mod.addOptions(
        "static_io_integration_options",
        static_io_integration_options,
    );
    const static_io_integration_exe = b.addTest(.{ .root_module = static_io_integration_mod });
    const run_static_io_integration = b.addRunArtifact(static_io_integration_exe);
    run_static_io_integration.step.dependOn(&static_io_driver_runtime_echo.step);
    step.dependOn(&run_static_io_integration.step);

    return step;
}

fn addAllChecksStep(b: *std.Build, mods: Modules) *std.Build.Step {
    const step = b.step("check", "Compile all tests (no run)");

    const tests = [_]struct { mod: *std.Build.Module }{
        .{ .mod = mods.static_core },
        .{ .mod = mods.static_bits },
        .{ .mod = mods.static_hash },
        .{ .mod = mods.static_memory },
        .{ .mod = mods.static_sync },
        .{ .mod = mods.static_collections },
        .{ .mod = mods.static_ecs },
        .{ .mod = mods.static_serial },
        .{ .mod = mods.static_net },
        .{ .mod = mods.static_net_native },
        .{ .mod = mods.static_queues },
        .{ .mod = mods.static_io },
        .{ .mod = mods.static_scheduling },
        .{ .mod = mods.static_profile },
        .{ .mod = mods.static_simd },
        .{ .mod = mods.static_meta },
        .{ .mod = mods.static_rng },
        .{ .mod = mods.static_string },
        .{ .mod = mods.static_spatial },
        .{ .mod = mods.static_math },
        .{ .mod = mods.static_testing },
    };

    for (tests) |t| {
        const test_exe = b.addTest(.{ .root_module = t.mod });
        step.dependOn(&test_exe.step);
    }

    const static_testing_driver_echo = b.addExecutable(.{
        .name = "static_testing_driver_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/static_testing/tests/support/driver_echo.zig"),
            .target = mods.static_core.resolved_target.?,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "static_testing", .module = mods.static_testing },
            },
        }),
    });
    const static_testing_integration_options = b.addOptions();
    static_testing_integration_options.addOptionPath(
        "driver_echo_path",
        static_testing_driver_echo.getEmittedBin(),
    );
    const static_testing_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_testing/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    static_testing_integration_mod.addOptions(
        "static_testing_integration_options",
        static_testing_integration_options,
    );
    const static_testing_integration_exe = b.addTest(.{ .root_module = static_testing_integration_mod });
    step.dependOn(&static_testing_driver_echo.step);
    step.dependOn(&static_testing_integration_exe.step);

    const static_core_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_core/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_core", .module = mods.static_core },
        },
    });
    const static_core_integration_exe = b.addTest(.{ .root_module = static_core_integration_mod });
    step.dependOn(&static_core_integration_exe.step);

    const static_hash_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_hash/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_hash", .module = mods.static_hash },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_hash_integration_exe = b.addTest(.{ .root_module = static_hash_integration_mod });
    step.dependOn(&static_hash_integration_exe.step);

    const static_bits_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_bits/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_bits", .module = mods.static_bits },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_bits_integration_exe = b.addTest(.{ .root_module = static_bits_integration_mod });
    step.dependOn(&static_bits_integration_exe.step);

    const static_serial_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_serial/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_serial", .module = mods.static_serial },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_serial_integration_exe = b.addTest(.{ .root_module = static_serial_integration_mod });
    step.dependOn(&static_serial_integration_exe.step);

    const static_net_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_net/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_net", .module = mods.static_net },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_net_integration_exe = b.addTest(.{ .root_module = static_net_integration_mod });
    step.dependOn(&static_net_integration_exe.step);

    const static_net_native_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_net_native/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_net_native", .module = mods.static_net_native },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_net_native_integration_exe = b.addTest(.{ .root_module = static_net_native_integration_mod });
    step.dependOn(&static_net_native_integration_exe.step);

    const static_string_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_string/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_string", .module = mods.static_string },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_string_integration_exe = b.addTest(.{ .root_module = static_string_integration_mod });
    step.dependOn(&static_string_integration_exe.step);

    const static_rng_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_rng/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_rng", .module = mods.static_rng },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_rng_integration_exe = b.addTest(.{ .root_module = static_rng_integration_mod });
    step.dependOn(&static_rng_integration_exe.step);

    const static_profile_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_profile/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_profile", .module = mods.static_profile },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_profile_integration_exe = b.addTest(.{ .root_module = static_profile_integration_mod });
    step.dependOn(&static_profile_integration_exe.step);

    const static_meta_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_meta/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_meta", .module = mods.static_meta },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_meta_integration_exe = b.addTest(.{ .root_module = static_meta_integration_mod });
    step.dependOn(&static_meta_integration_exe.step);

    const static_memory_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_memory/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_memory", .module = mods.static_memory },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_memory_integration_exe = b.addTest(.{ .root_module = static_memory_integration_mod });
    step.dependOn(&static_memory_integration_exe.step);

    const static_ecs_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_ecs/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_ecs", .module = mods.static_ecs },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_ecs_integration_exe = b.addTest(.{ .root_module = static_ecs_integration_mod });
    step.dependOn(&static_ecs_integration_exe.step);

    const static_queues_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_queues/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_queues", .module = mods.static_queues },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_queues_integration_exe = b.addTest(.{ .root_module = static_queues_integration_mod });
    step.dependOn(&static_queues_integration_exe.step);

    const static_sync_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_sync/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_sync", .module = mods.static_sync },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_sync_integration_exe = b.addTest(.{ .root_module = static_sync_integration_mod });
    step.dependOn(&static_sync_integration_exe.step);

    const static_scheduling_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_scheduling/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_scheduling", .module = mods.static_scheduling },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_scheduling_integration_exe = b.addTest(.{ .root_module = static_scheduling_integration_mod });
    step.dependOn(&static_scheduling_integration_exe.step);

    const static_math_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_math/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_math", .module = mods.static_math },
        },
    });
    const static_math_integration_exe = b.addTest(.{ .root_module = static_math_integration_mod });
    step.dependOn(&static_math_integration_exe.step);

    const static_simd_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_simd/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_simd", .module = mods.static_simd },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_simd_integration_exe = b.addTest(.{ .root_module = static_simd_integration_mod });
    step.dependOn(&static_simd_integration_exe.step);

    const static_spatial_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_spatial/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_spatial", .module = mods.static_spatial },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    const static_spatial_integration_exe = b.addTest(.{ .root_module = static_spatial_integration_mod });
    step.dependOn(&static_spatial_integration_exe.step);

    const static_io_driver_runtime_echo = b.addExecutable(.{
        .name = "static_io_driver_runtime_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/static_io/tests/support/driver_runtime_echo.zig"),
            .target = mods.static_core.resolved_target.?,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "static_io", .module = mods.static_io },
                .{ .name = "static_testing", .module = mods.static_testing },
            },
        }),
    });
    const static_io_integration_options = b.addOptions();
    static_io_integration_options.addOptionPath(
        "driver_runtime_echo_path",
        static_io_driver_runtime_echo.getEmittedBin(),
    );
    const static_io_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/static_io/tests/integration/root.zig"),
        .target = mods.static_core.resolved_target.?,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "static_io", .module = mods.static_io },
            .{ .name = "static_testing", .module = mods.static_testing },
        },
    });
    static_io_integration_mod.addOptions(
        "static_io_integration_options",
        static_io_integration_options,
    );
    const static_io_integration_exe = b.addTest(.{ .root_module = static_io_integration_mod });
    step.dependOn(&static_io_driver_runtime_echo.step);
    step.dependOn(&static_io_integration_exe.step);

    return step;
}

fn addAllExamplesStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mods: Modules,
) *std.Build.Step {
    const step = b.step("examples", "Build all examples");

    const examples = [_]struct {
        exe: []const u8,
        src: []const u8,
        import_name: []const u8,
        import_mod: *std.Build.Module,
        needs_driver_echo: bool = false,
    }{
        .{
            .exe = "static_core_errors_vocabulary",
            .src = "packages/static_core/examples/errors_vocabulary.zig",
            .import_name = "static_core",
            .import_mod = mods.static_core,
        },
        .{
            .exe = "static_core_config_validate",
            .src = "packages/static_core/examples/config_validate.zig",
            .import_name = "static_core",
            .import_mod = mods.static_core,
        },

        .{
            .exe = "static_bits_byte_reader",
            .src = "packages/static_bits/examples/byte_reader.zig",
            .import_name = "static_bits",
            .import_mod = mods.static_bits,
        },
        .{
            .exe = "static_bits_byte_writer",
            .src = "packages/static_bits/examples/byte_writer.zig",
            .import_name = "static_bits",
            .import_mod = mods.static_bits,
        },

        .{
            .exe = "static_hash_hash_bytes",
            .src = "packages/static_hash/examples/hash_bytes.zig",
            .import_name = "static_hash",
            .import_mod = mods.static_hash,
        },
        .{
            .exe = "static_hash_fingerprint_v1",
            .src = "packages/static_hash/examples/fingerprint_v1.zig",
            .import_name = "static_hash",
            .import_mod = mods.static_hash,
        },

        .{
            .exe = "static_memory_budget_lock_in",
            .src = "packages/static_memory/examples/budget_lock_in.zig",
            .import_name = "static_memory",
            .import_mod = mods.static_memory,
        },
        .{
            .exe = "static_memory_scratch_mark_rollback",
            .src = "packages/static_memory/examples/scratch_mark_rollback.zig",
            .import_name = "static_memory",
            .import_mod = mods.static_memory,
        },
        .{
            .exe = "static_memory_typed_pool_basic",
            .src = "packages/static_memory/examples/typed_pool_basic.zig",
            .import_name = "static_memory",
            .import_mod = mods.static_memory,
        },
        .{
            .exe = "static_memory_budget_lock_in_embedded",
            .src = "packages/static_memory/examples/budget_lock_in_embedded.zig",
            .import_name = "static_memory",
            .import_mod = mods.static_memory,
        },
        .{
            .exe = "static_memory_frame_arena_reset",
            .src = "packages/static_memory/examples/frame_arena_reset.zig",
            .import_name = "static_memory",
            .import_mod = mods.static_memory,
        },

        .{
            .exe = "static_sync_semaphore_basic",
            .src = "packages/static_sync/examples/semaphore_basic.zig",
            .import_name = "static_sync",
            .import_mod = mods.static_sync,
        },
        .{
            .exe = "static_sync_once_basic",
            .src = "packages/static_sync/examples/once_basic.zig",
            .import_name = "static_sync",
            .import_mod = mods.static_sync,
        },
        .{
            .exe = "static_sync_cancel_basic",
            .src = "packages/static_sync/examples/cancel_basic.zig",
            .import_name = "static_sync",
            .import_mod = mods.static_sync,
        },
        .{
            .exe = "static_sync_event_wait_for_work",
            .src = "packages/static_sync/examples/event_wait_for_work.zig",
            .import_name = "static_sync",
            .import_mod = mods.static_sync,
        },

        .{
            .exe = "static_collections_vec_basic",
            .src = "packages/static_collections/examples/vec_basic.zig",
            .import_name = "static_collections",
            .import_mod = mods.static_collections,
        },
        .{
            .exe = "static_collections_flat_hash_map_seeded",
            .src = "packages/static_collections/examples/flat_hash_map_seeded.zig",
            .import_name = "static_collections",
            .import_mod = mods.static_collections,
        },
        .{
            .exe = "static_collections_slot_map_handles",
            .src = "packages/static_collections/examples/slot_map_handles.zig",
            .import_name = "static_collections",
            .import_mod = mods.static_collections,
        },
        .{
            .exe = "static_collections_min_heap_basic",
            .src = "packages/static_collections/examples/min_heap_basic.zig",
            .import_name = "static_collections",
            .import_mod = mods.static_collections,
        },

        .{
            .exe = "static_serial_varint_roundtrip",
            .src = "packages/static_serial/examples/varint_roundtrip.zig",
            .import_name = "static_serial",
            .import_mod = mods.static_serial,
        },
        .{
            .exe = "static_serial_reader_writer_endian",
            .src = "packages/static_serial/examples/reader_writer_endian.zig",
            .import_name = "static_serial",
            .import_mod = mods.static_serial,
        },
        .{
            .exe = "static_serial_checksum_frame",
            .src = "packages/static_serial/examples/checksum_frame.zig",
            .import_name = "static_serial",
            .import_mod = mods.static_serial,
        },
        .{
            .exe = "static_serial_parse_length_prefixed_frame",
            .src = "packages/static_serial/examples/parse_length_prefixed_frame.zig",
            .import_name = "static_serial",
            .import_mod = mods.static_serial,
        },
        .{
            .exe = "static_serial_cursor_endian_varint_message",
            .src = "packages/static_serial/examples/cursor_endian_varint_message.zig",
            .import_name = "static_serial",
            .import_mod = mods.static_serial,
        },
        .{
            .exe = "static_net_address_parse_format_basic",
            .src = "packages/static_net/examples/address_parse_format_basic.zig",
            .import_name = "static_net",
            .import_mod = mods.static_net,
        },
        .{
            .exe = "static_net_frame_codec_incremental_basic",
            .src = "packages/static_net/examples/frame_codec_incremental_basic.zig",
            .import_name = "static_net",
            .import_mod = mods.static_net,
        },
        .{
            .exe = "static_net_frame_checksum_roundtrip_basic",
            .src = "packages/static_net/examples/frame_checksum_roundtrip_basic.zig",
            .import_name = "static_net",
            .import_mod = mods.static_net,
        },
        .{
            .exe = "static_net_native_endpoint_sockaddr_roundtrip",
            .src = "packages/static_net_native/examples/endpoint_sockaddr_roundtrip.zig",
            .import_name = "static_net_native",
            .import_mod = mods.static_net_native,
        },
        .{
            .exe = "static_io_fake_backend_roundtrip",
            .src = "packages/static_io/examples/fake_backend_roundtrip.zig",
            .import_name = "static_io",
            .import_mod = mods.static_io,
        },
        .{
            .exe = "static_io_buffer_pool_exhaustion",
            .src = "packages/static_io/examples/buffer_pool_exhaustion.zig",
            .import_name = "static_io",
            .import_mod = mods.static_io,
        },

        .{
            .exe = "static_queues_ring_buffer_basic",
            .src = "packages/static_queues/examples/ring_buffer_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_spsc_basic",
            .src = "packages/static_queues/examples/spsc_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_channel_close",
            .src = "packages/static_queues/examples/channel_close.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_spsc_isr_handoff",
            .src = "packages/static_queues/examples/spsc_isr_handoff.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_mpsc_job_handoff",
            .src = "packages/static_queues/examples/mpsc_job_handoff.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },

        .{
            .exe = "static_scheduling_task_graph_topo",
            .src = "packages/static_scheduling/examples/task_graph_topo.zig",
            .import_name = "static_scheduling",
            .import_mod = mods.static_scheduling,
        },

        .{
            .exe = "static_profile_chrome_trace_basic",
            .src = "packages/static_profile/examples/chrome_trace_basic.zig",
            .import_name = "static_profile",
            .import_mod = mods.static_profile,
        },
        .{
            .exe = "static_profile_counter_basic",
            .src = "packages/static_profile/examples/counter_basic.zig",
            .import_name = "static_profile",
            .import_mod = mods.static_profile,
        },
        .{
            .exe = "static_profile_hooks_emit_basic",
            .src = "packages/static_profile/examples/hooks_emit_basic.zig",
            .import_name = "static_profile",
            .import_mod = mods.static_profile,
        },

        .{
            .exe = "static_testing_replay_roundtrip",
            .src = "packages/static_testing/examples/replay_roundtrip.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_bench_smoke",
            .src = "packages/static_testing/examples/bench_smoke.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_bench_baseline_compare",
            .src = "packages/static_testing/examples/bench_baseline_compare.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_fuzz_seeded_runner",
            .src = "packages/static_testing/examples/fuzz_seeded_runner.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_explore_pct_bias",
            .src = "packages/static_testing/examples/sim_explore_pct_bias.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_ordered_effect_sequencer",
            .src = "packages/static_testing/examples/ordered_effect_sequencer.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_network_link_group_partition",
            .src = "packages/static_testing/examples/sim_network_link_group_partition.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_network_link_backlog_pressure",
            .src = "packages/static_testing/examples/sim_network_link_backlog_pressure.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_network_link_record_replay",
            .src = "packages/static_testing/examples/sim_network_link_record_replay.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_timer_mailbox",
            .src = "packages/static_testing/examples/sim_timer_mailbox.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_swarm_sim_runner",
            .src = "packages/static_testing/examples/swarm_sim_runner.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_repair_liveness_basic",
            .src = "packages/static_testing/examples/repair_liveness_basic.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_model_sim_fixture",
            .src = "packages/static_testing/examples/model_sim_fixture.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_storage_durability",
            .src = "packages/static_testing/examples/sim_storage_durability.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_storage_durability_record_replay",
            .src = "packages/static_testing/examples/sim_storage_durability_record_replay.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_storage_durability_misdirected_write",
            .src = "packages/static_testing/examples/sim_storage_durability_misdirected_write.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_storage_durability_acknowledged_not_durable",
            .src = "packages/static_testing/examples/sim_storage_durability_acknowledged_not_durable.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_sim_clock_drift",
            .src = "packages/static_testing/examples/sim_clock_drift.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_system_storage_retry_flow",
            .src = "packages/static_testing/examples/system_storage_retry_flow.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
        },
        .{
            .exe = "static_testing_system_process_driver_flow",
            .src = "packages/static_testing/examples/system_process_driver_flow.zig",
            .import_name = "static_testing",
            .import_mod = mods.static_testing,
            .needs_driver_echo = true,
        },

        .{
            .exe = "static_simd_vec4f_basic",
            .src = "packages/static_simd/examples/vec4f_basic.zig",
            .import_name = "static_simd",
            .import_mod = mods.static_simd,
        },
        .{
            .exe = "static_simd_masked_gather_scatter_basic",
            .src = "packages/static_simd/examples/masked_gather_scatter_basic.zig",
            .import_name = "static_simd",
            .import_mod = mods.static_simd,
        },
        .{
            .exe = "static_simd_compare_select_basic",
            .src = "packages/static_simd/examples/compare_select_basic.zig",
            .import_name = "static_simd",
            .import_mod = mods.static_simd,
        },
        .{
            .exe = "static_simd_trig4f_range_and_accuracy",
            .src = "packages/static_simd/examples/trig4f_range_and_accuracy.zig",
            .import_name = "static_simd",
            .import_mod = mods.static_simd,
        },
        .{
            .exe = "static_meta_type_id_basic",
            .src = "packages/static_meta/examples/type_id_basic.zig",
            .import_name = "static_meta",
            .import_mod = mods.static_meta,
        },
        .{
            .exe = "static_meta_type_registry_basic",
            .src = "packages/static_meta/examples/type_registry_basic.zig",
            .import_name = "static_meta",
            .import_mod = mods.static_meta,
        },
        .{
            .exe = "static_rng_pcg32_basic",
            .src = "packages/static_rng/examples/pcg32_basic.zig",
            .import_name = "static_rng",
            .import_mod = mods.static_rng,
        },
        .{
            .exe = "static_rng_shuffle_basic",
            .src = "packages/static_rng/examples/shuffle_basic.zig",
            .import_name = "static_rng",
            .import_mod = mods.static_rng,
        },
        .{
            .exe = "static_rng_xoroshiro_split_distributions",
            .src = "packages/static_rng/examples/xoroshiro_split_distributions.zig",
            .import_name = "static_rng",
            .import_mod = mods.static_rng,
        },
        .{
            .exe = "static_string_ascii_normalize_basic",
            .src = "packages/static_string/examples/ascii_normalize_basic.zig",
            .import_name = "static_string",
            .import_mod = mods.static_string,
        },
        .{
            .exe = "static_string_bounded_buffer_basic",
            .src = "packages/static_string/examples/bounded_buffer_basic.zig",
            .import_name = "static_string",
            .import_mod = mods.static_string,
        },
        .{
            .exe = "static_string_intern_pool_basic",
            .src = "packages/static_string/examples/intern_pool_basic.zig",
            .import_name = "static_string",
            .import_mod = mods.static_string,
        },
        .{
            .exe = "static_string_utf8_validate_basic",
            .src = "packages/static_string/examples/utf8_validate_basic.zig",
            .import_name = "static_string",
            .import_mod = mods.static_string,
        },

        .{
            .exe = "static_queues_broadcast_basic",
            .src = "packages/static_queues/examples/broadcast_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_inbox_outbox_basic",
            .src = "packages/static_queues/examples/inbox_outbox_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_work_stealing_basic",
            .src = "packages/static_queues/examples/work_stealing_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_mpmc_basic",
            .src = "packages/static_queues/examples/mpmc_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_priority_queue_basic",
            .src = "packages/static_queues/examples/priority_queue_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_intrusive_basic",
            .src = "packages/static_queues/examples/intrusive_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },
        .{
            .exe = "static_queues_disruptor_basic",
            .src = "packages/static_queues/examples/disruptor_basic.zig",
            .import_name = "static_queues",
            .import_mod = mods.static_queues,
        },

        .{
            .exe = "static_sync_barrier_basic",
            .src = "packages/static_sync/examples/barrier_basic.zig",
            .import_name = "static_sync",
            .import_mod = mods.static_sync,
        },
        .{
            .exe = "static_sync_grant_token_basic",
            .src = "packages/static_sync/examples/grant_token_basic.zig",
            .import_name = "static_sync",
            .import_mod = mods.static_sync,
        },

        .{
            .exe = "static_bits_bit_cursor",
            .src = "packages/static_bits/examples/bit_cursor.zig",
            .import_name = "static_bits",
            .import_mod = mods.static_bits,
        },
        .{
            .exe = "static_bits_varint",
            .src = "packages/static_bits/examples/varint.zig",
            .import_name = "static_bits",
            .import_mod = mods.static_bits,
        },

        .{
            .exe = "static_hash_hash_any",
            .src = "packages/static_hash/examples/hash_any.zig",
            .import_name = "static_hash",
            .import_mod = mods.static_hash,
        },
        .{
            .exe = "static_hash_stable_hash",
            .src = "packages/static_hash/examples/stable_hash.zig",
            .import_name = "static_hash",
            .import_mod = mods.static_hash,
        },
        .{
            .exe = "static_hash_siphash_keyed",
            .src = "packages/static_hash/examples/siphash_keyed.zig",
            .import_name = "static_hash",
            .import_mod = mods.static_hash,
        },

        .{
            .exe = "static_simd_memory_load_store",
            .src = "packages/static_simd/examples/memory_load_store.zig",
            .import_name = "static_simd",
            .import_mod = mods.static_simd,
        },
        .{
            .exe = "static_simd_horizontal_reduction",
            .src = "packages/static_simd/examples/horizontal_reduction.zig",
            .import_name = "static_simd",
            .import_mod = mods.static_simd,
        },

        // static_spatial and static_math (BLD-A1)
        .{
            .exe = "static_spatial_basic",
            .src = "packages/static_spatial/examples/spatial_basic.zig",
            .import_name = "static_spatial",
            .import_mod = mods.static_spatial,
        },
        .{
            .exe = "static_spatial_uniform_grid_3d_basic",
            .src = "packages/static_spatial/examples/uniform_grid_3d_basic.zig",
            .import_name = "static_spatial",
            .import_mod = mods.static_spatial,
        },
        .{
            .exe = "static_spatial_bvh_ray_aabb_frustum_basic",
            .src = "packages/static_spatial/examples/bvh_ray_aabb_frustum_basic.zig",
            .import_name = "static_spatial",
            .import_mod = mods.static_spatial,
        },
        .{
            .exe = "static_spatial_incremental_bvh_insert_remove_refit",
            .src = "packages/static_spatial/examples/incremental_bvh_insert_remove_refit.zig",
            .import_name = "static_spatial",
            .import_mod = mods.static_spatial,
        },
        .{
            .exe = "static_math_basic",
            .src = "packages/static_math/examples/math_basic.zig",
            .import_name = "static_math",
            .import_mod = mods.static_math,
        },
        .{
            .exe = "static_math_transform_roundtrip",
            .src = "packages/static_math/examples/transform_roundtrip.zig",
            .import_name = "static_math",
            .import_mod = mods.static_math,
        },
        .{
            .exe = "static_math_camera_look_at_conventions",
            .src = "packages/static_math/examples/camera_look_at_conventions.zig",
            .import_name = "static_math",
            .import_mod = mods.static_math,
        },
        .{
            .exe = "static_math_mat3_2d_transform",
            .src = "packages/static_math/examples/mat3_2d_transform.zig",
            .import_name = "static_math",
            .import_mod = mods.static_math,
        },
    };

    const static_testing_driver_echo = b.addExecutable(.{
        .name = "workspace_static_testing_example_driver_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/static_testing/tests/support/driver_echo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "static_testing", .module = mods.static_testing },
            },
        }),
    });
    const static_testing_example_options = b.addOptions();
    static_testing_example_options.addOptionPath(
        "driver_echo_path",
        static_testing_driver_echo.getEmittedBin(),
    );
    const static_testing_example_options_mod = static_testing_example_options.createModule();

    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.exe,
            .root_module = if (ex.needs_driver_echo)
                b.createModule(.{
                    .root_source_file = b.path(ex.src),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = ex.import_name, .module = ex.import_mod },
                        .{ .name = "static_testing_example_options", .module = static_testing_example_options_mod },
                    },
                })
            else
                b.createModule(.{
                    .root_source_file = b.path(ex.src),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = ex.import_name, .module = ex.import_mod },
                    },
                }),
        });
        if (ex.needs_driver_echo) {
            exe.step.dependOn(&static_testing_driver_echo.step);
        }
        step.dependOn(&exe.step);
    }

    return step;
}
