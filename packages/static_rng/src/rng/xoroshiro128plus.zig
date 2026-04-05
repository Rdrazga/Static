//! Xoroshiro128+: 128-bit xoroshiro generator with a + output function.
//!
//! Key operations: `init`, `nextU64`, `jump`, `split`.
//!
//! Algorithm: xoroshiro128+ uses a 128-bit state (two u64 words) advanced by
//! xor, rotate, and shift operations. The `+` output function sums the two
//! state words, which is fast but has known weakness in the low bits; use the
//! upper bits of each output when only partial precision is needed.
//! Period: 2^128 - 1. The all-zero state is excluded and never reached.
//! `jump` advances the state by 2^64 steps, equivalent to calling `nextU64`
//! that many times. Use `split` to obtain a new instance starting 2^64 steps
//! ahead of the current position, giving non-overlapping parallel streams.
//! Not cryptographically secure. Prefer for high-throughput simulations.
//! Thread safety: not thread-safe; use one instance per thread.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const splitmix64 = @import("splitmix64.zig");

pub const Xoroshiro128Plus = struct {
    s0: u64,
    s1: u64,

    pub fn init(seed: u64) Xoroshiro128Plus {
        var seeder = splitmix64.SplitMix64.init(seed);
        const s0 = seeder.next();
        var s1 = seeder.next();

        // Avoid all-zero state.
        if (s0 == 0 and s1 == 0) {
            s1 = 1;
        }

        return .{
            .s0 = s0,
            .s1 = s1,
        };
    }

    pub fn nextU64(self: *Xoroshiro128Plus) u64 {
        const result = self.s0 +% self.s1;
        const mixed = self.s1 ^ self.s0;

        self.s0 = rotl64(self.s0, 55) ^ mixed ^ (mixed << 14);
        self.s1 = rotl64(mixed, 36);
        return result;
    }

    pub fn jump(self: *Xoroshiro128Plus) void {
        // Precondition: state must be non-zero before the jump. A zero state would
        // produce zero output from nextU64 indefinitely and must never occur.
        assert(self.s0 != 0 or self.s1 != 0);
        const state_s0_before = self.s0;
        const state_s1_before = self.s1;

        const jump_constants = [_]u64{
            0xbeac0467eba5facb,
            0xd86b048b86aa9922,
        };

        var next_s0: u64 = 0;
        var next_s1: u64 = 0;

        for (jump_constants) |constant| {
            var bit: usize = 0;
            while (bit < 64) : (bit += 1) {
                const shift: u6 = @intCast(bit);
                if (((constant >> shift) & 1) == 1) {
                    next_s0 ^= self.s0;
                    next_s1 ^= self.s1;
                }
                _ = self.nextU64();
            }
        }

        self.s0 = next_s0;
        self.s1 = next_s1;
        // Postcondition: the jump must have changed the state (it advances 2^64 steps).
        assert(self.s0 != state_s0_before or self.s1 != state_s1_before);
        // Postcondition: state must remain non-zero after the jump.
        assert(self.s0 != 0 or self.s1 != 0);
    }

    pub fn split(self: *Xoroshiro128Plus) Xoroshiro128Plus {
        // Capture child state before advancing parent. Advancing parent ensures
        // that successive split() calls produce independent, non-overlapping streams.
        const child_start = self.*;
        self.jump();
        assert(self.s0 != child_start.s0 or self.s1 != child_start.s1);
        assert(self.s0 != 0 or self.s1 != 0);
        return child_start;
    }

    fn rotl64(value: u64, count: u6) u64 {
        if (count == 0) return value;
        return (value << count) | (value >> @as(u6, (0 -% count) & 63));
    }
};

test "Xoroshiro128Plus deterministic for same seed" {
    var a = Xoroshiro128Plus.init(123);
    var b = Xoroshiro128Plus.init(123);

    var index: usize = 0;
    while (index < 24) : (index += 1) {
        try testing.expectEqual(a.nextU64(), b.nextU64());
    }
}

test "Xoroshiro128Plus jump changes stream" {
    var a = Xoroshiro128Plus.init(99);
    var b = Xoroshiro128Plus.init(99);
    b.jump();
    try testing.expect(a.nextU64() != b.nextU64());
}

test "Xoroshiro128Plus split is deterministic for same parent state" {
    var parent_a = Xoroshiro128Plus.init(88);
    var parent_b = Xoroshiro128Plus.init(88);

    var child_a = parent_a.split();
    var child_b = parent_b.split();

    var index: usize = 0;
    while (index < 12) : (index += 1) {
        try testing.expectEqual(child_a.nextU64(), child_b.nextU64());
    }
}
