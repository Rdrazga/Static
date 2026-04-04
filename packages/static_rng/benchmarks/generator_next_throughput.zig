//! `static_rng` generator throughput benchmarks.

const std = @import("std");
const static_rng = @import("static_rng");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 64,
    .measure_iterations = 1_048_576,
    .sample_count = 16,
};

const ThroughputOp = enum {
    pcg32_next_u32,
    pcg32_next_u64,
    xoroshiro128plus_next_u64,
};

const ThroughputContext = struct {
    name: []const u8,
    op: ThroughputOp,
    pcg: static_rng.Pcg32 = static_rng.Pcg32.init(0x6e47_6e61_7469_0001, 0x6e47_6e61_7469_0002),
    xoroshiro: static_rng.Xoroshiro128Plus = static_rng.Xoroshiro128Plus.init(0x6e47_6e61_7469_0003),
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *ThroughputContext = @ptrCast(@alignCast(context_ptr));
        std.debug.assert(context.name.len > 0);
        std.debug.assert((context.pcg.inc & 1) == 1);
        std.debug.assert(context.xoroshiro.s0 != 0 or context.xoroshiro.s1 != 0);

        const value = switch (context.op) {
            .pcg32_next_u32 => @as(u64, context.pcg.nextU32()),
            .pcg32_next_u64 => context.pcg.nextU64(),
            .xoroshiro128plus_next_u64 => context.xoroshiro.nextU64(),
        };
        const consumed = bench.case.blackBox(value);
        context.sink +%= consumed | 1;
        std.debug.assert(context.sink != 0);
        std.debug.assert((context.pcg.inc & 1) == 1);
        std.debug.assert(context.xoroshiro.s0 != 0 or context.xoroshiro.s1 != 0);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "generator_next_throughput");
    defer output_dir.close(io);

    var contexts = [_]ThroughputContext{
        .{
            .name = "pcg32_next_u32",
            .op = .pcg32_next_u32,
        },
        .{
            .name = "pcg32_next_u64",
            .op = .pcg32_next_u64,
        },
        .{
            .name = "xoroshiro128plus_next_u64",
            .op = .xoroshiro128plus_next_u64,
        },
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_rng_generator_next_throughput",
        .config = bench_config,
    });

    inline for (&contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_rng", "generator", "throughput", "baseline" },
            .context = context,
            .run_fn = ThroughputContext.run,
        }));
    }

    var sample_storage: [contexts.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [contexts.len]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_rng generator next throughput ==\n", .{});
    try support.writeGroupReport(
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight() void {
    var pcg_a = static_rng.Pcg32.init(0x6e47_6e61_7469_1001, 0x6e47_6e61_7469_1002);
    var pcg_b = static_rng.Pcg32.init(0x6e47_6e61_7469_1001, 0x6e47_6e61_7469_1002);
    std.debug.assert(pcg_a.nextU32() == pcg_b.nextU32());
    std.debug.assert(pcg_a.nextU64() == pcg_b.nextU64());

    var xoroshiro_a = static_rng.Xoroshiro128Plus.init(0x6e47_6e61_7469_1003);
    var xoroshiro_b = static_rng.Xoroshiro128Plus.init(0x6e47_6e61_7469_1003);
    std.debug.assert(xoroshiro_a.nextU64() == xoroshiro_b.nextU64());
    std.debug.assert(xoroshiro_a.nextU64() == xoroshiro_b.nextU64());

    var parent_a = static_rng.Xoroshiro128Plus.init(0x6e47_6e61_7469_1004);
    var parent_b = static_rng.Xoroshiro128Plus.init(0x6e47_6e61_7469_1004);
    const child_a = parent_a.split();
    const child_b = parent_b.split();
    std.debug.assert(child_a.s0 == child_b.s0);
    std.debug.assert(child_a.s1 == child_b.s1);
}
