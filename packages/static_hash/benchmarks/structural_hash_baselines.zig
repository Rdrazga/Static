//! `static_hash` structural hashing overhead benchmark.
//!
//! This benchmark focuses on package-owned behavior:
//! - `hash_any` versus its direct byte-path lower bound on a simple value;
//! - `stableHashAny` versus a precomputed canonical-byte lower bound; and
//! - padded and slice-backed structural values that force the package-specific
//!   walking logic.

const builtin = @import("builtin");
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

const SimpleKey = struct {
    left: u32,
    right: u32,
};

const PaddedKey = struct {
    tag: u8,
    value: u32,
};

const SliceKey = struct {
    bytes: []const u8,
    flag: bool,
};

const CaseOp = enum {
    hash_any_simple,
    hash_any_simple_lower_bound,
    stable_simple,
    stable_simple_lower_bound,
    hash_any_padded,
    stable_padded,
    hash_any_slice,
    stable_slice,
};

const StructuralBenchContext = struct {
    name: []const u8,
    op: CaseOp,
    simple: SimpleKey = .{ .left = 0, .right = 0 },
    padded: PaddedKey = .{ .tag = 0, .value = 0 },
    slice: SliceKey = .{ .bytes = &.{}, .flag = false },
    stable_simple_bytes: []const u8 = &.{},
    seed: u64 = 0,
    sink_u64: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *StructuralBenchContext = @ptrCast(@alignCast(context_ptr));
        switch (context.op) {
            .hash_any_simple => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.hashAnySeeded(context.seed, context.simple),
                );
            },
            .hash_any_simple_lower_bound => {
                context.sink_u64 = bench.case.blackBox(
                    std.hash.Wyhash.hash(context.seed, std.mem.asBytes(&context.simple)),
                );
            },
            .stable_simple => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.stableHashAnySeeded(context.seed, context.simple),
                );
            },
            .stable_simple_lower_bound => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.stable.stableFingerprint64(context.stable_simple_bytes),
                );
            },
            .hash_any_padded => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.hashAnySeeded(context.seed, context.padded),
                );
            },
            .stable_padded => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.stableHashAnySeeded(context.seed, context.padded),
                );
            },
            .hash_any_slice => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.hashAnySeeded(context.seed, context.slice),
                );
            },
            .stable_slice => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.stableHashAnySeeded(context.seed, context.slice),
                );
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
    var output_dir = try support.openOutputDir(io, "structural_hash_baselines");
    defer output_dir.close(io);

    var stable_simple_storage: [34]u8 = undefined;
    const simple: SimpleKey = .{
        .left = 0x0102_0304,
        .right = 0x1122_3344,
    };
    const stable_simple_bytes = encodeStableSimpleKey(&stable_simple_storage, 0, simple);

    const padded = makePaddedKey(0xaa, 7, 0x4455_6677);
    const slice_storage = [_]u8{ 1, 4, 9, 16, 25, 36, 49, 64 };
    const slice = SliceKey{
        .bytes = slice_storage[0..],
        .flag = true,
    };

    validateSemanticPreflight(simple, stable_simple_bytes, padded, slice);

    var contexts = [_]StructuralBenchContext{
        .{
            .name = "hash_any_simple_seeded",
            .op = .hash_any_simple,
            .simple = simple,
            .seed = 0x3344_5566_7788_9900,
        },
        .{
            .name = "hash_any_simple_lower_bound_bytes",
            .op = .hash_any_simple_lower_bound,
            .simple = simple,
            .seed = 0x3344_5566_7788_9900,
        },
        .{
            .name = "stable_simple_seeded",
            .op = .stable_simple,
            .simple = simple,
            .seed = 0,
        },
        .{
            .name = "stable_simple_lower_bound_canonical_bytes",
            .op = .stable_simple_lower_bound,
            .stable_simple_bytes = stable_simple_bytes,
        },
        .{
            .name = "hash_any_padded_structural",
            .op = .hash_any_padded,
            .padded = padded,
            .seed = 0x7788_99aa_bbcc_ddee,
        },
        .{
            .name = "stable_padded_structural",
            .op = .stable_padded,
            .padded = padded,
            .seed = 0,
        },
        .{
            .name = "hash_any_slice_structural",
            .op = .hash_any_slice,
            .slice = slice,
            .seed = 0x1020_3040_5060_7080,
        },
        .{
            .name = "stable_slice_structural",
            .op = .stable_slice,
            .slice = slice,
            .seed = 0,
        },
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_hash_structural_baselines",
        .config = bench_config,
    });

    inline for (&contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_hash", "structural", "baseline" },
            .context = context,
            .run_fn = StructuralBenchContext.run,
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

    std.debug.print("== static_hash structural baselines ==\n", .{});
    var report_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer report_writer.deinit();
    _ = try support.writeReport(
        &report_writer.writer,
        run_result,
        io,
        output_dir,
        "structural_hash_baselines",
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
    );
    var out = report_writer.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{out.items});
}

fn validateSemanticPreflight(
    simple: SimpleKey,
    stable_simple_bytes: []const u8,
    padded: PaddedKey,
    slice: SliceKey,
) void {
    assert(static_hash.hashAnySeeded(0x3344_5566_7788_9900, simple) == std.hash.Wyhash.hash(0x3344_5566_7788_9900, std.mem.asBytes(&simple)));
    assert(static_hash.stableHashAny(simple) == static_hash.stable.stableFingerprint64(stable_simple_bytes));

    const padded_alt = makePaddedKey(0x55, padded.tag, padded.value);
    assert(std.meta.eql(padded, padded_alt));
    assert(static_hash.hashAnySeeded(0x7788_99aa_bbcc_ddee, padded) == static_hash.hashAnySeeded(0x7788_99aa_bbcc_ddee, padded_alt));
    assert(static_hash.stableHashAny(padded) == static_hash.stableHashAny(padded_alt));

    const slice_copy_storage = [_]u8{ 1, 4, 9, 16, 25, 36, 49, 64 };
    const slice_copy = SliceKey{
        .bytes = slice_copy_storage[0..],
        .flag = slice.flag,
    };
    assert(static_hash.hashAnySeeded(0x1020_3040_5060_7080, slice) == static_hash.hashAnySeeded(0x1020_3040_5060_7080, slice_copy));
    assert(
        static_hash.hash_any.hashAnySeededStrict(0x1020_3040_5060_7080, slice) ==
            static_hash.hash_any.hashAnySeededStrict(0x1020_3040_5060_7080, slice_copy),
    );
    assert(static_hash.stableHashAny(slice) == static_hash.stableHashAny(slice_copy));

    var hash_budget = static_hash.HashBudget.unlimited();
    assert(
        static_hash.hashAny(slice) ==
            static_hash.hashAnyBudgeted(slice, &hash_budget) catch unreachable,
    );

    var stable_budget = static_hash.HashBudget.unlimited();
    assert(
        static_hash.stableHashAny(slice) ==
            static_hash.stable.stableHashAnyBudgeted(slice, &stable_budget) catch unreachable,
    );
}

fn makePaddedKey(pattern: u8, tag: u8, value: u32) PaddedKey {
    var bytes: [@sizeOf(PaddedKey)]u8 = undefined;
    @memset(bytes[0..], pattern);
    bytes[@offsetOf(PaddedKey, "tag")] = tag;
    std.mem.writeInt(
        u32,
        bytes[@offsetOf(PaddedKey, "value")..][0..4],
        value,
        builtin.cpu.arch.endian(),
    );

    var key: PaddedKey = undefined;
    @memcpy(std.mem.asBytes(&key), bytes[0..]);
    return key;
}

fn encodeStableSimpleKey(storage: []u8, seed: u64, simple: SimpleKey) []const u8 {
    assert(storage.len >= 34);
    var index: usize = 0;
    storage[index] = 0x00;
    index += 1;
    std.mem.writeInt(u64, storage[index..][0..8], seed, .little);
    index += 8;
    storage[index] = 0x0C;
    index += 1;
    std.mem.writeInt(u64, storage[index..][0..8], 2, .little);
    index += 8;
    storage[index] = 0x02;
    index += 1;
    storage[index] = 0;
    index += 1;
    std.mem.writeInt(u16, storage[index..][0..2], 32, .little);
    index += 2;
    std.mem.writeInt(u32, storage[index..][0..4], simple.left, .little);
    index += 4;
    storage[index] = 0x02;
    index += 1;
    storage[index] = 0;
    index += 1;
    std.mem.writeInt(u16, storage[index..][0..2], 32, .little);
    index += 2;
    std.mem.writeInt(u32, storage[index..][0..4], simple.right, .little);
    index += 4;
    assert(index == 34);
    return storage[0..index];
}
