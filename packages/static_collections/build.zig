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
    options.addOption([]const u8, "static_package", "static_collections");
    const options_mod = options.createModule();

    const memory_dep = b.dependency("static_memory", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const hash_dep = b.dependency("static_hash", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });

    const memory_mod = memory_dep.module("static_memory");
    const hash_mod = hash_dep.module("static_hash");

    const static_collections_mod = b.addModule("static_collections", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_memory", .module = memory_mod },
            .{ .name = "static_hash", .module = hash_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = static_collections_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build examples");
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{
            .name = "static_collections_vec_basic",
            .path = "examples/vec_basic.zig",
        },
        .{
            .name = "static_collections_flat_hash_map_seeded",
            .path = "examples/flat_hash_map_seeded.zig",
        },
        .{
            .name = "static_collections_slot_map_handles",
            .path = "examples/slot_map_handles.zig",
        },
        .{
            .name = "static_collections_min_heap_basic",
            .path = "examples/min_heap_basic.zig",
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
                    .{ .name = "static_collections", .module = static_collections_mod },
                },
            }),
        });
        examples_step.dependOn(&exe.step);
    }
}
