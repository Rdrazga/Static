//! Bounded benchmark group registry with stable iteration order.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const config_mod = @import("config.zig");
const case_mod = @import("case.zig");

/// Operating errors surfaced by fixed-capacity benchmark groups.
pub const BenchmarkGroupError = error{
    NoSpaceLeft,
    AlreadyExists,
    InvalidConfig,
    Overflow,
};

/// Options for initializing a benchmark group.
pub const BenchmarkGroupInitOptions = struct {
    name: []const u8,
    config: config_mod.BenchmarkConfig,
};

/// Fixed-capacity benchmark case registry with stable insertion order.
pub const BenchmarkGroup = struct {
    name: []const u8,
    config: config_mod.BenchmarkConfig,
    storage: []case_mod.BenchmarkCase,
    case_count: usize = 0,

    /// Initialize a group over caller-provided case storage.
    pub fn init(
        storage: []case_mod.BenchmarkCase,
        options: BenchmarkGroupInitOptions,
    ) BenchmarkGroupError!BenchmarkGroup {
        assert(options.name.len > 0);
        if (storage.len == 0) return error.InvalidConfig;

        config_mod.validateConfig(options.config) catch |err| return switch (err) {
            error.InvalidConfig => error.InvalidConfig,
            error.Overflow => error.Overflow,
        };

        return .{
            .name = options.name,
            .config = options.config,
            .storage = storage,
        };
    }

    /// Append one case while preserving insertion order.
    pub fn addCase(self: *BenchmarkGroup, benchmark_case: case_mod.BenchmarkCase) BenchmarkGroupError!void {
        assert(benchmark_case.name.len > 0);
        if (self.findCase(benchmark_case.name) != null) return error.AlreadyExists;
        if (self.case_count >= self.storage.len) return error.NoSpaceLeft;

        self.storage[self.case_count] = benchmark_case;
        self.case_count += 1;
        assert(self.case_count <= self.storage.len);
    }

    /// Look up one case by name.
    pub fn findCase(self: *const BenchmarkGroup, name: []const u8) ?*const case_mod.BenchmarkCase {
        assert(name.len > 0);
        for (self.iter()) |*benchmark_case| {
            if (std.mem.eql(u8, benchmark_case.name, name)) return benchmark_case;
        }
        return null;
    }

    /// Return the first case carrying the requested tag.
    pub fn findFirstByTag(self: *const BenchmarkGroup, tag: []const u8) ?*const case_mod.BenchmarkCase {
        assert(tag.len > 0);
        for (self.iter()) |*benchmark_case| {
            if (caseHasTag(benchmark_case.*, tag)) return benchmark_case;
        }
        return null;
    }

    /// Iterate over the active case slice in insertion order.
    pub fn iter(self: *const BenchmarkGroup) []const case_mod.BenchmarkCase {
        assert(self.case_count <= self.storage.len);
        return self.storage[0..self.case_count];
    }
};

fn caseHasTag(benchmark_case: case_mod.BenchmarkCase, tag: []const u8) bool {
    for (benchmark_case.tags) |candidate| {
        if (std.mem.eql(u8, candidate, tag)) return true;
    }
    return false;
}

test "benchmark group add and find preserve order" {
    var group_storage: [2]case_mod.BenchmarkCase = undefined;
    var context_value: u32 = 0;
    const Context = struct {
        fn run(ctx: *anyopaque) void {
            const value: *u32 = @ptrCast(@alignCast(ctx));
            value.* += 1;
        }
    };
    const first_case = case_mod.BenchmarkCase.init(.{
        .name = "first",
        .context = &context_value,
        .run_fn = Context.run,
    });
    const second_case = case_mod.BenchmarkCase.init(.{
        .name = "second",
        .tags = &[_][]const u8{"tagged"},
        .context = &context_value,
        .run_fn = Context.run,
    });

    var group = try BenchmarkGroup.init(&group_storage, .{
        .name = "smoke_group",
        .config = config_mod.BenchmarkConfig.smokeDefaults(),
    });
    try group.addCase(first_case);
    try group.addCase(second_case);

    try testing.expectEqualStrings("first", group.iter()[0].name);
    try testing.expectEqualStrings("second", group.iter()[1].name);
    try testing.expect(group.findCase("second") != null);
    try testing.expect(group.findFirstByTag("tagged") != null);
}

test "benchmark group rejects duplicate names and capacity overflow" {
    var group_storage: [1]case_mod.BenchmarkCase = undefined;
    var context_value: u32 = 0;
    const Context = struct {
        fn run(ctx: *anyopaque) void {
            const value: *u32 = @ptrCast(@alignCast(ctx));
            value.* += 1;
        }
    };
    const benchmark_case = case_mod.BenchmarkCase.init(.{
        .name = "only",
        .context = &context_value,
        .run_fn = Context.run,
    });

    var group = try BenchmarkGroup.init(&group_storage, .{
        .name = "single",
        .config = config_mod.BenchmarkConfig.smokeDefaults(),
    });
    try group.addCase(benchmark_case);
    try testing.expectError(error.AlreadyExists, group.addCase(benchmark_case));
    try testing.expectEqual(@as(usize, 1), group.iter().len);
}
