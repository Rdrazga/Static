// This package is built as part of the static workspace.
// Standalone `zig build` from this directory is not supported.
// Use `zig build` from the workspace root instead.
const std = @import("std");

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

    const options = b.addOptions();
    options.addOption(bool, "single_threaded", single_threaded);
    options.addOption(bool, "enable_os_backends", enable_os_backends);
    options.addOption(bool, "enable_tracing", enable_tracing);
    options.addOption([]const u8, "static_package", "static_scheduling");
    const options_mod = options.createModule();

    const core_dep = b.dependency("static_core", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const sync_dep = b.dependency("static_sync", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const collections_dep = b.dependency("static_collections", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });

    const core_mod = core_dep.module("static_core");
    const sync_mod = sync_dep.module("static_sync");
    const collections_mod = collections_dep.module("static_collections");

    const static_scheduling_mod = b.addModule("static_scheduling", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_core", .module = core_mod },
            .{ .name = "static_sync", .module = sync_mod },
            .{ .name = "static_collections", .module = collections_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = static_scheduling_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build examples");
    const exe = b.addExecutable(.{
        .name = "static_scheduling_task_graph_topo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/task_graph_topo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "static_scheduling", .module = static_scheduling_mod },
            },
        }),
    });
    examples_step.dependOn(&exe.step);
}
