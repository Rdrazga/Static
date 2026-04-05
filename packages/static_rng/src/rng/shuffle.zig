//! shuffle: Fisher-Yates in-place shuffle over a generic slice.
//!
//! Key operations: `shuffleSlice`.
//!
//! Algorithm: Knuth/Fisher-Yates shuffle. Each element is swapped into a
//! uniformly-chosen position among the unprocessed suffix, producing an
//! unbiased uniform permutation. Uses `distributions.uintBelow` internally,
//! which applies rejection sampling to remove modulo bias.
//! Slices of length 0 or 1 are returned immediately without calling the RNG.
//! Thread safety: not thread-safe; the RNG argument is mutated and the slice
//! is written in place. Both must be owned by a single thread.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const distributions = @import("distributions.zig");

pub const DistributionError = distributions.DistributionError;

pub fn shuffleSlice(rng: anytype, values: anytype) DistributionError!void {
    if (values.len <= 1) return;

    var index = values.len - 1;
    while (true) {
        const bound: u64 = @intCast(index + 1);
        const chosen64 = try distributions.uintBelow(rng, bound);
        const chosen: usize = @intCast(chosen64);
        assert(chosen <= index);

        if (chosen != index) {
            std.mem.swap(@TypeOf(values[0]), &values[index], &values[chosen]);
        }

        if (index == 0) break;
        index -= 1;
    }
}

test "shuffleSlice deterministic for same seed" {
    const pcg = @import("pcg32.zig");
    var rng_a = pcg.Pcg32.init(5, 7);
    var rng_b = pcg.Pcg32.init(5, 7);

    var a = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var b = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };

    try shuffleSlice(&rng_a, a[0..]);
    try shuffleSlice(&rng_b, b[0..]);
    try testing.expectEqualSlices(u32, a[0..], b[0..]);
}

test "shuffleSlice preserves all input elements" {
    const pcg = @import("pcg32.zig");
    var rng = pcg.Pcg32.init(11, 13);
    var values = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };

    try shuffleSlice(&rng, values[0..]);

    var seen = [_]bool{false} ** 8;
    for (values) |value| {
        try testing.expect(value < 8);
        seen[value] = true;
    }
    for (seen) |flag| {
        try testing.expect(flag);
    }
}
