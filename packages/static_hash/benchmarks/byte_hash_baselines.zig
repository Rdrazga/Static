//! `static_hash` byte-hash throughput and baseline comparison benchmark.
//!
//! This benchmark keeps the scope narrow:
//! - wrapper algorithms are measured beside their direct Zig std/crypto
//!   implementation baselines;
//! - semantic equality is asserted before any timing begins; and
//! - payloads stay bounded and representative rather than trying to be a full
//!   hash-quality suite.

const std = @import("std");
const assert = std.debug.assert;
const static_hash = @import("static_hash");
const bench = @import("static_testing").bench;
const support = @import("support.zig");

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 4,
    .measure_iterations = 256,
    .sample_count = 8,
};

const fnv_length_sweep = [_]usize{ 0, 1, 3, 7, 8, 15, 16, 31, 32, 63, 64 };
const wyhash_length_sweep = [_]usize{ 0, 1, 3, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256 };
const xxhash_length_sweep = [_]usize{ 127, 128, 255, 256, 512, 4096 };
const fixed_case_count = 12;
const sweep_case_count = fnv_length_sweep.len + wyhash_length_sweep.len + xxhash_length_sweep.len;

const CaseOp = enum {
    fnv1a64_wrapper,
    fnv1a64_std,
    wyhash_wrapper,
    wyhash_std,
    xxhash3_wrapper,
    xxhash3_std,
    crc32_wrapper,
    crc32_std,
    crc32c_wrapper,
    crc32c_std,
    siphash_wrapper,
    siphash_std,
};

const ByteBenchContext = struct {
    name: []const u8,
    payload: []const u8,
    op: CaseOp,
    seed: u64 = 0,
    key: static_hash.siphash.Key = undefined,
    sink_u64: u64 = 0,
    sink_u32: u32 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *ByteBenchContext = @ptrCast(@alignCast(context_ptr));
        switch (context.op) {
            .fnv1a64_wrapper => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.fnv1a.hash64(@truncate(context.seed), context.payload),
                );
            },
            .fnv1a64_std => {
                context.sink_u64 = bench.case.blackBox(std.hash.Fnv1a_64.hash(context.payload));
            },
            .wyhash_wrapper => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.wyhash.hashSeeded(context.seed, context.payload),
                );
            },
            .wyhash_std => {
                context.sink_u64 = bench.case.blackBox(
                    std.hash.Wyhash.hash(context.seed, context.payload),
                );
            },
            .xxhash3_wrapper => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.xxhash3.hash64Seeded(context.seed, context.payload),
                );
            },
            .xxhash3_std => {
                context.sink_u64 = bench.case.blackBox(
                    std.hash.XxHash3.hash(context.seed, context.payload),
                );
            },
            .crc32_wrapper => {
                context.sink_u32 = bench.case.blackBox(static_hash.crc32.checksum(context.payload));
            },
            .crc32_std => {
                var hasher = std.hash.Crc32.init();
                hasher.update(context.payload);
                context.sink_u32 = bench.case.blackBox(hasher.final());
            },
            .crc32c_wrapper => {
                context.sink_u32 = bench.case.blackBox(static_hash.crc32.checksumCastagnoli(context.payload));
            },
            .crc32c_std => {
                var hasher = std.hash.crc.Crc32Iscsi.init();
                hasher.update(context.payload);
                context.sink_u32 = bench.case.blackBox(hasher.final());
            },
            .siphash_wrapper => {
                context.sink_u64 = bench.case.blackBox(
                    static_hash.siphash.hash64_24(&context.key, context.payload),
                );
            },
            .siphash_std => {
                context.sink_u64 = bench.case.blackBox(
                    directSipHash64_24(&context.key, context.payload),
                );
            },
        }
    }
};

pub fn main() !void {
    validateSemanticBaselines();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "byte_hash_baselines");
    defer output_dir.close(io);

    var zero_64: [64]u8 = undefined;
    var zero_4096: [4096]u8 = undefined;
    var incrementing_512: [512]u8 = undefined;
    var incrementing_4096: [4096]u8 = undefined;
    var random_4096: [4096]u8 = undefined;
    @memset(zero_64[0..], 0);
    @memset(zero_4096[0..], 0);
    fillIncrementing(incrementing_512[0..]);
    fillIncrementing(incrementing_4096[0..]);
    fillPseudoRandom(random_4096[0..], 0x17b4_2026_0000_1001);

    const siphash_key = static_hash.siphash.keyFromU64s(
        0x0123_4567_89ab_cdef,
        0xfedc_ba98_7654_3210,
    );

    var contexts: [fixed_case_count + sweep_case_count]ByteBenchContext = undefined;
    var index: usize = 0;

    contexts[index] = .{
        .name = "fnv1a64_wrapper_len64_zero",
        .payload = zero_64[0..],
        .op = .fnv1a64_wrapper,
    };
    index += 1;
    contexts[index] = .{
        .name = "fnv1a64_std_len64_zero",
        .payload = zero_64[0..],
        .op = .fnv1a64_std,
    };
    index += 1;
    contexts[index] = .{
        .name = "wyhash_wrapper_len512_inc",
        .payload = incrementing_512[0..],
        .op = .wyhash_wrapper,
        .seed = 0x00c0_ffee,
    };
    index += 1;
    contexts[index] = .{
        .name = "wyhash_std_len512_inc",
        .payload = incrementing_512[0..],
        .op = .wyhash_std,
        .seed = 0x00c0_ffee,
    };
    index += 1;
    contexts[index] = .{
        .name = "xxhash3_wrapper_len4096_random",
        .payload = random_4096[0..],
        .op = .xxhash3_wrapper,
        .seed = 0x1357_2468_abcdef01,
    };
    index += 1;
    contexts[index] = .{
        .name = "xxhash3_std_len4096_random",
        .payload = random_4096[0..],
        .op = .xxhash3_std,
        .seed = 0x1357_2468_abcdef01,
    };
    index += 1;
    contexts[index] = .{
        .name = "crc32_wrapper_len4096_random",
        .payload = random_4096[0..],
        .op = .crc32_wrapper,
    };
    index += 1;
    contexts[index] = .{
        .name = "crc32_std_len4096_random",
        .payload = random_4096[0..],
        .op = .crc32_std,
    };
    index += 1;
    contexts[index] = .{
        .name = "crc32c_wrapper_len4096_random",
        .payload = random_4096[0..],
        .op = .crc32c_wrapper,
    };
    index += 1;
    contexts[index] = .{
        .name = "crc32c_std_len4096_random",
        .payload = random_4096[0..],
        .op = .crc32c_std,
    };
    index += 1;
    contexts[index] = .{
        .name = "siphash_wrapper_len512_inc",
        .payload = incrementing_512[0..],
        .op = .siphash_wrapper,
        .key = siphash_key,
    };
    index += 1;
    contexts[index] = .{
        .name = "siphash_std_len512_inc",
        .payload = incrementing_512[0..],
        .op = .siphash_std,
        .key = siphash_key,
    };
    index += 1;

    inline for (fnv_length_sweep) |len| {
        contexts[index] = .{
            .name = comptime std.fmt.comptimePrint("fnv1a64_wrapper_len{}_zero_sweep", .{len}),
            .payload = zero_4096[0..len],
            .op = .fnv1a64_wrapper,
        };
        index += 1;
    }

    inline for (wyhash_length_sweep) |len| {
        contexts[index] = .{
            .name = comptime std.fmt.comptimePrint("wyhash_wrapper_len{}_inc_sweep", .{len}),
            .payload = incrementing_4096[0..len],
            .op = .wyhash_wrapper,
            .seed = 0x00c0_ffee,
        };
        index += 1;
    }

    inline for (xxhash_length_sweep) |len| {
        contexts[index] = .{
            .name = comptime std.fmt.comptimePrint("xxhash3_wrapper_len{}_random_sweep", .{len}),
            .payload = random_4096[0..len],
            .op = .xxhash3_wrapper,
            .seed = 0x1357_2468_abcdef01,
        };
        index += 1;
    }

    assert(index == contexts.len);

    var case_storage: [contexts.len]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_hash_byte_baselines",
        .config = bench_config,
    });

    inline for (&contexts) |*context| {
        try group.addCase(bench.case.BenchmarkCase.init(.{
            .name = context.name,
            .tags = &[_][]const u8{ "static_hash", "bytes", "baseline" },
            .context = context,
            .run_fn = ByteBenchContext.run,
        }));
    }

    var sample_storage: [contexts.len * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [contexts.len]bench.runner.BenchmarkCaseResult = undefined;
    var stats_storage: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [16 * 1024]u8 = undefined;
    var read_source_buffer: [16 * 1024]u8 = undefined;
    var read_parse_buffer: [64 * 1024]u8 = undefined;
    var comparison_storage: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [128 * 1024]u8 = undefined;
    var history_record_buffer: [32 * 1024]u8 = undefined;
    var history_frame_buffer: [32 * 1024]u8 = undefined;
    var history_output_buffer: [128 * 1024]u8 = undefined;
    var history_file_buffer: [128 * 1024]u8 = undefined;
    var history_cases: [contexts.len]bench.stats.BenchmarkStats = undefined;
    var history_names: [8192]u8 = undefined;
    var history_tags: [8][]const u8 = undefined;
    var history_comparisons: [contexts.len * 2]bench.baseline.BaselineCaseComparison = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_hash byte hash baselines ==\n", .{});
    var report_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer report_writer.deinit();
    _ = try support.writeReport(
        &report_writer.writer,
        run_result,
        io,
        output_dir,
        "byte_hash_baselines",
        .{
            .stats_storage = &stats_storage,
            .baseline_document_buffer = &baseline_document_buffer,
            .read_source_buffer = &read_source_buffer,
            .read_parse_buffer = &read_parse_buffer,
            .comparison_storage = &comparison_storage,
        },
        .report_only,
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

fn validateSemanticBaselines() void {
    var zero_64: [64]u8 = undefined;
    var incrementing_512: [512]u8 = undefined;
    var random_4096: [4096]u8 = undefined;
    @memset(zero_64[0..], 0);
    fillIncrementing(incrementing_512[0..]);
    fillPseudoRandom(random_4096[0..], 0x17b4_2026_0000_1001);

    assert(static_hash.fnv1a.hash64(0, zero_64[0..]) == std.hash.Fnv1a_64.hash(zero_64[0..]));
    assert(static_hash.wyhash.hashSeeded(0x00c0_ffee, incrementing_512[0..]) == std.hash.Wyhash.hash(0x00c0_ffee, incrementing_512[0..]));
    assert(static_hash.xxhash3.hash64Seeded(0x1357_2468_abcdef01, random_4096[0..]) == std.hash.XxHash3.hash(0x1357_2468_abcdef01, random_4096[0..]));

    const crc32_wrapper = static_hash.crc32.checksum(random_4096[0..]);
    var crc32_std = std.hash.Crc32.init();
    crc32_std.update(random_4096[0..]);
    assert(crc32_wrapper == crc32_std.final());

    const crc32c_wrapper = static_hash.crc32.checksumCastagnoli(random_4096[0..]);
    var crc32c_std = std.hash.crc.Crc32Iscsi.init();
    crc32c_std.update(random_4096[0..]);
    assert(crc32c_wrapper == crc32c_std.final());

    const key = static_hash.siphash.keyFromU64s(0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210);
    assert(
        static_hash.siphash.hash64_24(&key, incrementing_512[0..]) ==
            directSipHash64_24(&key, incrementing_512[0..]),
    );
}

fn fillIncrementing(bytes: []u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* = @truncate(index);
    }
}

fn fillPseudoRandom(bytes: []u8, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(bytes);
}

fn directSipHash64_24(key: *const static_hash.siphash.Key, bytes: []const u8) u64 {
    const Direct = std.crypto.auth.siphash.SipHash64(2, 4);
    var hasher = Direct.init(key);
    hasher.update(bytes);
    var out: [8]u8 = undefined;
    hasher.final(&out);
    return std.mem.readInt(u64, &out, .little);
}
