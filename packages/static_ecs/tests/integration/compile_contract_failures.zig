//! Negative compile-contract coverage for the package's public comptime validators.
const std = @import("std");
const testing = std.testing;

const CompileFailCase = struct {
    fixture_name: []const u8,
    expected_fragment: []const u8,
};

const compile_fail_cases = [_]CompileFailCase{
    .{
        .fixture_name = "component_registry_invalid_universe_entry.zig",
        .expected_fragment = "Component universe entries must be types.",
    },
    .{
        .fixture_name = "archetype_key_duplicate_type.zig",
        .expected_fragment = "ArchetypeKey.fromTypes must not contain duplicate component types.",
    },
    .{
        .fixture_name = "query_tag_read_rejected.zig",
        .expected_fragment = "Zero-sized tag components must use With/Exclude instead of column access.",
    },
    .{
        .fixture_name = "query_out_of_universe_component.zig",
        .expected_fragment = "Query access descriptors must come from the component universe.",
    },
    .{
        .fixture_name = "command_buffer_invalid_component_type.zig",
        .expected_fragment = "CommandBuffer component operations require a type from the component universe.",
    },
    .{
        .fixture_name = "command_buffer_insert_bundle_non_tuple.zig",
        .expected_fragment = "CommandBuffer.stageInsertBundle expects a comptime tuple of component values.",
    },
};

test "static_ecs compile-contract fixtures fail with stable diagnostics" {
    const repo_root = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(repo_root);

    for (compile_fail_cases) |case| {
        try expectCompileFailure(repo_root, case);
    }
}

fn expectCompileFailure(repo_root: []const u8, case: CompileFailCase) !void {
    const fixture_path = try std.fs.path.join(testing.allocator, &.{
        repo_root,
        "packages",
        "static_ecs",
        "tests",
        "compile_fail",
        "fixtures",
        case.fixture_name,
    });
    defer testing.allocator.free(fixture_path);
    const build_options_path = try std.fs.path.join(testing.allocator, &.{
        repo_root,
        "packages",
        "static_ecs",
        "tests",
        "compile_fail",
        "build_options.zig",
    });
    defer testing.allocator.free(build_options_path);
    const static_ecs_path = try std.fs.path.join(testing.allocator, &.{
        repo_root,
        "packages",
        "static_ecs",
        "src",
        "root.zig",
    });
    defer testing.allocator.free(static_ecs_path);
    const static_memory_path = try std.fs.path.join(testing.allocator, &.{
        repo_root,
        "packages",
        "static_memory",
        "src",
        "root.zig",
    });
    defer testing.allocator.free(static_memory_path);
    const static_collections_path = try std.fs.path.join(testing.allocator, &.{
        repo_root,
        "packages",
        "static_collections",
        "src",
        "root.zig",
    });
    defer testing.allocator.free(static_collections_path);
    const static_hash_path = try std.fs.path.join(testing.allocator, &.{
        repo_root,
        "packages",
        "static_hash",
        "src",
        "root.zig",
    });
    defer testing.allocator.free(static_hash_path);
    const static_core_path = try std.fs.path.join(testing.allocator, &.{
        repo_root,
        "packages",
        "static_core",
        "src",
        "root.zig",
    });
    defer testing.allocator.free(static_core_path);
    const static_sync_path = try std.fs.path.join(testing.allocator, &.{
        repo_root,
        "packages",
        "static_sync",
        "src",
        "root.zig",
    });
    defer testing.allocator.free(static_sync_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    var owned_args: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_args.items) |arg| testing.allocator.free(arg);
        owned_args.deinit(testing.allocator);
    }

    try argv.append(testing.allocator, "zig");
    try argv.append(testing.allocator, "build-obj");
    try argv.append(testing.allocator, "-ODebug");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_ecs");
    try appendModuleArg(&argv, &owned_args, "root", fixture_path);
    try argv.append(testing.allocator, "-ODebug");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_build_options");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_memory");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_collections");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_hash");
    try appendModuleArg(&argv, &owned_args, "static_ecs", static_ecs_path);
    try argv.append(testing.allocator, "-ODebug");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_build_options");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_core");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_sync");
    try appendModuleArg(&argv, &owned_args, "static_build_options", build_options_path);
    try appendModuleArg(&argv, &owned_args, "static_memory", static_memory_path);
    try argv.append(testing.allocator, "-ODebug");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_build_options");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_memory");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_hash");
    try appendModuleArg(&argv, &owned_args, "static_collections", static_collections_path);
    try argv.append(testing.allocator, "-ODebug");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_build_options");
    try appendModuleArg(&argv, &owned_args, "static_hash", static_hash_path);
    try argv.append(testing.allocator, "-ODebug");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_build_options");
    try appendModuleArg(&argv, &owned_args, "static_core", static_core_path);
    try argv.append(testing.allocator, "-ODebug");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_build_options");
    try argv.append(testing.allocator, "--dep");
    try argv.append(testing.allocator, "static_core");
    try appendModuleArg(&argv, &owned_args, "static_sync", static_sync_path);
    try argv.append(testing.allocator, "-fno-emit-bin");

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = repo_root },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try testing.expect(code != 0),
        else => {},
    }
    try testing.expect(std.mem.indexOf(u8, result.stderr, case.expected_fragment) != null);
}

fn appendModuleArg(
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]u8),
    module_name: []const u8,
    module_path: []const u8,
) !void {
    const arg = try std.fmt.allocPrint(testing.allocator, "-M{s}={s}", .{ module_name, module_path });
    try argv.append(testing.allocator, arg);
    try owned_args.append(testing.allocator, arg);
}
