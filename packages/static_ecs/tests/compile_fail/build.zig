const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(bool, "single_threaded", false);
    options.addOption(bool, "enable_os_backends", false);
    options.addOption(bool, "enable_tracing", false);
    options.addOption([]const u8, "static_package", "static_ecs_compile_fail");
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
        .root_source_file = b.path("../../../static_collections/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_memory", .module = static_memory_mod },
            .{ .name = "static_hash", .module = static_hash_mod },
        },
    });

    const static_ecs_mod = b.addModule("static_ecs", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_memory", .module = static_memory_mod },
            .{ .name = "static_collections", .module = static_collections_mod },
            .{ .name = "static_hash", .module = static_hash_mod },
        },
    });

    const fixtures = [_]struct {
        step_name: []const u8,
        path: []const u8,
        description: []const u8,
    }{
        .{
            .step_name = "component_registry_invalid_universe_entry",
            .path = "fixtures/component_registry_invalid_universe_entry.zig",
            .description = "Compile the invalid component-universe entry fixture",
        },
        .{
            .step_name = "archetype_key_duplicate_type",
            .path = "fixtures/archetype_key_duplicate_type.zig",
            .description = "Compile the duplicate ArchetypeKey.fromTypes fixture",
        },
        .{
            .step_name = "query_tag_read_rejected",
            .path = "fixtures/query_tag_read_rejected.zig",
            .description = "Compile the zero-sized tag read fixture",
        },
        .{
            .step_name = "query_out_of_universe_component",
            .path = "fixtures/query_out_of_universe_component.zig",
            .description = "Compile the out-of-universe query component fixture",
        },
        .{
            .step_name = "command_buffer_invalid_component_type",
            .path = "fixtures/command_buffer_invalid_component_type.zig",
            .description = "Compile the out-of-universe command-buffer component fixture",
        },
        .{
            .step_name = "command_buffer_insert_bundle_non_tuple",
            .path = "fixtures/command_buffer_insert_bundle_non_tuple.zig",
            .description = "Compile the non-tuple command-buffer insert bundle fixture",
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
                    .{ .name = "static_ecs", .module = static_ecs_mod },
                },
            }),
        });
        const step = b.step(fixture.step_name, fixture.description);
        step.dependOn(&object.step);
    }
}
