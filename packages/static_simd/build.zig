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
    options.addOption([]const u8, "static_package", "static_simd");
    const options_mod = options.createModule();

    const static_simd_mod = b.addModule("static_simd", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = static_simd_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build examples");
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "static_simd_vec4f_basic", .path = "examples/vec4f_basic.zig" },
        .{ .name = "static_simd_memory_load_store", .path = "examples/memory_load_store.zig" },
        .{ .name = "static_simd_horizontal_reduction", .path = "examples/horizontal_reduction.zig" },
        .{ .name = "static_simd_masked_gather_scatter_basic", .path = "examples/masked_gather_scatter_basic.zig" },
        .{ .name = "static_simd_compare_select_basic", .path = "examples/compare_select_basic.zig" },
        .{ .name = "static_simd_trig4f_range_and_accuracy", .path = "examples/trig4f_range_and_accuracy.zig" },
    };
    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "static_simd", .module = static_simd_mod },
                },
            }),
        });
        examples_step.dependOn(&exe.step);
    }
}
