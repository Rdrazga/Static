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
    options.addOption([]const u8, "static_package", "static_io");
    const options_mod = options.createModule();

    const core_dep = b.dependency("static_core", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const memory_dep = b.dependency("static_memory", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const queues_dep = b.dependency("static_queues", .{
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
    const net_dep = b.dependency("static_net", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const net_native_dep = b.dependency("static_net_native", .{
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

    const core_mod = core_dep.module("static_core");
    const memory_mod = memory_dep.module("static_memory");
    const queues_mod = queues_dep.module("static_queues");
    const collections_mod = collections_dep.module("static_collections");
    const net_mod = net_dep.module("static_net");
    const net_native_mod = net_native_dep.module("static_net_native");
    const sync_mod = sync_dep.module("static_sync");

    const static_io_mod = b.addModule("static_io", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_core", .module = core_mod },
            .{ .name = "static_memory", .module = memory_mod },
            .{ .name = "static_queues", .module = queues_mod },
            .{ .name = "static_collections", .module = collections_mod },
            .{ .name = "static_net", .module = net_mod },
            .{ .name = "static_net_native", .module = net_native_mod },
            .{ .name = "static_sync", .module = sync_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = static_io_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build examples");
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{
            .name = "static_io_fake_backend_roundtrip",
            .path = "examples/fake_backend_roundtrip.zig",
        },
        .{
            .name = "static_io_buffer_pool_exhaustion",
            .path = "examples/buffer_pool_exhaustion.zig",
        },
    };
    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "static_io", .module = static_io_mod },
                },
            }),
        });
        examples_step.dependOn(&exe.step);
    }
}
