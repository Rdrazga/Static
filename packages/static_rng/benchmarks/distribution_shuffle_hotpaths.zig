//! `static_rng` distribution and shuffle hot-path benchmarks.

const std = @import("std");
const assert = std.debug.assert;
const static_rng = @import("static_rng");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 262_144,
    .sample_count = 16,
};

const HotPathOp = enum {
    uint_below_small_bound,
    uint_below_large_bound,
    f64_unit,
    shuffle_slice_256_u32,
};

const HotPathContext = struct {
    name: []const u8,
    op: HotPathOp,
    rng: static_rng.Pcg32 = static_rng.Pcg32.init(0x6e47_6e61_7469_2001, 0x6e47_6e61_7469_2002),
    values: [256]u32 = initValues(),
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *HotPathContext = @ptrCast(@alignCast(context_ptr));
        assert(context.name.len > 0);
        assert((context.rng.inc & 1) == 1);

        switch (context.op) {
            .uint_below_small_bound => {
                const value = static_rng.distributions.uintBelow(&context.rng, 17) catch unreachable;
                const consumed = bench.case.blackBox(@as(u64, value));
                context.sink +%= consumed | 1;
                assert(value < 17);
            },
            .uint_below_large_bound => {
                const value = static_rng.distributions.uintBelow(&context.rng, 1_000_000_007) catch unreachable;
                const consumed = bench.case.blackBox(@as(u64, value));
                context.sink +%= consumed | 1;
                assert(value < 1_000_000_007);
            },
            .f64_unit => {
                const value = static_rng.distributions.f64Unit(&context.rng);
                const scaled = @as(u64, @intFromFloat(value * 1_000_000_000.0)) | 1;
                const consumed = bench.case.blackBox(scaled);
                context.sink +%= consumed | 1;
                assert(value >= 0.0);
                assert(value < 1.0);
            },
            .shuffle_slice_256_u32 => {
                static_rng.shuffleSlice(&context.rng, context.values[0..]) catch unreachable;
                const consumed = bench.case.blackBox(@as(u64, context.values[0]) | @as(u64, context.values[255]));
                context.sink +%= consumed | 1;
                assert(context.values[0] < context.values.len);
                assert(context.values[255] < context.values.len);
            },
        }

        assert(context.sink != 0);
        assert((context.rng.inc & 1) == 1);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "distribution_shuffle_hotpaths");
    defer output_dir.close(io);

    var contexts = [_]HotPathContext{
        .{
            .name = "uint_below_small_bound",
            .op = .uint_below_small_bound,
        },
        .{
            .name = "uint_below_large_bound",
            .op = .uint_below_large_bound,
        },
        .{
            .name = "f64_unit",
            .op = .f64_unit,
        },
        .{
            .name = "shuffle_slice_256_u32",
            .op = .shuffle_slice_256_u32,
        },
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_rng_distribution_shuffle_hotpaths",
        .config = bench_config,
    });

    inline for (&contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_rng", "distribution", "shuffle", "baseline" },
            .context = context,
            .run_fn = HotPathContext.run,
        }));
    }

    var sample_storage: [contexts.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [contexts.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_rng distribution and shuffle hot paths ==\n", .{});
    try support.writeGroupReport(
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight() void {
    var small_a = static_rng.Pcg32.init(0x6e47_6e61_7469_2003, 0x6e47_6e61_7469_2004);
    var small_b = static_rng.Pcg32.init(0x6e47_6e61_7469_2003, 0x6e47_6e61_7469_2004);
    const small_value_a = static_rng.distributions.uintBelow(&small_a, 17) catch unreachable;
    const small_value_b = static_rng.distributions.uintBelow(&small_b, 17) catch unreachable;
    assert(small_value_a == small_value_b);
    assert(small_value_a < 17);

    var large_rng = static_rng.Pcg32.init(0x6e47_6e61_7469_2005, 0x6e47_6e61_7469_2006);
    const large_value = static_rng.distributions.uintBelow(&large_rng, 1_000_000_007) catch unreachable;
    assert(large_value < 1_000_000_007);

    var float_rng = static_rng.Pcg32.init(0x6e47_6e61_7469_2007, 0x6e47_6e61_7469_2008);
    const unit = static_rng.distributions.f64Unit(&float_rng);
    assert(unit >= 0.0);
    assert(unit < 1.0);

    var shuffle_a = static_rng.Pcg32.init(0x6e47_6e61_7469_2005, 0x6e47_6e61_7469_2006);
    var shuffle_b = static_rng.Pcg32.init(0x6e47_6e61_7469_2005, 0x6e47_6e61_7469_2006);
    var values_a = initValues();
    var values_b = initValues();
    static_rng.shuffleSlice(&shuffle_a, values_a[0..]) catch unreachable;
    static_rng.shuffleSlice(&shuffle_b, values_b[0..]) catch unreachable;
    assert(std.mem.eql(u32, values_a[0..], values_b[0..]));
    assert(isPermutation(values_a[0..]));
}

fn initValues() [256]u32 {
    var values: [256]u32 = undefined;
    for (&values, 0..) |*value, index| {
        value.* = @as(u32, @intCast(index));
    }
    return values;
}

fn isPermutation(values: []const u32) bool {
    assert(values.len == 256);

    var seen: [256]bool = [_]bool{false} ** 256;
    for (values) |value| {
        if (value >= seen.len) return false;
        if (seen[value]) return false;
        seen[value] = true;
    }

    for (seen) |flag| {
        if (!flag) return false;
    }
    return true;
}
