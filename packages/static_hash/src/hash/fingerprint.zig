//! Fingerprinting - Content-Addressable Hash Functions.
//!
//! Fingerprints are deterministic hashes used for content addressing, deduplication,
//! and identity. This module provides both one-shot (Wyhash-based) and streaming
//! (FNV-1a-based) fingerprinting.
//!
//! ## Thread Safety
//! - One-shot functions (`fingerprint64`, `fingerprint128`): unrestricted (pure).
//! - Streaming hasher (`Fingerprint64V1`): none (single-threaded per instance).
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).
//!
//! ## Design
//! - One-shot fingerprints use Wyhash for speed and quality. These are NOT a
//!   stable on-disk format: the underlying algorithm may change between major
//!   versions. For cross-architecture stable hashing of arbitrary types, use
//!   the `stable` module.
//! - Streaming fingerprints (`Fingerprint64V1`) are versioned and stable within
//!   a version. The `static_version` field identifies the scheme; output is
//!   immutable within a version.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const combine = @import("combine.zig");

const Wyhash = std.hash.Wyhash;

/// Hash seed type.
pub const Seed = u64;

// =============================================================================
// One-Shot Fingerprinting (Wyhash-based)
// =============================================================================

/// 64-bit fingerprint for content addressing.
///
/// Uses Wyhash with seed 0 for deterministic, high-quality fingerprinting.
///
/// Preconditions: if data.len > 0, data.ptr must be non-null.
/// Postconditions: returns deterministic 64-bit fingerprint of data.
pub fn fingerprint64(data: []const u8) u64 {
    assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
    return Wyhash.hash(0, data);
}

/// 64-bit fingerprint with an explicit seed.
///
/// Use different seeds for keyed hashing or to generate independent hash families.
///
/// Preconditions: if data.len > 0, data.ptr must be non-null.
/// Postconditions: returns deterministic 64-bit fingerprint of data with given seed.
pub fn fingerprint64Seeded(seed: Seed, data: []const u8) u64 {
    assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
    return Wyhash.hash(seed, data);
}

/// 128-bit fingerprint (two independent hashes) for lower collision probability.
///
/// Postconditions: low 64 bits use seed 0, high 64 bits use the golden ratio.
pub fn fingerprint128(data: []const u8) u128 {
    assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
    return fingerprint128Seeded(0, 0x9e3779b97f4a7c15, data);
}

/// 128-bit fingerprint with explicit seeds (two independent hashes).
///
/// Preconditions: seed_a != seed_b (identical seeds produce correlated hashes,
/// defeating the purpose of a 128-bit fingerprint).
/// Postconditions: low 64 bits use seed_a, high 64 bits use seed_b.
pub fn fingerprint128Seeded(seed_a: Seed, seed_b: Seed, data: []const u8) u128 {
    // Identical seeds produce identical high/low halves, which defeats the
    // collision-resistance benefit of a 128-bit fingerprint.
    assert(seed_a != seed_b);
    assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
    const low = Wyhash.hash(seed_a, data);
    const high = Wyhash.hash(seed_b, data);
    return @as(u128, high) << 64 | low;
}

// =============================================================================
// Streaming Fingerprinting (FNV-1a-based)
// =============================================================================

/// Streaming fingerprint using FNV-1a internally.
///
/// Guarantees that splitting input across multiple `update` calls produces
/// the same result as a single call with the concatenated input (streaming
/// invariant). Use `addU64` to incorporate structured values alongside bytes.
///
/// The `static_name` and `static_version` fields identify this fingerprint
/// scheme for versioned storage.
pub const Fingerprint64V1 = struct {
    pub const static_name = "static_hash/fingerprint64_v1";
    pub const static_version: u32 = 1;

    const fnv64_offset_basis: u64 = 0xCBF29CE484222325;
    const fnv64_prime: u64 = 0x100000001B3;

    comptime {
        // FNV-1a constants must be non-zero for correct mixing.
        assert(fnv64_offset_basis != 0);
        assert(fnv64_prime != 0);
        // Prime must be odd for invertibility in mod 2^64.
        assert(fnv64_prime % 2 == 1);
    }

    state: u64 = fnv64_offset_basis,

    /// Initialize a new streaming fingerprint.
    ///
    /// Postconditions: state is the FNV-1a offset basis.
    pub fn init() Fingerprint64V1 {
        const result: Fingerprint64V1 = .{};
        // Postcondition: state starts at the canonical offset basis.
        assert(result.state == fnv64_offset_basis);
        return result;
    }

    /// Feed `bytes` into the fingerprint.
    ///
    /// Maintains the streaming invariant:
    /// `update("ab"); update("cd")` == `update("abcd")`.
    ///
    /// Preconditions: if bytes.len > 0, bytes.ptr must be non-null.
    /// Postconditions: state updated with every byte.
    pub fn update(self: *Fingerprint64V1, bytes: []const u8) void {
        assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
        for (bytes) |b| {
            self.state ^= b;
            self.state *%= fnv64_prime;
        }
    }

    /// Incorporate a u64 value into the fingerprint via combineOrdered64.
    ///
    /// Use this to mix structured values (lengths, tags, computed hashes)
    /// alongside raw byte data.
    ///
    /// Postconditions: state updated with the combined value.
    pub fn addU64(self: *Fingerprint64V1, value: u64) void {
        self.state = combine.combineOrdered64(.{
            .left = self.state,
            .right = value,
        });
    }

    /// Finalize and return the fingerprint value.
    ///
    /// Postconditions: returns accumulated fingerprint; state is unchanged.
    pub fn final(self: *const Fingerprint64V1) u64 {
        return self.state;
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: validate determinism and streaming equivalence, and cover invariants that should hold across seeds.

test "fingerprint64 one-shot is deterministic" {
    const a = fingerprint64("test data");
    const b = fingerprint64("test data");
    try testing.expectEqual(a, b);
}

test "fingerprint64Seeded differs across seeds" {
    const a = fingerprint64Seeded(1, "test data");
    const b = fingerprint64Seeded(2, "test data");
    try testing.expect(a != b);
}

test "fingerprint128 low 64 matches fingerprint64" {
    const fp64 = fingerprint64("test");
    const fp128 = fingerprint128("test");
    const low: u64 = @truncate(fp128);
    try testing.expectEqual(fp64, low);
}

test "fingerprint128 high and low differ" {
    const fp128 = fingerprint128("test");
    const low: u64 = @truncate(fp128);
    const high: u64 = @truncate(fp128 >> 64);
    try testing.expect(low != high);
}

test "fingerprint v1 is stable for same input stream" {
    var a = Fingerprint64V1.init();
    a.update("abc");
    a.addU64(42);

    var b = Fingerprint64V1.init();
    b.update("abc");
    b.addU64(42);

    try testing.expectEqual(a.final(), b.final());
}

test "fingerprint v1 streaming invariant: split input equals concatenated input" {
    var concat = Fingerprint64V1.init();
    concat.update("abcdef");

    var split = Fingerprint64V1.init();
    split.update("abc");
    split.update("def");

    try testing.expectEqual(concat.final(), split.final());
}

test "fingerprint v1 streaming invariant: single-byte splits" {
    var whole = Fingerprint64V1.init();
    whole.update("hello");

    var bytewise = Fingerprint64V1.init();
    for ("hello") |b| {
        bytewise.update(&.{b});
    }

    try testing.expectEqual(whole.final(), bytewise.final());
}

test "fingerprint v1 different inputs produce different results" {
    var a = Fingerprint64V1.init();
    a.update("hello");

    var b = Fingerprint64V1.init();
    b.update("world");

    try testing.expect(a.final() != b.final());
}
