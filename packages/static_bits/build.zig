// This package supports local validation with `zig build` from this directory
// and workspace-wide validation from the repository root.
const std = @import("std");

const ExampleSpec = struct {
    name: []const u8,
    path: []const u8,
};

const CompileFailSpec = struct {
    name: []const u8,
    path: []const u8,
    expected_error: []const u8,
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

    const static_bits_mod = addStaticBitsModule(b, .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });

    addTestStep(b, .{
        .target = target,
        .optimize = optimize,
        .module = static_bits_mod,
    });
    addExampleStep(b, .{
        .target = target,
        .optimize = optimize,
        .module = static_bits_mod,
    });
}

const ModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    single_threaded: bool,
    enable_os_backends: bool,
    enable_tracing: bool,
};

fn addStaticBitsModule(b: *std.Build, options: ModuleOptions) *std.Build.Module {
    const package_options = b.addOptions();
    package_options.addOption(bool, "single_threaded", options.single_threaded);
    package_options.addOption(bool, "enable_os_backends", options.enable_os_backends);
    package_options.addOption(bool, "enable_tracing", options.enable_tracing);
    package_options.addOption([]const u8, "static_package", "static_bits");
    const options_mod = package_options.createModule();

    const core_dep = b.dependency("static_core", .{
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
        .enable_os_backends = options.enable_os_backends,
        .enable_tracing = options.enable_tracing,
    });
    const core_mod = core_dep.module("static_core");

    return b.addModule("static_bits", .{
        .root_source_file = b.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_core", .module = core_mod },
        },
    });
}

const TestStepOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
};

fn addTestStep(b: *std.Build, options: TestStepOptions) void {
    const tests = b.addTest(.{ .root_module = options.module });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    addCompileFailStep(b, .{
        .target = options.target,
        .optimize = options.optimize,
        .module = options.module,
        .test_step = test_step,
    });
}

const ExampleStepOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
};

fn addExampleStep(b: *std.Build, options: ExampleStepOptions) void {
    const examples_step = b.step("examples", "Run package examples");
    const examples = [_]ExampleSpec{
        .{ .name = "static_bits_byte_reader", .path = "examples/byte_reader.zig" },
        .{ .name = "static_bits_byte_writer", .path = "examples/byte_writer.zig" },
        .{ .name = "static_bits_bit_cursor", .path = "examples/bit_cursor.zig" },
        .{ .name = "static_bits_varint", .path = "examples/varint.zig" },
        .{ .name = "static_bits_endian_layout", .path = "examples/endian_layout.zig" },
        .{ .name = "static_bits_bitfield_layout", .path = "examples/bitfield_layout.zig" },
        .{ .name = "static_bits_checkpoint_rewind", .path = "examples/checkpoint_rewind.zig" },
        .{ .name = "static_bits_cast_int", .path = "examples/cast_int.zig" },
        .{ .name = "static_bits_compile_time_helpers", .path = "examples/compile_time_helpers.zig" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "static_bits", .module = options.module },
                },
            }),
        });
        const run_example = b.addRunArtifact(exe);
        examples_step.dependOn(&run_example.step);
    }
}

const CompileFailStepOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    test_step: *std.Build.Step,
};

fn addCompileFailStep(b: *std.Build, options: CompileFailStepOptions) void {
    const compile_fail = [_]CompileFailSpec{
        .{
            .name = "static_bits_read_int_at_invalid_offset",
            .path = "tests/compile_fail/read_int_at_invalid_offset.zig",
            .expected_error = "readIntAt requires offset 0 + size 2 <= array len 1",
        },
        .{
            .name = "static_bits_write_int_at_invalid_offset",
            .path = "tests/compile_fail/write_int_at_invalid_offset.zig",
            .expected_error = "writeIntAt requires offset 0 + size 2 <= array len 1",
        },
        .{
            .name = "static_bits_extract_bits_ct_invalid_range",
            .path = "tests/compile_fail/extract_bits_ct_invalid_range.zig",
            .expected_error = "extractBitsCt range [7, 9) exceeds 8-bit `u8`",
        },
        .{
            .name = "static_bits_insert_bits_ct_invalid_range",
            .path = "tests/compile_fail/insert_bits_ct_invalid_range.zig",
            .expected_error = "insertBitsCt range [7, 9) exceeds 8-bit `u8`",
        },
        .{
            .name = "static_bits_read_bits_ct_invalid_width",
            .path = "tests/compile_fail/read_bits_ct_invalid_width.zig",
            .expected_error = "readBitsCt bit_count 9 exceeds `u8` width 8",
        },
        .{
            .name = "static_bits_write_bits_ct_invalid_width",
            .path = "tests/compile_fail/write_bits_ct_invalid_width.zig",
            .expected_error = "writeBitsCt bit_count 9 exceeds `u8` width 8",
        },
        .{
            .name = "static_bits_decode_uleb128_ct_partial_slice",
            .path = "tests/compile_fail/decode_uleb128_ct_partial_slice.zig",
            .expected_error = "decodeUleb128Ct requires full-slice consumption: read 2 of 3 bytes",
        },
        .{
            .name = "static_bits_decode_sleb128_ct_partial_slice",
            .path = "tests/compile_fail/decode_sleb128_ct_partial_slice.zig",
            .expected_error = "decodeSleb128Ct requires full-slice consumption: read 1 of 2 bytes",
        },
    };

    for (compile_fail) |fixture| {
        const obj = b.addObject(.{
            .name = fixture.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(fixture.path),
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "static_bits", .module = options.module },
                },
            }),
        });
        obj.expect_errors = .{ .contains = fixture.expected_error };
        options.test_step.dependOn(&obj.step);
    }
}
