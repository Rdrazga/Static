//! `static_hash` bounded quality sample.
//!
//! This is a deterministic, SMHasher-style spot check rather than a proof:
//! - exact collision sampling on a bounded generated corpus;
//! - low-bit bucket occupancy spread;
//! - output bit-balance bias; and
//! - average flipped output bits after a one-bit input perturbation.
//!
//! The results are emitted through the shared `static_testing` benchmark
//! workflow as a reviewable `baseline.zon` plus bounded `history.binlog`
//! sidecar, while the human-readable stdout summary remains for quick scanning.
//!
//! Ideal state for 64-bit outputs:
//! - zero exact collisions in this bounded sample;
//! - bucket occupancy close to the sample mean;
//! - bit bias close to 0%; and
//! - avalanche averages near 32 changed bits.

const std = @import("std");
const assert = std.debug.assert;
const static_hash = @import("static_hash");
const builtin = @import("builtin");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const quality_compare_config: bench.baseline.BaselineCompareConfig = .{
    .thresholds = .{
        .median_ratio_ppm = 0,
        .p95_ratio_ppm = 0,
        .p99_ratio_ppm = 0,
    },
};

const sample_count = 4096;
const avalanche_sample_count = 512;
const bucket_count = 256;
const metric_case_count = 25;
const baseline_document_len = @max(16 * 1024, metric_case_count * 2048);
const read_source_len = @max(16 * 1024, metric_case_count * 2048);
const read_parse_len = @max(32 * 1024, metric_case_count * 4096);
const comparison_capacity = metric_case_count * 2;
const history_existing_len = @max(64 * 1024, metric_case_count * 16 * 1024);
const history_record_len = @max(16 * 1024, metric_case_count * 4096);
const history_frame_len = @max(16 * 1024, metric_case_count * 4096);
const history_output_len = @max(64 * 1024, metric_case_count * 16 * 1024);
const history_file_len = @max(64 * 1024, metric_case_count * 16 * 1024);
const history_names_len = @max(4096, metric_case_count * 1024);

const QualitySummary = struct {
    collisions: usize,
    bucket_min: usize,
    bucket_max: usize,
    max_bit_bias_percent: f64,
    average_flipped_bits: f64,
};

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "quality_samples");
    defer output_dir.close(io);

    const fingerprint64_summary = sampleFingerprint64();
    const fingerprint_v1_summary = sampleFingerprintV1();
    const combine_ordered_summary = sampleCombineOrdered();
    const combine_multiset_summary = sampleCombineMultiset();
    const xor_lower_bound_summary = sampleXorLowerBound();

    var case_sample_storage: [metric_case_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [metric_case_count]bench.runner.BenchmarkCaseResult = undefined;
    var case_index: usize = 0;
    appendSummaryCases(
        "fingerprint64",
        fingerprint64_summary,
        &case_index,
        &case_sample_storage,
        &case_result_storage,
    );
    appendSummaryCases(
        "fingerprint_v1",
        fingerprint_v1_summary,
        &case_index,
        &case_sample_storage,
        &case_result_storage,
    );
    appendSummaryCases(
        "combine_ordered",
        combine_ordered_summary,
        &case_index,
        &case_sample_storage,
        &case_result_storage,
    );
    appendSummaryCases(
        "combine_multiset",
        combine_multiset_summary,
        &case_index,
        &case_sample_storage,
        &case_result_storage,
    );
    appendSummaryCases(
        "xor_multiset_lower_bound",
        xor_lower_bound_summary,
        &case_index,
        &case_sample_storage,
        &case_result_storage,
    );
    assert(case_index == case_result_storage.len);

    var report_stats_storage: [metric_case_count]bench.stats.BenchmarkStats = undefined;
    var report_baseline_buffer: [baseline_document_len]u8 = undefined;
    var report_source_buffer: [read_source_len]u8 = undefined;
    var report_parse_buffer: [read_parse_len]u8 = undefined;
    var report_comparison_storage: [comparison_capacity]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [history_existing_len]u8 = undefined;
    var history_record_buffer: [history_record_len]u8 = undefined;
    var history_frame_buffer: [history_frame_len]u8 = undefined;
    var history_output_buffer: [history_output_len]u8 = undefined;
    var history_file_buffer: [history_file_len]u8 = undefined;
    var history_cases: [metric_case_count]bench.stats.BenchmarkStats = undefined;
    var history_names: [history_names_len]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [comparison_capacity]bench.baseline.BaselineCaseComparison = undefined;

    const run_result = bench.runner.BenchmarkRunResult{
        .mode = .smoke,
        .case_results = &case_result_storage,
    };

    std.debug.print("== static_hash bounded quality sample ==\n", .{});
    std.debug.print(
        "ideal: collisions=0, bucket_mean~{d}, low bias, avg_flip_bits~32\n",
        .{sample_count / bucket_count},
    );
    printSummary("fingerprint64", fingerprint64_summary);
    printSummary("fingerprint_v1", fingerprint_v1_summary);
    printSummary("combine_ordered", combine_ordered_summary);
    printSummary("combine_multiset", combine_multiset_summary);
    printSummary("xor_multiset_lower_bound", xor_lower_bound_summary);

    var report_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer report_writer.deinit();
    _ = try support.writeReport(
        &report_writer.writer,
        run_result,
        io,
        output_dir,
        "quality_samples",
        .{
            .stats_storage = &report_stats_storage,
            .baseline_document_buffer = &report_baseline_buffer,
            .read_source_buffer = &report_source_buffer,
            .read_parse_buffer = &report_parse_buffer,
            .comparison_storage = &report_comparison_storage,
        },
        .record_if_missing_then_compare,
        quality_compare_config,
        false,
        .{
            .sub_path = "history.binlog",
            .package_name = "static_hash",
            .environment_note = support.default_environment_note,
            .environment_tags = &[_][]const u8{ "static_hash", "quality_samples" },
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
        .{
            .include_samples = false,
            .include_derived_summary = false,
        },
    );

    var report_out = report_writer.toArrayList();
    defer report_out.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{report_out.items});
}

fn sampleFingerprint64() QualitySummary {
    var outputs: [sample_count]u64 = undefined;
    var avalanche_sum: u64 = 0;

    for (0..sample_count) |index| {
        var storage: [256]u8 = undefined;
        const data = buildByteCase(0x17b4_2026_0000_3001 + index, &storage);
        outputs[index] = static_hash.fingerprint64(data);

        if (index < avalanche_sample_count) {
            var perturbed_storage = storage;
            perturbByteSlice(perturbed_storage[0..data.len], index);
            const perturbed = static_hash.fingerprint64(perturbed_storage[0..data.len]);
            avalanche_sum += @popCount(outputs[index] ^ perturbed);
        }
    }

    return analyzeOutputs(outputs[0..], avalanche_sum, avalanche_sample_count);
}

fn sampleFingerprintV1() QualitySummary {
    var outputs: [sample_count]u64 = undefined;
    var avalanche_sum: u64 = 0;

    for (0..sample_count) |index| {
        var storage: [256]u8 = undefined;
        const data = buildByteCase(0x17b4_2026_0000_3002 + index, &storage);

        var base = static_hash.fingerprint.Fingerprint64V1.init();
        base.update(data);
        base.addU64(0x0123_4567_89ab_cdef);
        outputs[index] = base.final();

        if (index < avalanche_sample_count) {
            var perturbed_storage = storage;
            perturbByteSlice(perturbed_storage[0..data.len], index);
            var perturbed = static_hash.fingerprint.Fingerprint64V1.init();
            perturbed.update(perturbed_storage[0..data.len]);
            perturbed.addU64(0x0123_4567_89ab_cdef);
            avalanche_sum += @popCount(outputs[index] ^ perturbed.final());
        }
    }

    return analyzeOutputs(outputs[0..], avalanche_sum, avalanche_sample_count);
}

fn sampleCombineOrdered() QualitySummary {
    var outputs: [sample_count]u64 = undefined;
    var avalanche_sum: u64 = 0;

    for (0..sample_count) |index| {
        const base_values = buildValueTuple(0x17b4_2026_0000_3003 + index);
        outputs[index] = foldOrdered(base_values[0..]);

        if (index < avalanche_sample_count) {
            var perturbed_values = base_values;
            perturbed_values[0] ^= (@as(u64, 1) << @as(u6, @truncate(index)));
            avalanche_sum += @popCount(outputs[index] ^ foldOrdered(perturbed_values[0..]));
        }
    }

    return analyzeOutputs(outputs[0..], avalanche_sum, avalanche_sample_count);
}

fn sampleCombineMultiset() QualitySummary {
    var outputs: [sample_count]u64 = undefined;
    var avalanche_sum: u64 = 0;

    for (0..sample_count) |index| {
        const base_values = buildValueTuple(0x17b4_2026_0000_3004 + index);
        outputs[index] = foldUnorderedMultiset(base_values[0..]);

        if (index < avalanche_sample_count) {
            var perturbed_values = base_values;
            perturbed_values[0] ^= (@as(u64, 1) << @as(u6, @truncate(index)));
            avalanche_sum += @popCount(outputs[index] ^ foldUnorderedMultiset(perturbed_values[0..]));
        }
    }

    return analyzeOutputs(outputs[0..], avalanche_sum, avalanche_sample_count);
}

fn sampleXorLowerBound() QualitySummary {
    var outputs: [sample_count]u64 = undefined;
    var avalanche_sum: u64 = 0;

    for (0..sample_count) |index| {
        const base_values = buildValueTuple(0x17b4_2026_0000_3005 + index);
        outputs[index] = foldXor(base_values[0..]);

        if (index < avalanche_sample_count) {
            var perturbed_values = base_values;
            perturbed_values[0] ^= (@as(u64, 1) << @as(u6, @truncate(index)));
            avalanche_sum += @popCount(outputs[index] ^ foldXor(perturbed_values[0..]));
        }
    }

    return analyzeOutputs(outputs[0..], avalanche_sum, avalanche_sample_count);
}

fn analyzeOutputs(outputs: []const u64, avalanche_sum: u64, avalanche_samples: usize) QualitySummary {
    var buckets: [bucket_count]usize = [_]usize{0} ** bucket_count;
    var bit_counts: [64]usize = [_]usize{0} ** 64;

    for (outputs) |output| {
        buckets[@as(usize, @intCast(output & (bucket_count - 1)))] += 1;
        for (0..64) |bit_index| {
            bit_counts[bit_index] += @intFromBool(((output >> @as(u6, @intCast(bit_index))) & 1) == 1);
        }
    }

    var collisions: usize = 0;
    for (outputs, 0..) |left, left_index| {
        for (outputs[left_index + 1 ..]) |right| {
            if (left == right) collisions += 1;
        }
    }

    var bucket_min: usize = std.math.maxInt(usize);
    var bucket_max: usize = 0;
    for (buckets) |count| {
        bucket_min = @min(bucket_min, count);
        bucket_max = @max(bucket_max, count);
    }

    const expected_half = @as(f64, @floatFromInt(outputs.len)) / 2.0;
    var max_bit_bias_percent: f64 = 0.0;
    for (bit_counts) |count| {
        const deviation = @abs(@as(f64, @floatFromInt(count)) - expected_half);
        const percent = (deviation / @as(f64, @floatFromInt(outputs.len))) * 100.0;
        max_bit_bias_percent = @max(max_bit_bias_percent, percent);
    }

    return .{
        .collisions = collisions,
        .bucket_min = bucket_min,
        .bucket_max = bucket_max,
        .max_bit_bias_percent = max_bit_bias_percent,
        .average_flipped_bits = @as(f64, @floatFromInt(avalanche_sum)) /
            @as(f64, @floatFromInt(avalanche_samples)),
    };
}

fn printSummary(name: []const u8, summary: QualitySummary) void {
    std.debug.print(
        "{s}: collisions={} bucket_min={} bucket_max={} max_bit_bias={d:.2}% avg_flip_bits={d:.2}\n",
        .{
            name,
            summary.collisions,
            summary.bucket_min,
            summary.bucket_max,
            summary.max_bit_bias_percent,
            summary.average_flipped_bits,
        },
    );
}

fn appendSummaryCases(
    comptime prefix: []const u8,
    summary: QualitySummary,
    case_index: *usize,
    sample_storage: []bench.runner.BenchmarkSample,
    case_result_storage: []bench.runner.BenchmarkCaseResult,
) void {
    appendMetricCase(
        comptime std.fmt.comptimePrint("{s}_collisions", .{prefix}),
        @as(u64, @intCast(summary.collisions)),
        case_index,
        sample_storage,
        case_result_storage,
    );
    appendMetricCase(
        comptime std.fmt.comptimePrint("{s}_bucket_min", .{prefix}),
        @as(u64, @intCast(summary.bucket_min)),
        case_index,
        sample_storage,
        case_result_storage,
    );
    appendMetricCase(
        comptime std.fmt.comptimePrint("{s}_bucket_max", .{prefix}),
        @as(u64, @intCast(summary.bucket_max)),
        case_index,
        sample_storage,
        case_result_storage,
    );
    appendMetricCase(
        comptime std.fmt.comptimePrint("{s}_max_bit_bias_x1000", .{prefix}),
        scaledMetric(summary.max_bit_bias_percent),
        case_index,
        sample_storage,
        case_result_storage,
    );
    appendMetricCase(
        comptime std.fmt.comptimePrint("{s}_avg_flipped_bits_x1000", .{prefix}),
        scaledMetric(summary.average_flipped_bits),
        case_index,
        sample_storage,
        case_result_storage,
    );
}

fn appendMetricCase(
    comptime name: []const u8,
    value: u64,
    case_index: *usize,
    sample_storage: []bench.runner.BenchmarkSample,
    case_result_storage: []bench.runner.BenchmarkCaseResult,
) void {
    const index = case_index.*;
    assert(index < sample_storage.len);
    assert(index < case_result_storage.len);

    sample_storage[index] = .{
        .elapsed_ns = value,
        .iteration_count = 1,
    };
    case_result_storage[index] = .{
        .name = name,
        .warmup_iterations = 0,
        .measure_iterations = 1,
        .samples = sample_storage[index .. index + 1],
        .total_elapsed_ns = value,
    };
    case_index.* = index + 1;
}

fn scaledMetric(value: f64) u64 {
    assert(value >= 0.0);
    return @as(u64, @intFromFloat(value * 1000.0));
}

fn buildByteCase(seed_value: usize, storage: []u8) []const u8 {
    const len = 64;
    const bytes = storage[0..len];

    switch (@as(u2, @truncate(seed_value >> 4))) {
        0 => for (bytes, 0..) |*byte, index| {
            byte.* = @truncate(seed_value +% (index *% 17));
        },
        1 => for (bytes, 0..) |*byte, index| {
            byte.* = @truncate((seed_value >> @as(u6, @truncate((index % 8) * 8))) +% index);
        },
        else => {
            var prng = std.Random.DefaultPrng.init(@as(u64, seed_value) ^ 0x243f_6a88_85a3_08d3);
            prng.random().bytes(bytes);
        },
    }

    for (bytes, 0..) |*byte, index| {
        byte.* ^= @truncate((seed_value >> @as(u6, @truncate((index % 8) * 8))) & 0xff);
        byte.* +%= @truncate(index *% 31);
    }

    std.mem.writeInt(
        u64,
        bytes[0..8],
        @as(u64, seed_value),
        builtin.cpu.arch.endian(),
    );
    std.mem.writeInt(
        u64,
        bytes[8..16],
        (@as(u64, seed_value) *% 0x9e37_79b9_7f4a_7c15),
        builtin.cpu.arch.endian(),
    );

    return bytes;
}

fn perturbByteSlice(bytes: []u8, index: usize) void {
    assert(bytes.len != 0);
    const byte_index = index % bytes.len;
    const mask: u8 = @as(u8, 1) << @as(u3, @truncate(index));
    bytes[byte_index] ^= mask;
}

fn buildValueTuple(seed_value: usize) [4]u64 {
    var prng = std.Random.DefaultPrng.init(@as(u64, seed_value) ^ 0x9e37_79b9_7f4a_7c15);
    const random = prng.random();
    return .{
        random.int(u64),
        random.int(u64),
        random.int(u64),
        random.int(u64),
    };
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

fn foldXor(values: []const u64) u64 {
    var acc: u64 = 0;
    for (values) |value| {
        acc ^= value;
    }
    return acc;
}
