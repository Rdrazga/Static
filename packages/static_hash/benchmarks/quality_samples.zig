//! `static_hash` bounded quality sample.
//!
//! This is a deterministic, SMHasher-style spot check rather than a proof:
//! - exact collision sampling on a bounded generated corpus;
//! - low-bit bucket occupancy spread;
//! - output bit-balance bias; and
//! - average flipped output bits after a one-bit input perturbation.
//!
//! Ideal state for 64-bit outputs:
//! - zero exact collisions in this bounded sample;
//! - bucket occupancy close to the sample mean;
//! - bit bias close to 0%; and
//! - avalanche averages near 32 changed bits.

const std = @import("std");
const static_hash = @import("static_hash");
const builtin = @import("builtin");

const sample_count = 4096;
const avalanche_sample_count = 512;
const bucket_count = 256;

const QualitySummary = struct {
    collisions: usize,
    bucket_min: usize,
    bucket_max: usize,
    max_bit_bias_percent: f64,
    average_flipped_bits: f64,
};

pub fn main() !void {
    std.debug.print("== static_hash bounded quality sample ==\n", .{});
    std.debug.print(
        "ideal: collisions=0, bucket_mean~{d}, low bias, avg_flip_bits~32\n",
        .{sample_count / bucket_count},
    );

    const fingerprint64_summary = sampleFingerprint64();
    const fingerprint_v1_summary = sampleFingerprintV1();
    const combine_ordered_summary = sampleCombineOrdered();
    const combine_multiset_summary = sampleCombineMultiset();
    const xor_lower_bound_summary = sampleXorLowerBound();

    printSummary("fingerprint64", fingerprint64_summary);
    printSummary("fingerprint_v1", fingerprint_v1_summary);
    printSummary("combine_ordered", combine_ordered_summary);
    printSummary("combine_multiset", combine_multiset_summary);
    printSummary("xor_multiset_lower_bound", xor_lower_bound_summary);
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
    std.debug.assert(bytes.len != 0);
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
    std.debug.assert(values.len != 0);
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
