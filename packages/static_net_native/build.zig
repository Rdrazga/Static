// This package keeps package-local validation so its dependency contract can
// stay aligned with the workspace root instead of drifting silently.
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
    options.addOption([]const u8, "static_package", "static_net_native");
    const options_mod = options.createModule();

    const net_dep = b.dependency("static_net", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const net_mod = net_dep.module("static_net");

    const static_net_native_mod = b.addModule("static_net_native", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_net", .module = net_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = static_net_native_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build examples");
    const exe = b.addExecutable(.{
        .name = "static_net_native_endpoint_sockaddr_roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/endpoint_sockaddr_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "static_net_native", .module = static_net_native_mod },
            },
        }),
    });
    examples_step.dependOn(&exe.step);
}
