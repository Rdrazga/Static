//! Hash Combiners - Composing Multiple Hash Values.
//!
//! When hashing composite values (sequences, sets, structs), individual field
//! hashes must be combined into a single hash. This module provides combiners
//! for different use cases.
//!
//! ## Thread Safety
//! Unrestricted. All functions are pure and reentrant.
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).
//!
//! ## Design
//! - `combineOrdered64`: order-dependent. Use for sequences and tuples.
//! - `combineUnordered64`: order-independent via canonical ordering. Fast but
//!   cannot distinguish multisets (e.g., {a,a,b} vs {a,b,b}).
//! - `combineUnorderedMultiset64`: order-independent and multiplicity-sensitive.
//!   Recommended for most unordered use cases.
//! - The `Pair64` struct avoids positional ambiguity when passing two u64 args.

const std = @import("std");

/// A pair of 64-bit hash values to be combined.
///
/// Using a struct avoids positional ambiguity when two u64 parameters would
/// otherwise be interchangeable at the call site.
pub const Pair64 = struct {
    left: u64,
    right: u64,
};

/// Combine two hashes (order-dependent).
///
/// Uses a SplitMix64-style avalanche to mix left and right. The result
/// depends on operand order: `combineOrdered64({a,b}) != combineOrdered64({b,a})`.
///
/// Postconditions: returns deterministic combined hash.
pub fn combineOrdered64(pair: Pair64) u64 {
    comptime {
        // Golden-ratio constant distributes entropy across bits before finalization.
        std.debug.assert(0x9e3779b97f4a7c15 != 0);
        // SplitMix64 finalizer multipliers must be odd for invertibility in mod 2^64.
        std.debug.assert(0xbf58476d1ce4e5b9 % 2 == 1);
        std.debug.assert(0x94d049bb133111eb % 2 == 1);
    }
    var x = pair.left ^ (pair.right +% 0x9e3779b97f4a7c15);
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

/// Combine two hashes (order-independent).
///
/// Achieves commutativity by canonicalizing operand order (min/max) before
/// feeding into the ordered combiner. This is fast but does not distinguish
/// multisets: `combine(a, a)` always produces the same result regardless of
/// multiplicity context.
///
/// Postconditions: `combineUnordered64({a,b}) == combineUnordered64({b,a})`.
pub fn combineUnordered64(pair: Pair64) u64 {
    const lo = @min(pair.left, pair.right);
    const hi = @max(pair.left, pair.right);
    // Canonical ordering: lo <= hi by construction of @min/@max.
    std.debug.assert(lo <= hi);
    return combineOrdered64(.{ .left = lo, .right = hi });
}

/// SplitMix64 finalizer - fast bit avalanche for 64-bit values.
///
/// Used internally by the multiset combiner to ensure each element hash
/// contributes independently to the accumulator.
pub fn mix64(x: u64) u64 {
    comptime {
        // SplitMix64 finalizer multipliers must be odd for invertibility.
        std.debug.assert(0xbf58476d1ce4e5b9 % 2 == 1);
        std.debug.assert(0x94d049bb133111eb % 2 == 1);
    }
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Combine a running accumulator with an element hash (order-independent multiset).
///
/// This is commutative and multiplicity-sensitive:
/// - Combining the same element hash twice changes the result.
/// - `combine(combine(0, a), b) == combine(combine(0, b), a)`.
///
/// The mix64 finalizer prevents the cancellation weakness of plain XOR.
///
/// Postconditions: returns updated accumulator.
pub fn combineUnorderedMultiset64(acc: u64, elem_hash: u64) u64 {
    // mix64 ensures each element contributes non-trivially to the accumulator.
    // SplitMix64 is a bijection on u64, so fixed points (mix64(x) == x) are
    // theoretically possible but astronomically unlikely (~1 in 2^64).
    return acc +% mix64(elem_hash);
}

/// Short alias for `combineOrdered64`.
pub fn ordered(pair: Pair64) u64 {
    return combineOrdered64(pair);
}

/// Short alias for `combineUnordered64`.
pub fn unordered(pair: Pair64) u64 {
    return combineUnordered64(pair);
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: cover each combiner's algebraic guarantees (determinism, commutativity, ordering)
// with a mix of fixed vectors and bounded randomized property tests.

test "ordered and unordered combiners differ in ordering guarantees" {
    const ab = combineOrdered64(.{ .left = 1, .right = 2 });
    const ba = combineOrdered64(.{ .left = 2, .right = 1 });
    try std.testing.expect(ab != ba);
    try std.testing.expectEqual(
        combineUnordered64(.{ .left = 1, .right = 2 }),
        combineUnordered64(.{ .left = 2, .right = 1 }),
    );
}

test "combine ordered is deterministic" {
    const x = combineOrdered64(.{ .left = 0xDEAD, .right = 0xBEEF });
    const y = combineOrdered64(.{ .left = 0xDEAD, .right = 0xBEEF });
    try std.testing.expectEqual(x, y);
}

test "combine aliases match direct calls" {
    const pair: Pair64 = .{ .left = 42, .right = 99 };
    try std.testing.expectEqual(combineOrdered64(pair), ordered(pair));
    try std.testing.expectEqual(combineUnordered64(pair), unordered(pair));
}

test "combineUnorderedMultiset64 is commutative" {
    const a: u64 = 12345;
    const b: u64 = 67890;
    const ab = combineUnorderedMultiset64(combineUnorderedMultiset64(0, a), b);
    const ba = combineUnorderedMultiset64(combineUnorderedMultiset64(0, b), a);
    try std.testing.expectEqual(ab, ba);
}

test "combineUnorderedMultiset64 is multiplicity-sensitive" {
    const x: u64 = 0xdeadbeef;
    const once = combineUnorderedMultiset64(0, x);
    const twice = combineUnorderedMultiset64(once, x);
    try std.testing.expect(twice != once);
    try std.testing.expect(twice != 0);
}

test "mix64 produces different outputs for different inputs" {
    try std.testing.expect(mix64(0) != mix64(1));
    try std.testing.expect(mix64(0) != 0);
}

test "combine golden vectors are stable" {
    // Pinned output values. These must never change.
    try std.testing.expectEqual(@as(u64, 0x910a2dec89025cc1), combineOrdered64(.{ .left = 1, .right = 2 }));
    try std.testing.expectEqual(@as(u64, 0xe220a8397b1dcdaf), mix64(0));
}

test "property: combineUnordered64 is commutative for random inputs" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();
    for (0..1000) |_| {
        const a = random.int(u64);
        const b = random.int(u64);
        try std.testing.expectEqual(
            combineUnordered64(.{ .left = a, .right = b }),
            combineUnordered64(.{ .left = b, .right = a }),
        );
    }
}

test "property: combineUnorderedMultiset64 is commutative for random inputs" {
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE);
    const random = prng.random();
    for (0..1000) |_| {
        const a = random.int(u64);
        const b = random.int(u64);
        const ab = combineUnorderedMultiset64(combineUnorderedMultiset64(0, a), b);
        const ba = combineUnorderedMultiset64(combineUnorderedMultiset64(0, b), a);
        try std.testing.expectEqual(ab, ba);
    }
}
