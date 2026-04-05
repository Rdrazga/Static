//! distributions: bounded uniform sampling over a generic RNG interface.
//!
//! Key operations: `uintBelow`, `uintInRange`, `f32Unit`, `f64Unit`.
//! Key types: `DistributionError`.
//!
//! All functions accept any RNG with a `nextU64() u64` method (duck-typed via
//! `anytype`). This avoids a concrete dependency on a specific generator.
//! `uintBelow` uses rejection sampling with a debiasing threshold to eliminate
//! modulo bias; for a well-behaved PRNG the expected rejection count is < 2.
//! `f32Unit` and `f64Unit` produce values in [0.0, 1.0) by extracting the
//! required number of mantissa bits from a raw u64 draw.
//! Thread safety: not thread-safe; the RNG argument is mutated and must be
//! owned by a single thread.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const DistributionError = error{
    InvalidConfig,
};

const SamplingError = error{
    PathologicalEngine,
};

const rejection_attempt_limit: u16 = 1024;

/// Return a uniformly sampled integer below `upper_exclusive`.
///
/// The helper retries up to `rejection_attempt_limit` times to avoid modulo
/// bias. Exhausting that budget is treated as a hard liveness failure for a
/// pathological or noncompliant RNG, so the public API keeps the current
/// crash-on-escape-hatch contract instead of widening its error surface.
/// The public wrapper panics on that escape hatch.
pub fn uintBelow(rng: anytype, upper_exclusive: u64) DistributionError!u64 {
    const sample = uintBelowWithPathologicalEngine(rng, upper_exclusive) catch |err| switch (err) {
        error.InvalidConfig => return error.InvalidConfig,
        error.PathologicalEngine => @panic("uintBelow: pathological engine"),
    };
    return sample;
}

fn uintBelowWithPathologicalEngine(
    rng: anytype,
    upper_exclusive: u64,
) (DistributionError || SamplingError)!u64 {
    if (upper_exclusive == 0) return error.InvalidConfig;

    const threshold = (0 -% upper_exclusive) % upper_exclusive;
    var attempts: u16 = 0;
    while (attempts < rejection_attempt_limit) : (attempts += 1) {
        const value = rng.nextU64();
        if (value >= threshold) {
            return value % upper_exclusive;
        }
    }

    // 1024 attempts without a valid sample indicates a pathological engine.
    // The public wrapper treats this as a hard contract failure because the
    // helper is only meant for trusted RNG engines.
    return error.PathologicalEngine;
}

pub fn uintInRange(rng: anytype, min_inclusive: u64, max_inclusive: u64) DistributionError!u64 {
    if (min_inclusive > max_inclusive) return error.InvalidConfig;
    if (min_inclusive == 0 and max_inclusive == std.math.maxInt(u64)) {
        return rng.nextU64();
    }

    const span = (max_inclusive - min_inclusive) + 1;
    const offset = try uintBelow(rng, span);
    return min_inclusive + offset;
}

pub fn f32Unit(rng: anytype) f32 {
    // bits is a 24-bit integer in [0, 2^24). Dividing by 2^24 maps it to [0.0, 1.0).
    const bits: u24 = @truncate(rng.nextU64() >> 40);
    const value = @as(f32, @floatFromInt(bits));
    const result = value / 16777216.0;
    // Postcondition: the result must lie in the half-open interval [0.0, 1.0).
    assert(result >= 0.0);
    assert(result < 1.0);
    return result;
}

pub fn f64Unit(rng: anytype) f64 {
    // bits is a 53-bit integer in [0, 2^53). Dividing by 2^53 maps it to [0.0, 1.0).
    const bits: u53 = @truncate(rng.nextU64() >> 11);
    const value = @as(f64, @floatFromInt(bits));
    const result = value / 9007199254740992.0;
    // Postcondition: the result must lie in the half-open interval [0.0, 1.0).
    assert(result >= 0.0);
    assert(result < 1.0);
    return result;
}

test "uintBelow enforces upper bound" {
    const pcg = @import("pcg32.zig");
    var rng = pcg.Pcg32.init(7, 3);

    var index: usize = 0;
    while (index < 200) : (index += 1) {
        const value = try uintBelow(&rng, 17);
        try testing.expect(value < 17);
    }
}

test "uintBelow rejects zero upper bound" {
    const pcg = @import("pcg32.zig");
    var rng = pcg.Pcg32.init(1, 1);
    try testing.expectError(error.InvalidConfig, uintBelow(&rng, 0));
}

test "uintInRange returns values in requested closed interval" {
    const pcg = @import("pcg32.zig");
    var rng = pcg.Pcg32.init(9, 5);

    var index: usize = 0;
    while (index < 200) : (index += 1) {
        const value = try uintInRange(&rng, 10, 20);
        try testing.expect(value >= 10);
        try testing.expect(value <= 20);
    }
}

test "uintInRange rejects inverted range" {
    const pcg = @import("pcg32.zig");
    var rng = pcg.Pcg32.init(1, 3);
    try testing.expectError(error.InvalidConfig, uintInRange(&rng, 20, 10));
}

test "f32Unit and f64Unit produce [0, 1) values" {
    const pcg = @import("pcg32.zig");
    var rng = pcg.Pcg32.init(77, 15);

    var index: usize = 0;
    while (index < 128) : (index += 1) {
        const value32 = f32Unit(&rng);
        const value64 = f64Unit(&rng);
        try testing.expect(value32 >= 0.0 and value32 < 1.0);
        try testing.expect(value64 >= 0.0 and value64 < 1.0);
    }
}

test "uintBelow with bound=1 always returns 0" {
    // Goal: when the only valid output is zero (bound == 1), every sample must be 0.
    // Method: draw 100 samples with bound=1 and assert each result is zero.
    const pcg = @import("pcg32.zig");
    var rng = pcg.Pcg32.init(1, 1);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const v = try uintBelow(&rng, 1);
        try testing.expectEqual(@as(u64, 0), v);
    }
}

test "uintBelow with nearly-full range" {
    // Goal: verify uintBelow handles large but sub-maxInt(u64) bounds correctly.
    // Method: draw one sample with bound == maxInt(u32) and assert it is in range.
    const pcg = @import("pcg32.zig");
    var rng = pcg.Pcg32.init(42, 7);
    const bound: u64 = std.math.maxInt(u32); // Large but not u64 max.
    const v = try uintBelow(&rng, bound);
    try testing.expect(v < bound);
}

test "uintBelow rejects pathological engines after a bounded attempt budget" {
    const PathologicalRng = struct {
        calls: u16 = 0,

        fn nextU64(self: *@This()) u64 {
            self.calls += 1;
            // Always return a value below the rejection threshold so the helper
            // consumes its entire retry budget.
            return 0;
        }
    };

    var rng = PathologicalRng{};
    try testing.expectError(error.PathologicalEngine, uintBelowWithPathologicalEngine(&rng, 17));
    try testing.expectEqual(rejection_attempt_limit, rng.calls);
}

test "uintBelow panics on pathological engines through the public wrapper" {
    if (isPathologicalChild()) {
        const PathologicalRng = struct {
            fn nextU64(_: *@This()) u64 {
                return 0;
            }
        };

        var rng = PathologicalRng{};
        _ = uintBelow(&rng, 17) catch unreachable;
        return;
    }

    var env_map = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env_map.deinit();
    try env_map.put("STATIC_RNG_UINT_BELOW_PATHOLOGICAL_CHILD", "1");

    const exe_path = try std.process.executablePathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(exe_path);

    const argv = [_][]const u8{exe_path};
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &argv,
        .environ_map = &env_map,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try testing.expect(code != 0),
        else => {},
    }
    try testing.expect(std.mem.indexOf(u8, result.stderr, "uintBelow: pathological engine") != null);
}

fn isPathologicalChild() bool {
    var env_map = std.process.Environ.createMap(testing.environ, testing.allocator) catch return false;
    defer env_map.deinit();
    return env_map.get("STATIC_RNG_UINT_BELOW_PATHOLOGICAL_CHILD") != null;
}
