//! `static_hash` fingerprint overhead benchmark.
//!
//! This benchmark focuses on package-owned fingerprint behavior:
//! - `fingerprint64` and `fingerprint64Seeded` beside direct Wyhash baselines;
//! - `fingerprint128` beside its two-hash lower bound; and
//! - `Fingerprint64V1` whole, chunked, and `addU64` paths beside the raw
//!   FNV-1a and direct-combine lower bounds that define its implementation.

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

const v1_add_value: u64 = 0x0123_4567_89ab_cdef;
const fp128_seed_a: u64 = 0x0f1e_2d3c_4b5a_6978;
const fp128_seed_b: u64 = 0x89ab_cdef_0123_4567;

const CaseOp = enum {
    fingerprint64,
    fingerprint64_std,
    fingerprint64_seeded,
    fingerprint64_seeded_std,
    fingerprint128,
    fingerprint128_lower_bound,
    fingerprint_v1_whole,
    fingerprint_v1_chunked,
    fingerprint_v1_lower_bound,
    fingerprint_v1_add_u64,
    fingerprint_v1_add_u64_lower_bound,
};

const FingerprintBenchContext = struct {
    name: []const u8,
    op: CaseOp,
    payload: []const u8,
    seed: u64 = 0,
    seed_b: u64 = 0,
    add_value: u64 = 0,
    sink_u64: u64 = 0,
    sink_u128: u128 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *FingerprintBenchContext = @ptrCast(@alignCast(context_ptr));
        switch (context.op) {
            .fingerprint64 => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.fingerprint64(context.payload),
                );
            },
            .fingerprint64_std => {
                context.sink_u64 = bench.case.blackBox(
                    std.hash.Wyhash.hash(0, context.payload),
                );
            },
            .fingerprint64_seeded => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.fingerprint64Seeded(context.seed, context.payload),
                );
            },
            .fingerprint64_seeded_std => {
                context.sink_u64 = bench.case.blackBox(
                    std.hash.Wyhash.hash(context.seed, context.payload),
                );
            },
            .fingerprint128 => {
                context.sink_u128 = bench.case.blackBox(
                    static_hash.fingerprint.fingerprint128Seeded(
                        context.seed,
                        context.seed_b,
                        context.payload,
                    ),
                );
            },
            .fingerprint128_lower_bound => {
                context.sink_u128 = bench.case.blackBox(
                    directFingerprint128LowerBound(
                        context.seed,
                        context.seed_b,
                        context.payload,
                    ),
                );
            },
            .fingerprint_v1_whole => {
                var fp = static_hash.fingerprint.Fingerprint64V1.init();
                fp.update(context.payload);
                context.sink_u64 = bench.case.blackBox(fp.final());
            },
            .fingerprint_v1_chunked => {
                var fp = static_hash.fingerprint.Fingerprint64V1.init();
                updateInFixedChunks(&fp, context.payload, 17);
                context.sink_u64 = bench.case.blackBox(fp.final());
            },
            .fingerprint_v1_lower_bound => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.fnv1a.hash64(0, context.payload),
                );
            },
            .fingerprint_v1_add_u64 => {
                var fp = static_hash.fingerprint.Fingerprint64V1.init();
                fp.update(context.payload);
                fp.addU64(context.add_value);
                context.sink_u64 = bench.case.blackBox(fp.final());
            },
            .fingerprint_v1_add_u64_lower_bound => {
                const base = static_hash.fnv1a.hash64(0, context.payload);
                context.sink_u64 = bench.case.blackBox(
                    static_hash.combineOrdered64(.{
                        .left = base,
                        .right = context.add_value,
                    }),
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
    var output_dir = try support.openOutputDir(io, "fingerprint_baselines");
    defer output_dir.close(io);

    var zero_256: [256]u8 = undefined;
    var incrementing_512: [512]u8 = undefined;
    var random_512: [512]u8 = undefined;
    @memset(zero_256[0..], 0);
    fillIncrementing(incrementing_512[0..]);
    fillPseudoRandom(random_512[0..], 0x17b4_2026_0000_2001);

    validateSemanticPreflight(
        zero_256[0..64],
        incrementing_512[0..256],
        random_512[0..512],
    );

    var contexts = [_]FingerprintBenchContext{
        .{
            .name = "fingerprint64_len64_zero",
            .op = .fingerprint64,
            .payload = zero_256[0..64],
        },
        .{
            .name = "fingerprint64_std_len64_zero",
            .op = .fingerprint64_std,
            .payload = zero_256[0..64],
        },
        .{
            .name = "fingerprint64_seeded_len512_random",
            .op = .fingerprint64_seeded,
            .payload = random_512[0..],
            .seed = 0x1020_3040_5060_7080,
        },
        .{
            .name = "fingerprint64_seeded_std_len512_random",
            .op = .fingerprint64_seeded_std,
            .payload = random_512[0..],
            .seed = 0x1020_3040_5060_7080,
        },
        .{
            .name = "fingerprint128_len512_random",
            .op = .fingerprint128,
            .payload = random_512[0..],
            .seed = fp128_seed_a,
            .seed_b = fp128_seed_b,
        },
        .{
            .name = "fingerprint128_two_wyhash_lower_bound_len512_random",
            .op = .fingerprint128_lower_bound,
            .payload = random_512[0..],
            .seed = fp128_seed_a,
            .seed_b = fp128_seed_b,
        },
        .{
            .name = "fingerprint_v1_whole_len256_inc",
            .op = .fingerprint_v1_whole,
            .payload = incrementing_512[0..256],
        },
        .{
            .name = "fingerprint_v1_chunked_len256_inc",
            .op = .fingerprint_v1_chunked,
            .payload = incrementing_512[0..256],
        },
        .{
            .name = "fingerprint_v1_fnv_lower_bound_len256_inc",
            .op = .fingerprint_v1_lower_bound,
            .payload = incrementing_512[0..256],
        },
        .{
            .name = "fingerprint_v1_add_u64_len256_inc",
            .op = .fingerprint_v1_add_u64,
            .payload = incrementing_512[0..256],
            .add_value = v1_add_value,
        },
        .{
            .name = "fingerprint_v1_add_u64_lower_bound_len256_inc",
            .op = .fingerprint_v1_add_u64_lower_bound,
            .payload = incrementing_512[0..256],
            .add_value = v1_add_value,
        },
    };

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_hash_fingerprint_baselines",
        .config = bench_config,
    });

    inline for (&contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_hash", "fingerprint", "baseline" },
            .context = context,
            .run_fn = FingerprintBenchContext.run,
        }));
    }

    var sample_storage: [contexts.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [contexts.len]bench.runner.BenchmarkCaseResult = undefined;
    var stats_storage: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [16 * 1024]u8 = undefined;
    var read_source_buffer: [16 * 1024]u8 = undefined;
    var read_parse_buffer: [64 * 1024]u8 = undefined;
    var comparison_storage: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [64 * 1024]u8 = undefined;
    var history_record_buffer: [32 * 1024]u8 = undefined;
    var history_frame_buffer: [32 * 1024]u8 = undefined;
    var history_output_buffer: [64 * 1024]u8 = undefined;
    var history_file_buffer: [64 * 1024]u8 = undefined;
    var history_cases: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var history_names: [4096]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_hash fingerprint baselines ==\n", .{});
    var report_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer report_writer.deinit();
    _ = try support.writeReport(
        &report_writer.writer,
        run_result,
        io,
        output_dir,
        "fingerprint_baselines",
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
    zero_payload: []const u8,
    incrementing_payload: []const u8,
    random_payload: []const u8,
) void {
    if (!std.debug.runtime_safety) return;

    assert(
        static_hash.fingerprint64(zero_payload) ==
            std.hash.Wyhash.hash(0, zero_payload),
    );
    assert(
        static_hash.fingerprint64Seeded(0x1020_3040_5060_7080, random_payload) ==
            std.hash.Wyhash.hash(0x1020_3040_5060_7080, random_payload),
    );
    assert(
        static_hash.fingerprint.fingerprint128Seeded(fp128_seed_a, fp128_seed_b, random_payload) ==
            directFingerprint128LowerBound(fp128_seed_a, fp128_seed_b, random_payload),
    );

    var fp_whole = static_hash.fingerprint.Fingerprint64V1.init();
    fp_whole.update(incrementing_payload);

    var fp_chunked = static_hash.fingerprint.Fingerprint64V1.init();
    updateInFixedChunks(&fp_chunked, incrementing_payload, 17);

    assert(fp_whole.final() == fp_chunked.final());
    assert(
        fp_whole.final() ==
            static_hash.fnv1a.hash64(0, incrementing_payload),
    );

    var fp_add = static_hash.fingerprint.Fingerprint64V1.init();
    fp_add.update(incrementing_payload);
    fp_add.addU64(v1_add_value);
    assert(
        fp_add.final() ==
            static_hash.combineOrdered64(.{
                .left = static_hash.fnv1a.hash64(0, incrementing_payload),
                .right = v1_add_value,
            }),
    );
}

fn directFingerprint128LowerBound(seed_a: u64, seed_b: u64, payload: []const u8) u128 {
    const low = std.hash.Wyhash.hash(seed_a, payload);
    const high = std.hash.Wyhash.hash(seed_b, payload);
    return (@as(u128, high) << 64) | low;
}

fn updateInFixedChunks(
    fp: *static_hash.fingerprint.Fingerprint64V1,
    payload: []const u8,
    chunk_len: usize,
) void {
    assert(chunk_len != 0);
    var index: usize = 0;
    while (index < payload.len) {
        const end = @min(index + chunk_len, payload.len);
        fp.update(payload[index..end]);
        index = end;
    }
}

fn fillIncrementing(bytes: []u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* = @truncate(index);
    }
}

fn fillPseudoRandom(bytes: []u8, seed_value: u64) void {
    var prng = std.Random.DefaultPrng.init(seed_value);
    prng.random().bytes(bytes);
}
