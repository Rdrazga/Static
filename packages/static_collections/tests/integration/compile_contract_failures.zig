//! Negative compile-contract coverage for the package's comptime validators.
//! Each fixture is expected to fail compilation with a precise diagnostic.
const std = @import("std");
const testing = std.testing;

const CompileFailCase = struct {
    step_name: []const u8,
    expected_fragment: []const u8,
};

const compile_fail_cases = [_]CompileFailCase{
    .{
        .step_name = "flat_hash_map_default_hash_padded_key",
        .expected_fragment = "FlatHashMap default hashing cannot safely hash key type",
    },
    .{
        .step_name = "flat_hash_map_invalid_hash_signature",
        .expected_fragment = "Ctx.hash second parameter must be u64",
    },
    .{
        .step_name = "min_heap_invalid_less_than_signature",
        .expected_fragment = "Ctx.lessThan parameters must both be T or both be *const T",
    },
    .{
        .step_name = "sorted_vec_map_invalid_comparator_signature",
        .expected_fragment = "Cmp.less must have signature `fn(a: K, b: K) bool` or `fn(a: *const K, b: *const K) bool`",
    },
};

test "static_collections compile-contract fixtures fail with stable diagnostics" {
    const compile_fail_dir = try compileFailDirAlloc(testing.allocator);
    defer testing.allocator.free(compile_fail_dir);

    for (compile_fail_cases) |case| {
        try expectCompileFailure(compile_fail_dir, case);
    }
}

fn expectCompileFailure(
    compile_fail_dir: []const u8,
    case: CompileFailCase,
) !void {
    const argv = [_][]const u8{
        "zig",
        "build",
        case.step_name,
        "--summary",
        "none",
    };
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &argv,
        .cwd = .{ .path = compile_fail_dir },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try testing.expect(code != 0),
        else => {},
    }
    try testing.expect(std.mem.indexOf(u8, result.stderr, case.expected_fragment) != null);
}

fn compileFailDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{
        cwd,
        "packages",
        "static_collections",
        "tests",
        "compile_fail",
    });
}
