//! `static_hash` combiner overhead benchmark.
//!
//! This benchmark keeps the scope narrow:
//! - ordered and unordered pair combiners are measured directly;
//! - ordered and multiset folds are measured at two small representative sizes; and
//! - trivial fold lower bounds are kept beside the package-owned combiners to
//!   make the abstraction cost explicit.

const std = @import("std");
const assert = std.debug.assert;
const static_hash = @import("static_hash");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 8,
    .measure_iterations = 2048,
    .sample_count = 8,
};

const CaseOp = enum {
    ordered_pair,
    unordered_pair,
    ordered_fold_4,
    ordered_fold_16,
    multiset_fold_4,
    multiset_fold_16,
    xor_fold_4,
    xor_fold_16,
};

const CombineBenchContext = struct {
    name: []const u8,
    op: CaseOp,
    pair: static_hash.Pair64 = .{ .left = 0, .right = 0 },
    values: []const u64 = &.{},
    sink_u64: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *CombineBenchContext = @ptrCast(@alignCast(context_ptr));
        switch (context.op) {
            .ordered_pair => {
                context.sink_u64 = bench.case.blackBox(static_hash.combineOrdered64(context.pair));
            },
            .unordered_pair => {
                context.sink_u64 = bench.case.blackBox(static_hash.combineUnordered64(context.pair));
            },
            .ordered_fold_4, .ordered_fold_16 => {
                context.sink_u64 = bench.case.blackBox(foldOrdered(context.values));
            },
            .multiset_fold_4, .multiset_fold_16 => {
                context.sink_u64 = bench.case.blackBox(foldUnorderedMultiset(context.values));
            },
            .xor_fold_4, .xor_fold_16 => {
                context.sink_u64 = bench.case.blackBox(foldXor(context.values));
            },
        }
    }
};

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "combine_baselines");
    defer output_dir.close(io);

    const pair: static_hash.Pair64 = .{
        .left = 0x0123_4567_89ab_cdef,
        .right = 0xfedc_ba98_7654_3210,
    };
    const four_values = [_]u64{
        0x0102_0304_0506_0708,
        0x1112_1314_1516_1718,
        0x2122_2324_2526_2728,
        0x3132_3334_3536_3738,
    };
    const sixteen_values = [_]u64{
        0x0001_0002_0003_0004,
        0x1001_1002_1003_1004,
        0x2001_2002_2003_2004,
        0x3001_3002_3003_3004,
        0x4001_4002_4003_4004,
        0x5001_5002_5003_5004,
        0x6001_6002_6003_6004,
        0x7001_7002_7003_7004,
        0x8001_8002_8003_8004,
        0x9001_9002_9003_9004,
        0xa001_a002_a003_a004,
        0xb001_b002_b003_b004,
        0xc001_c002_c003_c004,
        0xd001_d002_d003_d004,
        0xe001_e002_e003_e004,
        0xf001_f002_f003_f004,
    };

    validateSemanticPreflight(pair, four_values[0..], sixteen_values[0..]);

    var contexts = [_]CombineBenchContext{
        .{
            .name = "combine_ordered_pair",
            .op = .ordered_pair,
            .pair = pair,
        },
        .{
            .name = "combine_unordered_pair",
            .op = .unordered_pair,
            .pair = pair,
        },
        .{
            .name = "combine_ordered_fold_4",
            .op = .ordered_fold_4,
            .values = four_values[0..],
        },
        .{
            .name = "combine_ordered_fold_16",
            .op = .ordered_fold_16,
            .values = sixteen_values[0..],
        },
        .{
            .name = "combine_multiset_fold_4",
            .op = .multiset_fold_4,
            .values = four_values[0..],
        },
        .{
            .name = "combine_multiset_fold_16",
            .op = .multiset_fold_16,
            .values = sixteen_values[0..],
        },
        .{
            .name = "combine_xor_fold_4_lower_bound",
            .op = .xor_fold_4,
            .values = four_values[0..],
        },
        .{
            .name = "combine_xor_fold_16_lower_bound",
            .op = .xor_fold_16,
            .values = sixteen_values[0..],
        },
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_hash_combine_baselines",
        .config = bench_config,
    });

    inline for (&contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_hash", "combine", "baseline" },
            .context = context,
            .run_fn = CombineBenchContext.run,
        }));
    }

    var sample_storage: [contexts.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [contexts.len]bench.runner.BenchmarkCaseResult = undefined;
    var stats_storage: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [8192]u8 = undefined;
    var read_source_buffer: [8192]u8 = undefined;
    var read_parse_buffer: [16 * 1024]u8 = undefined;
    var comparison_storage: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [64 * 1024]u8 = undefined;
    var history_record_buffer: [16 * 1024]u8 = undefined;
    var history_frame_buffer: [16 * 1024]u8 = undefined;
    var history_output_buffer: [64 * 1024]u8 = undefined;
    var history_file_buffer: [64 * 1024]u8 = undefined;
    var history_cases: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var history_names: [2048]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_hash combine baselines ==\n", .{});
    var report_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer report_writer.deinit();
    _ = try support.writeReport(
        &report_writer.writer,
        run_result,
        io,
        output_dir,
        "combine_baselines",
        .{
            .stats_storage = &stats_storage,
            .baseline_document_buffer = &baseline_document_buffer,
            .read_source_buffer = &read_source_buffer,
            .read_parse_buffer = &read_parse_buffer,
            .comparison_storage = &comparison_storage,
        },
        .record_if_missing_then_compare,
        support.default_compare_config,
        false,
        .{
            .sub_path = "history.binlog",
            .package_name = "static_hash",
            .environment_note = support.default_environment_note,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_names,
                .tag_storage = &history_tags,
            },
            .comparison_storage = &history_comparisons,
        },
        .{},
    );
    var out = report_writer.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{out.items});
}

fn validateSemanticPreflight(
    pair: static_hash.Pair64,
    four_values: []const u64,
    sixteen_values: []const u64,
) void {
    if (!std.debug.runtime_safety) return;

    assert(
        static_hash.combineOrdered64(pair) !=
            static_hash.combineOrdered64(.{ .left = pair.right, .right = pair.left }),
    );
    assert(
        static_hash.combineUnordered64(pair) ==
            static_hash.combineUnordered64(.{ .left = pair.right, .right = pair.left }),
    );
    assert(
        foldUnorderedMultiset(four_values) ==
            foldUnorderedMultisetReverse(four_values),
    );
    assert(
        foldUnorderedMultiset(sixteen_values) ==
            foldUnorderedMultisetReverse(sixteen_values),
    );
    assert(
        static_hash.combineUnorderedMultiset64(
            foldUnorderedMultiset(four_values),
            four_values[0],
        ) != foldUnorderedMultiset(four_values),
    );
}

fn foldOrdered(values: []const u64) u64 {
    assert(values.len != 0);
    var acc = values[0];
    for (values[1..]) |value| {
        acc = static_hash.combineOrdered64(.{
            .left = acc,
            .right = value,
        });
    }
    return acc;
}

fn foldUnorderedMultiset(values: []const u64) u64 {
    var acc: u64 = 0;
    for (values) |value| {
        acc = static_hash.combineUnorderedMultiset64(acc, value);
    }
    return acc;
}

fn foldUnorderedMultisetReverse(values: []const u64) u64 {
    var acc: u64 = 0;
    var index = values.len;
    while (index > 0) {
        index -= 1;
        acc = static_hash.combineUnorderedMultiset64(acc, values[index]);
    }
    return acc;
}

fn foldXor(values: []const u64) u64 {
    var acc: u64 = 0;
    for (values) |value| {
        acc ^= value;
    }
    return acc;
}
