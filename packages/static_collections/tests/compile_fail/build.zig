const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(bool, "single_threaded", false);
    options.addOption(bool, "enable_os_backends", false);
    options.addOption(bool, "enable_tracing", false);
    options.addOption([]const u8, "static_package", "static_collections_compile_fail");
    const options_mod = options.createModule();

    const static_core_mod = b.addModule("static_core", .{
        .root_source_file = b.path("../../../static_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
        },
    });

    const static_sync_mod = b.addModule("static_sync", .{
        .root_source_file = b.path("../../../static_sync/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_core", .module = static_core_mod },
        },
    });

    const static_memory_mod = b.addModule("static_memory", .{
        .root_source_file = b.path("../../../static_memory/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_core", .module = static_core_mod },
            .{ .name = "static_sync", .module = static_sync_mod },
        },
    });

    const static_hash_mod = b.addModule("static_hash", .{
        .root_source_file = b.path("../../../static_hash/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
        },
    });

    const static_collections_mod = b.addModule("static_collections", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_memory", .module = static_memory_mod },
            .{ .name = "static_hash", .module = static_hash_mod },
        },
    });

    const fixtures = [_]struct {
        step_name: []const u8,
        path: []const u8,
        description: []const u8,
    }{
        .{
            .step_name = "flat_hash_map_default_hash_padded_key",
            .path = "fixtures/flat_hash_map_default_hash_padded_key.zig",
            .description = "Compile the padded-key default-hash rejection fixture",
        },
        .{
            .step_name = "flat_hash_map_invalid_hash_signature",
            .path = "fixtures/flat_hash_map_invalid_hash_signature.zig",
            .description = "Compile the invalid FlatHashMap hash callback signature fixture",
        },
        .{
            .step_name = "min_heap_invalid_less_than_signature",
            .path = "fixtures/min_heap_invalid_less_than_signature.zig",
            .description = "Compile the invalid MinHeap comparator fixture",
        },
        .{
            .step_name = "sorted_vec_map_invalid_comparator_signature",
            .path = "fixtures/sorted_vec_map_invalid_comparator_signature.zig",
            .description = "Compile the invalid SortedVecMap comparator fixture",
        },
    };

    for (fixtures) |fixture| {
        const object = b.addObject(.{
            .name = fixture.step_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(fixture.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "static_collections", .module = static_collections_mod },
                },
            }),
        });
        const step = b.step(fixture.step_name, fixture.description);
        step.dependOn(&object.step);
    }
}
