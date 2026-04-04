//! Wyhash - Zig's Default High-Quality Hash.
//!
//! Wyhash provides excellent speed and distribution quality. It is Zig's default
//! hash function for `std.HashMap` and the recommended general-purpose hash for
//! most use cases.
//!
//! This module wraps `std.hash.Wyhash` with a consistent API that matches the
//! other hashers in this package.
//!
//! ## Thread Safety
//! - Stateful hasher (`Wyhash64`): none (single-threaded per instance).
//! - One-shot functions (`hash`, `hashSeeded`): unrestricted (pure functions).
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).

const std = @import("std");

/// Wyhash 64-bit streaming hasher.
///
/// Wraps `std.hash.Wyhash` with a uniform init/update/final interface.
pub const Wyhash64 = struct {
    ctx: std.hash.Wyhash,
    /// Debug-only guard against calling final() twice. `std.hash.Wyhash.final()`
    /// mutates internal state, so a second call produces undefined results.
    finalized: if (std.debug.runtime_safety) bool else void =
        if (std.debug.runtime_safety) false else {},

    /// Initialize with an explicit seed.
    ///
    /// Postconditions: hasher is ready to accept data.
    pub fn init(seed: u64) Wyhash64 {
        const result: Wyhash64 = .{ .ctx = std.hash.Wyhash.init(seed) };
        // Postcondition: finalization guard is in the initial (not-finalized) state.
        if (comptime std.debug.runtime_safety) {
            std.debug.assert(!result.finalized);
        }
        return result;
    }

    /// Initialize with the default seed (0).
    ///
    /// Postconditions: hasher is ready to accept data with the unseeded path.
    pub fn initDefault() Wyhash64 {
        return init(0);
    }

    /// Feed `bytes` into the hasher.
    ///
    /// Preconditions: if bytes.len > 0, bytes.ptr must be non-null.
    /// Postconditions: internal state updated with bytes.
    pub fn update(self: *Wyhash64, bytes: []const u8) void {
        // Precondition: non-empty slices must have a valid pointer.
        std.debug.assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
        self.ctx.update(bytes);
    }

    /// Finalize and return the 64-bit hash.
    ///
    /// Takes `*Wyhash64` (not `*const`) because `std.hash.Wyhash.final()` mutates
    /// internal state during finalization. This means the hasher is consumed;
    /// calling `final()` twice is a programmer error (enforced by debug assertion).
    ///
    /// Postconditions: returns 64-bit hash of all data fed via update().
    pub fn final(self: *Wyhash64) u64 {
        // Precondition: final() must not be called twice.
        if (comptime std.debug.runtime_safety) {
            std.debug.assert(!self.finalized);
        }
        const result = self.ctx.final();
        if (comptime std.debug.runtime_safety) {
            self.finalized = true;
        }
        return result;
    }
};

/// Re-export of `std.hash.Wyhash` for direct use.
///
/// Prefer `Wyhash64` for the streaming interface or `hash()`/`hashSeeded()`
/// for one-shot use.
pub const Wyhash = std.hash.Wyhash;

/// One-shot Wyhash with seed 0.
///
/// Preconditions: if bytes.len > 0, bytes.ptr must be non-null.
/// Postconditions: returns deterministic 64-bit hash of bytes.
pub fn hash(bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
    return std.hash.Wyhash.hash(0, bytes);
}

/// Alias for `hash()` using the package-wide `hash64` naming style.
pub fn hash64(bytes: []const u8) u64 {
    return hash(bytes);
}

/// One-shot Wyhash with an explicit seed.
///
/// Preconditions: if bytes.len > 0, bytes.ptr must be non-null.
/// Postconditions: returns deterministic 64-bit hash of bytes for given seed.
pub fn hashSeeded(seed: u64, bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
    return std.hash.Wyhash.hash(seed, bytes);
}

/// Alias for `hashSeeded()` using the package-wide `hash64Seeded` naming style.
pub fn hash64Seeded(seed: u64, bytes: []const u8) u64 {
    return hashSeeded(seed, bytes);
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: validate determinism, seed separation, streaming equivalence, and a small set of pinned vectors.

test "wyhash is deterministic for a given seed" {
    try std.testing.expectEqual(hash("abc"), hash("abc"));
    try std.testing.expectEqual(hashSeeded(42, "abc"), hashSeeded(42, "abc"));
}

test "wyhash seed changes output" {
    try std.testing.expect(hashSeeded(42, "abc") != hashSeeded(43, "abc"));
}

test "wyhash different inputs produce different hashes" {
    try std.testing.expect(hash("hello") != hash("world"));
}

test "wyhash empty input is stable" {
    const a = hash("");
    const b = hash("");
    try std.testing.expectEqual(a, b);
}

test "wyhash streaming matches one-shot" {
    var h = Wyhash64.initDefault();
    h.update("hel");
    h.update("lo");
    try std.testing.expectEqual(hash("hello"), h.final());
}

test "wyhash aliases match direct entrypoints" {
    try std.testing.expectEqual(hash("hello"), hash64("hello"));
    try std.testing.expectEqual(hashSeeded(42, "hello"), hash64Seeded(42, "hello"));
}

test "wyhash golden vectors are stable" {
    // Pinned output values. These must never change.
    try std.testing.expectEqual(@as(u64, 0x0409638ee2bde459), hash(""));
    try std.testing.expectEqual(@as(u64, 0x0e24bbd9f93f532d), hash("hello"));
}
