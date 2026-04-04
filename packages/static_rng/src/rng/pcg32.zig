//! Pcg32: 32-bit Permuted Congruential Generator (PCG-XSH-RR).
//!
//! Key operations: `init`, `nextU32`, `nextU64`, `split`.
//!
//! Algorithm: PCG-XSH-RR — a 64-bit LCG followed by a xor-shift-right plus
//! a rotation output permutation. The `sequence` parameter selects an
//! independent stream; different sequences produce non-overlapping outputs.
//! Period: 2^64 per stream. The increment is forced odd by `init` so that
//! the LCG modulus (2^64) and increment are coprime, guaranteeing a full period.
//! Use `split` to derive a child stream that does not overlap the parent.
//! Not cryptographically secure. Use for reproducible simulations and tests.
//! Thread safety: not thread-safe; use one instance per thread.

const std = @import("std");

pub const Pcg32 = struct {
    state: u64,
    inc: u64,

    pub fn init(seed: u64, sequence: u64) Pcg32 {
        var result = Pcg32{
            .state = 0,
            .inc = (sequence << 1) | 1,
        };
        _ = result.nextU32();
        result.state +%= seed;
        _ = result.nextU32();
        // Postcondition: PCG requires the increment to be odd so it and the
        // modulus (2^64) are coprime, guaranteeing a full-period LCG.
        std.debug.assert((result.inc & 1) == 1);
        return result;
    }

    pub fn nextU32(self: *Pcg32) u32 {
        // Precondition: the increment must remain odd throughout the generator's
        // lifetime. A zero or even increment collapses the period.
        std.debug.assert((self.inc & 1) == 1);
        const old_state = self.state;
        self.state = old_state *% 6364136223846793005 +% self.inc;

        const xorshifted: u32 = @truncate(((old_state >> 18) ^ old_state) >> 27);
        const rot: u5 = @truncate(old_state >> 59);
        return rotateRight32(xorshifted, rot);
    }

    pub fn nextU64(self: *Pcg32) u64 {
        const hi = @as(u64, self.nextU32());
        const lo = @as(u64, self.nextU32());
        return (hi << 32) | lo;
    }

    pub fn split(self: *Pcg32) Pcg32 {
        const parent_state = self.state;
        const parent_inc = self.inc;
        const child_seed = self.nextU64();
        const child_sequence = self.nextU64() | 1;
        const child = init(child_seed, child_sequence);
        // Postcondition: advancing the parent (via nextU64 calls) must have
        // changed its state, and the child must differ from the parent.
        std.debug.assert(self.state != parent_state or self.inc != parent_inc);
        std.debug.assert(child.state != self.state or child.inc != self.inc);
        return child;
    }

    fn rotateRight32(value: u32, count: u5) u32 {
        if (count == 0) return value;
        return (value >> count) | (value << @as(u5, (0 -% count) & 31));
    }
};

test "Pcg32 deterministic for same seed and sequence" {
    var a = Pcg32.init(42, 7);
    var b = Pcg32.init(42, 7);

    var index: usize = 0;
    while (index < 32) : (index += 1) {
        try std.testing.expectEqual(a.nextU32(), b.nextU32());
    }
}

test "Pcg32 sequences differ when sequence stream differs" {
    var a = Pcg32.init(42, 7);
    var b = Pcg32.init(42, 9);
    try std.testing.expect(a.nextU32() != b.nextU32());
}

test "Pcg32 split creates deterministic child stream" {
    var parent_a = Pcg32.init(99, 11);
    var parent_b = Pcg32.init(99, 11);

    var child_a = parent_a.split();
    var child_b = parent_b.split();

    var index: usize = 0;
    while (index < 16) : (index += 1) {
        try std.testing.expectEqual(child_a.nextU64(), child_b.nextU64());
    }
}
