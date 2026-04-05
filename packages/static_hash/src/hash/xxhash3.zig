//! XxHash3 - High-Throughput Hash for Large Buffers.
//!
//! XxHash3 is optimized for large-buffer throughput (>256 bytes). For small
//! keys, prefer Wyhash or FNV-1a. This module wraps `std.hash.XxHash3`.
//!
//! ## Thread Safety
//! - One-shot functions (`hash64`, `hash64Seeded`): unrestricted (pure functions).
//! - Streaming hasher (`XxHash3`): none (single-threaded per instance).
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).
//!
//! ## Design
//! - Seeding is explicit and defaults to 0 for unkeyed use.
//! - No hidden randomness.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// XxHash3 streaming hasher with the package's uniform init/update/final shape.
pub const XxHash3_64 = struct {
    ctx: std.hash.XxHash3,
    finalized: if (std.debug.runtime_safety) bool else void =
        if (std.debug.runtime_safety) false else {},

    /// Initialize with an explicit seed.
    ///
    /// Postconditions: hasher is ready to accept data.
    pub fn init(seed: u64) XxHash3_64 {
        const result: XxHash3_64 = .{
            .ctx = std.hash.XxHash3.init(seed),
        };
        if (comptime std.debug.runtime_safety) {
            assert(!result.finalized);
        }
        return result;
    }

    /// Initialize with the default seed (0).
    ///
    /// Postconditions: hasher is ready to accept data with the unseeded path.
    pub fn initDefault() XxHash3_64 {
        return init(0);
    }

    /// Feed `data` into the hasher.
    ///
    /// Preconditions: if data.len > 0, data.ptr must be non-null.
    /// Postconditions: internal state updated with data.
    pub fn update(self: *XxHash3_64, data: []const u8) void {
        assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
        self.ctx.update(data);
    }

    /// Finalize and return the 64-bit hash.
    ///
    /// Postconditions: returns 64-bit hash of all data fed via update().
    pub fn final(self: *XxHash3_64) u64 {
        if (comptime std.debug.runtime_safety) {
            assert(!self.finalized);
        }
        const result = self.ctx.final();
        if (comptime std.debug.runtime_safety) {
            self.finalized = true;
        }
        return result;
    }
};

/// Package-default XxHash3 streaming hasher.
pub const XxHash3 = XxHash3_64;

/// Direct std re-export for callers that need the raw upstream type.
pub const StdXxHash3 = std.hash.XxHash3;

/// One-shot 64-bit hash with default seed (0).
///
/// Preconditions: if data.len > 0, data.ptr must be non-null.
/// Postconditions: returns deterministic 64-bit hash of data.
pub fn hash64(data: []const u8) u64 {
    assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
    return std.hash.XxHash3.hash(0, data);
}

/// Alias for `hash64()` using the shorter package-wide naming style.
pub fn hash(data: []const u8) u64 {
    return hash64(data);
}

/// One-shot 64-bit hash with explicit seed.
///
/// Preconditions: if data.len > 0, data.ptr must be non-null.
/// Postconditions: returns deterministic 64-bit hash of data for given seed.
pub fn hash64Seeded(seed: u64, data: []const u8) u64 {
    assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
    return std.hash.XxHash3.hash(seed, data);
}

/// Alias for `hash64Seeded()` using the shorter package-wide naming style.
pub fn hashSeeded(seed: u64, data: []const u8) u64 {
    return hash64Seeded(seed, data);
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: validate determinism, seed separation, streaming equivalence, and stable vectors.

test "xxhash3 hash64 deterministic" {
    const a = hash64("hello");
    const b = hash64("hello");
    try testing.expectEqual(a, b);
}

test "xxhash3 hash64Seeded differs across seeds" {
    const a = hash64Seeded(1, "test");
    const b = hash64Seeded(2, "test");
    try testing.expect(a != b);
}

test "xxhash3 different inputs produce different hashes" {
    try testing.expect(hash64("hello") != hash64("world"));
}

test "xxhash3 empty input is stable" {
    try testing.expectEqual(hash64(""), hash64(""));
}

test "xxhash3 streaming matches one-shot" {
    var hasher = XxHash3.initDefault();
    hasher.update("hel");
    hasher.update("lo");
    try testing.expectEqual(hash64("hello"), hasher.final());
}

test "xxhash3 seeded streaming matches one-shot" {
    var hasher = XxHash3.init(42);
    hasher.update("hello ");
    hasher.update("world");
    try testing.expectEqual(hash64Seeded(42, "hello world"), hasher.final());
}

test "xxhash3 golden vectors are stable" {
    // Pinned output values. These must never change.
    try testing.expectEqual(@as(u64, 0x2d06800538d394c2), hash64(""));
    try testing.expectEqual(@as(u64, 0x9555e8555c62dcfd), hash64("hello"));
}

test "xxhash3 aliases match direct entrypoints" {
    try testing.expectEqual(hash64("hello"), hash("hello"));
    try testing.expectEqual(hash64Seeded(42, "hello"), hashSeeded(42, "hello"));
}
