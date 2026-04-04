//! Static Hash - High-Performance Hash Functions.
//!
//! Provides fast, well-distributed hash functions for hash tables, checksums,
//! fingerprinting, and content addressing. All implementations prioritize
//! speed while maintaining good distribution properties.
//!
//! ## Algorithms
//! - **FNV-1a**: Simple, portable, good for small keys.
//! - **Wyhash**: Excellent speed and quality (Zig's default).
//! - **XxHash3**: Large-buffer throughput.
//! - **CRC32/CRC32C**: IEEE and Castagnoli checksums (hardware-accelerated where available).
//! - **SipHash**: Keyed hashing for DoS resistance on untrusted inputs.
//! - **Stable**: Cross-architecture deterministic hashing via canonical encoding.
//! - **Fingerprint**: Content-addressable fingerprinting (one-shot and streaming).
//! - **Hash Any**: Generic type-aware hashing for any Zig value.
//! - **Combiners**: Order-dependent and order-independent hash composition.
//! - **Budget**: Explicit work bounds for hashing untrusted input.
//!
//! ## Thread Safety
//! - Stateless functions: unrestricted.
//! - Stateful hashers: single-threaded per instance.
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).

const std = @import("std");

// Algorithm modules.
pub const fnv1a = @import("hash/fnv1a.zig");
pub const wyhash = @import("hash/wyhash.zig");
pub const crc32 = @import("hash/crc32.zig");
pub const combine = @import("hash/combine.zig");
pub const fingerprint = @import("hash/fingerprint.zig");
pub const siphash = @import("hash/siphash.zig");
pub const xxhash3 = @import("hash/xxhash3.zig");
pub const stable = @import("hash/stable.zig");
pub const hash_any = @import("hash/hash_any.zig");
pub const budget = @import("hash/budget.zig");

// Convenience re-exports for the most commonly used types and functions.
pub const HashBudget = budget.HashBudget;
pub const HashBudgetError = budget.HashBudgetError;
pub const Seed = hash_any.Seed;
pub const Pair64 = combine.Pair64;

// Top-level convenience functions.
pub const hashAny = hash_any.hashAny;
pub const hashAnySeeded = hash_any.hashAnySeeded;
pub const hashAnyStrict = hash_any.hashAnyStrict;
pub const hashAnyBudgeted = hash_any.hashAnyBudgeted;
pub const hashTuple = hash_any.hashTuple;
pub const hashTupleSeeded = hash_any.hashTupleSeeded;
pub const fingerprint64 = fingerprint.fingerprint64;
pub const fingerprint64Seeded = fingerprint.fingerprint64Seeded;
pub const fingerprint128 = fingerprint.fingerprint128;
pub const combineOrdered64 = combine.combineOrdered64;
pub const combineUnordered64 = combine.combineUnordered64;
pub const combineUnorderedMultiset64 = combine.combineUnorderedMultiset64;
pub const stableHashAny = stable.stableHashAny;
pub const stableHashAnySeeded = stable.stableHashAnySeeded;
pub const stableFingerprint64 = stable.stableFingerprint64;

test {
    _ = fnv1a;
    _ = wyhash;
    _ = crc32;
    _ = combine;
    _ = fingerprint;
    _ = siphash;
    _ = xxhash3;
    _ = stable;
    _ = hash_any;
    _ = budget;
}

test "root convenience re-exports match underlying modules" {
    const bytes = "static-hash";

    const pair: Pair64 = .{ .left = 11, .right = 17 };
    try std.testing.expectEqual(combine.combineOrdered64(pair), combineOrdered64(pair));
    try std.testing.expectEqual(
        combine.combineUnordered64(pair),
        combineUnordered64(pair),
    );
    try std.testing.expectEqual(
        combine.combineUnorderedMultiset64(11, 3),
        combineUnorderedMultiset64(11, 3),
    );

    try std.testing.expectEqual(fingerprint.fingerprint64(bytes), fingerprint64(bytes));
    try std.testing.expectEqual(
        fingerprint.fingerprint64Seeded(99, bytes),
        fingerprint64Seeded(99, bytes),
    );
    try std.testing.expectEqual(
        fingerprint.fingerprint128(bytes),
        fingerprint128(bytes),
    );

    try std.testing.expectEqual(stable.stableHashAny(@as(u32, 7)), stableHashAny(@as(u32, 7)));
    try std.testing.expectEqual(
        stable.stableHashAnySeeded(123, @as(u32, 7)),
        stableHashAnySeeded(123, @as(u32, 7)),
    );
    try std.testing.expectEqual(
        stable.stableFingerprint64(bytes),
        stableFingerprint64(bytes),
    );
}
