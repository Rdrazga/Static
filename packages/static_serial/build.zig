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
    options.addOption([]const u8, "static_package", "static_serial");
    const options_mod = options.createModule();

    const core_dep = b.dependency("static_core", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const bits_dep = b.dependency("static_bits", .{
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

    const core_mod = core_dep.module("static_core");
    const bits_mod = bits_dep.module("static_bits");
    const hash_mod = hash_dep.module("static_hash");

    const static_serial_mod = b.addModule("static_serial", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_core", .module = core_mod },
            .{ .name = "static_bits", .module = bits_mod },
            .{ .name = "static_hash", .module = hash_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = static_serial_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build examples");
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{
            .name = "static_serial_varint_roundtrip",
            .path = "examples/varint_roundtrip.zig",
        },
        .{
            .name = "static_serial_reader_writer_endian",
            .path = "examples/reader_writer_endian.zig",
        },
        .{
            .name = "static_serial_checksum_frame",
            .path = "examples/checksum_frame.zig",
        },
        .{
            .name = "static_serial_parse_length_prefixed_frame",
            .path = "examples/parse_length_prefixed_frame.zig",
        },
        .{
            .name = "static_serial_cursor_endian_varint_message",
            .path = "examples/cursor_endian_varint_message.zig",
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
                    .{ .name = "static_serial", .module = static_serial_mod },
                },
            }),
        });
        examples_step.dependOn(&exe.step);
    }
}
