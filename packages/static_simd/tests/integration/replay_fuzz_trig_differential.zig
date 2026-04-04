const std = @import("std");
const static_simd = @import("static_simd");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const fuzz_runner = static_testing.testing.fuzz_runner;
const identity = static_testing.testing.identity;

const case_count_max: u32 = 96;
const vectors_per_case: u32 = 12;
const differential_range_limit: f32 = 512.0;
const sin_cos_abs_tol: f32 = 5.0e-5;
const sin_cos_rel_tol: f32 = 5.0e-5;
const tan_abs_tol: f32 = 2.0e-3;
const tan_rel_tol: f32 = 2.0e-3;
const sin_cos_pair_tol: f32 = 1.0e-6;
const tan_pole_offset: f32 = 1.0e-3;

const trig_violation = [_]checker.Violation{
    .{
        .code = "static_simd.trig_differential",
        .message = "SIMD trig lane results diverged from scalar references within the documented valid domain",
    },
};

test "static_simd replay-backed trig differential families stay aligned with scalar references" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const runner = Runner{
        .config = .{
            .package_name = "static_simd",
            .run_name = "trig_differential",
            .base_seed = .{ .value = 0x5171_d000_2026_0001 },
            .build_mode = .debug,
            .case_count_max = case_count_max,
        },
        .target = .{
            .context = undefined,
            .run_fn = TrigTarget.run,
        },
        .persistence = .{
            .io = threaded_io.io(),
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_simd_trig" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    };

    const summary = try runner.run();
    try std.testing.expectEqual(case_count_max, summary.executed_case_count);
    try std.testing.expect(summary.failed_case == null);
}

test "static_simd trig edge inputs stay non-crashing at the integration surface" {
    const edge_values = static_simd.vec4f.Vec4f.init(.{
        std.math.inf(f32),
        -std.math.inf(f32),
        std.math.nan(f32),
        100000.0,
    });

    _ = static_simd.trig.sin4f(edge_values);
    _ = static_simd.trig.cos4f(edge_values);
    _ = static_simd.trig.sincos4f(edge_values);
    _ = static_simd.trig.tan4f(edge_values);
}

test "static_simd trig boundary sin and cos stay finite across the documented range edge" {
    const boundary_values = static_simd.vec4f.Vec4f.init(.{ -8192.0, -4096.0, 4096.0, 8192.0 });
    const sin_values = static_simd.trig.sin4f(boundary_values).toArray();
    const cos_values = static_simd.trig.cos4f(boundary_values).toArray();

    inline for (0..4) |lane_index| {
        try std.testing.expect(std.math.isFinite(sin_values[lane_index]));
        try std.testing.expect(std.math.isFinite(cos_values[lane_index]));
    }
}

const TrigTarget = struct {
    fn run(_: *const anyopaque, run_identity: identity.RunIdentity) error{}!fuzz_runner.FuzzExecution {
        return evaluateCase(run_identity);
    }
};

fn evaluateCase(run_identity: identity.RunIdentity) fuzz_runner.FuzzExecution {
    var digest: u128 = @as(u128, run_identity.seed.value);

    var vector_index: u32 = 0;
    while (vector_index < vectors_per_case) : (vector_index += 1) {
        const values = makeInputFamily(run_identity.seed.value, vector_index);
        const simd_values = static_simd.vec4f.Vec4f.init(values);
        const sin_values = static_simd.trig.sin4f(simd_values).toArray();
        const cos_values = static_simd.trig.cos4f(simd_values).toArray();
        const pair = static_simd.trig.sincos4f(simd_values);
        const pair_sin = pair.sin.toArray();
        const pair_cos = pair.cos.toArray();
        const tan_values = static_simd.trig.tan4f(simd_values).toArray();

        for (values, 0..) |value, lane_index| {
            if (!laneMatches(
                value,
                sin_values[lane_index],
                cos_values[lane_index],
                pair_sin[lane_index],
                pair_cos[lane_index],
                tan_values[lane_index],
            )) {
                return failExecution(run_identity, vector_index + 1, digest);
            }

            digest = foldDigest(digest, valueHash(value));
            digest = foldDigest(digest, valueHash(sin_values[lane_index]));
            digest = foldDigest(digest, valueHash(cos_values[lane_index]));
            digest = foldDigest(digest, valueHash(tan_values[lane_index]));
        }
    }

    return .{
        .trace_metadata = .{
            .event_count = vectors_per_case * 4,
            .truncated = false,
            .has_range = true,
            .first_sequence_no = run_identity.case_index,
            .last_sequence_no = run_identity.case_index + (vectors_per_case * 4) - 1,
            .first_timestamp_ns = run_identity.seed.value & 0xffff,
            .last_timestamp_ns = (run_identity.seed.value & 0xffff) + (vectors_per_case * 4),
        },
        .check_result = checker.CheckResult.pass(checker.CheckpointDigest.init(digest)),
    };
}

fn laneMatches(
    value: f32,
    sin_value: f32,
    cos_value: f32,
    pair_sin_value: f32,
    pair_cos_value: f32,
    tan_value: f32,
) bool {
    if (!std.math.isFinite(value)) return false;
    if (@abs(value) > differential_range_limit) return false;

    const sin_expected = @sin(value);
    const cos_expected = @cos(value);
    if (!approxFinite(sin_value, sin_expected, sin_cos_abs_tol, sin_cos_rel_tol)) return false;
    if (!approxFinite(cos_value, cos_expected, sin_cos_abs_tol, sin_cos_rel_tol)) return false;
    if (!approxFinite(pair_sin_value, sin_expected, sin_cos_abs_tol, sin_cos_rel_tol)) return false;
    if (!approxFinite(pair_cos_value, cos_expected, sin_cos_abs_tol, sin_cos_rel_tol)) return false;
    if (!approxFinite(pair_sin_value, sin_value, sin_cos_pair_tol, sin_cos_pair_tol)) return false;
    if (!approxFinite(pair_cos_value, cos_value, sin_cos_pair_tol, sin_cos_pair_tol)) return false;

    if (isTanPoleAdjacent(value)) {
        return std.math.isFinite(tan_value);
    }

    const tan_expected = @tan(value);
    if (!approxFinite(tan_value, tan_expected, tan_abs_tol, tan_rel_tol)) return false;
    return true;
}

fn approxFinite(actual: f32, expected: f32, abs_tol: f32, rel_tol: f32) bool {
    if (!std.math.isFinite(actual) or !std.math.isFinite(expected)) return false;
    const diff = @abs(actual - expected);
    if (diff <= abs_tol) return true;
    return diff <= @max(@abs(expected), 1.0) * rel_tol;
}

fn isTanPoleAdjacent(value: f32) bool {
    const pi: f32 = @floatCast(std.math.pi);
    const scaled = value / pi;
    const nearest_half_turn = @round(scaled - 0.5) + 0.5;
    const distance = @abs((scaled - nearest_half_turn) * pi);
    return distance <= tan_pole_offset * 2.0;
}

fn makeInputFamily(seed_value: u64, vector_index: u32) [4]f32 {
    var prng = std.Random.DefaultPrng.init(seed_value ^ (@as(u64, vector_index) *% 0x9e37_79b9_7f4a_7c15));
    const random = prng.random();

    var values: [4]f32 = undefined;
    var lane_index: usize = 0;
    while (lane_index < values.len) : (lane_index += 1) {
        const family = @as(u32, @intCast((vector_index + lane_index + @as(usize, @truncate(seed_value))) % 6));
        values[lane_index] = switch (family) {
            0 => (random.float(f32) * 16.0) - 8.0,
            1 => makeBoundaryValue(random),
            2 => makePoleAdjacentValue(random),
            3 => if ((random.int(u32) & 1) == 0) 0.0 else -0.0,
            4 => makeLargeFiniteValue(random),
            5 => makeExactAngleValue(random),
            else => unreachable,
        };
    }
    return values;
}

fn makeBoundaryValue(random: std.Random) f32 {
    const pi: f32 = @floatCast(std.math.pi);
    const multiple = @as(i32, @intCast(random.int(u32) % 9)) - 4;
    const offset_options = [_]f32{ -1.0e-3, -1.0e-4, 0.0, 1.0e-4, 1.0e-3 };
    const offset = offset_options[random.int(u32) % offset_options.len];
    return (@as(f32, @floatFromInt(multiple)) * (pi / 2.0)) + offset;
}

fn makePoleAdjacentValue(random: std.Random) f32 {
    const pi: f32 = @floatCast(std.math.pi);
    const multiple = @as(i32, @intCast(random.int(u32) % 7)) - 3;
    const offset = if ((random.int(u32) & 1) == 0) tan_pole_offset else -tan_pole_offset;
    return (@as(f32, @floatFromInt((multiple * 2) + 1)) * (pi / 2.0)) + offset;
}

fn makeLargeFiniteValue(random: std.Random) f32 {
    const options = [_]f32{ -512.0, -256.0, 128.5, 256.0, 512.0 };
    return options[random.int(u32) % options.len];
}

fn makeExactAngleValue(random: std.Random) f32 {
    const pi: f32 = @floatCast(std.math.pi);
    const options = [_]f32{
        -pi,
        -(pi / 2.0),
        -(pi / 3.0),
        -pi / 6.0,
        0.0,
        pi / 6.0,
        pi / 4.0,
        pi / 3.0,
        pi / 2.0,
        pi,
    };
    return options[random.int(u32) % options.len];
}

fn failExecution(run_identity: identity.RunIdentity, evaluated_vectors: u32, digest: u128) fuzz_runner.FuzzExecution {
    return .{
        .trace_metadata = .{
            .event_count = evaluated_vectors * 4,
            .truncated = false,
            .has_range = true,
            .first_sequence_no = run_identity.case_index,
            .last_sequence_no = run_identity.case_index + (evaluated_vectors * 4) - 1,
            .first_timestamp_ns = run_identity.seed.value & 0xffff,
            .last_timestamp_ns = (run_identity.seed.value & 0xffff) + (evaluated_vectors * 4),
        },
        .check_result = checker.CheckResult.fail(
            &trig_violation,
            checker.CheckpointDigest.init(digest),
        ),
    };
}

fn foldDigest(digest: u128, value: u64) u128 {
    return (digest *% 0x9e37_79b9_7f4a_7c15) ^ @as(u128, value +% 0x5171_d000);
}

fn valueHash(value: f32) u64 {
    const bits: u32 = @bitCast(value);
    return bits;
}
