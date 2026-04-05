//! Benchmark case definitions and anti-elision helpers.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Supported benchmark parameter payload types.
pub const ParameterValue = union(enum) {
    u64: u64,
    i64: i64,
    bool: bool,
    bytes: []const u8,
};

/// One named benchmark parameter value.
pub const Parameter = struct {
    key: []const u8,
    value: ParameterValue,
};

/// Timed benchmark callback for in-process hot loops.
///
/// This surface is intentionally infallible: benchmark targets are expected to
/// validate setup before timing begins and encode operating failures outside the
/// measured callback.
pub const BenchmarkCaseFn = *const fn (context: *anyopaque) void;

/// Named arguments for constructing one benchmark case.
pub const BenchmarkCaseOptions = struct {
    name: []const u8,
    tags: []const []const u8 = &.{},
    parameters: []const Parameter = &.{},
    context: *anyopaque,
    run_fn: BenchmarkCaseFn,
};

/// In-process benchmark case plus static metadata.
pub const BenchmarkCase = struct {
    name: []const u8,
    tags: []const []const u8,
    parameters: []const Parameter,
    context: *anyopaque,
    run_fn: BenchmarkCaseFn,

    /// Construct one benchmark case from caller-provided metadata and callback.
    pub fn init(options: BenchmarkCaseOptions) BenchmarkCase {
        assert(options.name.len > 0);
        assertUniqueParameterKeys(options.parameters);
        assertValidTags(options.tags);

        return .{
            .name = options.name,
            .tags = options.tags,
            .parameters = options.parameters,
            .context = options.context,
            .run_fn = options.run_fn,
        };
    }

    /// Run the benchmark callback once.
    pub fn run(self: BenchmarkCase) void {
        self.run_fn(self.context);
    }
};

/// Preserve a value across optimization boundaries.
///
/// Use this for scalars and other cheap-by-value types. For large values, prefer
/// `blackBoxPointer()` to avoid introducing an extra copy into the benchmarked
/// code path.
pub fn blackBox(value: anytype) @TypeOf(value) {
    const preserved = value;
    std.mem.doNotOptimizeAway(preserved);
    return preserved;
}

/// Preserve a pointer across optimization boundaries without copying its pointee.
pub fn blackBoxPointer(pointer: anytype) void {
    const Pointer = @TypeOf(pointer);
    const pointer_info = @typeInfo(Pointer);
    comptime assert(pointer_info == .pointer);

    std.mem.doNotOptimizeAway(pointer);
}

fn assertUniqueParameterKeys(parameters: []const Parameter) void {
    for (parameters, 0..) |parameter, index| {
        assert(parameter.key.len > 0);
        for (parameters[0..index]) |previous| {
            assert(!std.mem.eql(u8, parameter.key, previous.key));
        }
    }
}

fn assertValidTags(tags: []const []const u8) void {
    for (tags) |tag| {
        assert(tag.len > 0);
    }
}

test "benchmark case preserves metadata and callback" {
    var context_value: u32 = 0;
    const tags = [_][]const u8{"smoke"};
    const parameters = [_]Parameter{
        .{ .key = "size", .value = .{ .u64 = 64 } },
    };
    const Context = struct {
        fn run(ctx: *anyopaque) void {
            const value: *u32 = @ptrCast(@alignCast(ctx));
            value.* += 1;
        }
    };

    const benchmark_case = BenchmarkCase.init(.{
        .name = "increment",
        .tags = &tags,
        .parameters = &parameters,
        .context = &context_value,
        .run_fn = Context.run,
    });
    benchmark_case.run();

    try testing.expectEqualStrings("increment", benchmark_case.name);
    try testing.expectEqual(@as(usize, 1), benchmark_case.tags.len);
    try testing.expectEqual(@as(usize, 1), benchmark_case.parameters.len);
    try testing.expectEqual(@as(u32, 1), context_value);
}

test "blackBox returns the preserved value" {
    try testing.expectEqual(@as(u64, 7), blackBox(@as(u64, 7)));
}

test "blackBoxPointer preserves pointer identity without copying pointee" {
    const Large = struct {
        values: [8]u64,
    };
    var large = Large{ .values = .{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    const before = &large;

    blackBoxPointer(before);

    try testing.expect(before == &large);
    try testing.expectEqual(@as(u64, 8), large.values[7]);
}
