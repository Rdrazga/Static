//! SplitMix64: 64-bit splittable PRNG based on a Weyl sequence.
//!
//! Key operations: `init`, `next`.
//!
//! Algorithm: each call adds the golden-ratio Weyl constant (0x9e3779b97f4a7c15)
//! to the state then applies three finalisation rounds. All 2^64 states are
//! valid including zero; the Weyl increment is odd so the state visits every
//! u64 value exactly once before wrapping.
//! Period: 2^64. Primarily used to initialise multi-word generators such as
//! Xoroshiro128Plus from a single seed value.
//! Not cryptographically secure.
//! Thread safety: not thread-safe; use one instance per thread.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const SplitMix64 = struct {
    state: u64,

    pub fn init(seed: u64) SplitMix64 {
        return .{ .state = seed };
    }

    pub fn next(self: *SplitMix64) u64 {
        // Deviation: all u64 values are valid states for SplitMix64. No precondition
        // assertion possible -- zero is a legitimate initial state.
        const state_before = self.state;
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        const result = z ^ (z >> 31);
        // Postcondition: the Weyl sequence increment (0x9e3779b97f4a7c15) is odd,
        // so state advances by that odd constant each call and wraps mod 2^64.
        // The state must have changed from before the call.
        assert(self.state != state_before);
        return result;
    }
};

test "SplitMix64 is deterministic for same seed" {
    var a = SplitMix64.init(12345);
    var b = SplitMix64.init(12345);

    var index: usize = 0;
    while (index < 16) : (index += 1) {
        try testing.expectEqual(a.next(), b.next());
    }
}

test "SplitMix64 diverges for different seeds" {
    var a = SplitMix64.init(1);
    var b = SplitMix64.init(2);
    try testing.expect(a.next() != b.next());
}
