//! FNV-1a Hash - Simple, Portable Hash for Small Keys.
//!
//! FNV-1a is a non-cryptographic hash with good distribution for small inputs.
//! It processes one byte at a time (XOR-then-multiply), making it simple to
//! implement and verify but slower than Wyhash for large buffers.
//!
//! ## Thread Safety
//! - Stateful hashers (`Fnv1a32`, `Fnv1a64`): none (single-threaded per instance).
//! - One-shot functions (`hash32`, `hash64`): unrestricted (pure functions).
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).

const std = @import("std");

/// FNV-1a 32-bit hash.
///
/// Streaming hasher: call `update()` one or more times, then `final()`.
/// For one-shot hashing, use `Fnv1a32.hash()` or the module-level `hash32()`.
pub const Fnv1a32 = struct {
    const offset_basis: u32 = 0x811C9DC5;
    const prime: u32 = 0x01000193;

    state: u32,

    /// Initialize with a seed. Seed is XOR'd into the offset basis.
    ///
    /// Postconditions: state is offset_basis ^ seed.
    pub fn init(seed: u32) Fnv1a32 {
        comptime {
            std.debug.assert(offset_basis != 0);
            std.debug.assert(prime != 0);
        }
        return .{ .state = offset_basis ^ seed };
    }

    /// Initialize with the default seed (0).
    ///
    /// Postconditions: state is the canonical FNV-1a offset basis.
    pub fn initDefault() Fnv1a32 {
        return init(0);
    }

    /// Feed `data` into the hasher state.
    ///
    /// Preconditions: if data.len > 0, data.ptr must be non-null.
    /// Postconditions: internal state updated with every byte of data.
    pub fn update(self: *Fnv1a32, data: []const u8) void {
        std.debug.assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
        for (data) |byte| {
            self.state ^= byte;
            self.state *%= prime;
        }
    }

    /// Finalize and return the hash value.
    ///
    /// Postconditions: returns accumulated hash; hasher state is unchanged.
    pub fn final(self: *const Fnv1a32) u32 {
        return self.state;
    }

    /// One-shot hash of data.
    ///
    /// Postconditions: returns FNV-1a 32-bit hash of entire input.
    pub fn hash(data: []const u8) u32 {
        var hasher = Fnv1a32.initDefault();
        hasher.update(data);
        return hasher.final();
    }
};

/// FNV-1a 64-bit hash.
///
/// Streaming hasher: call `update()` one or more times, then `final()`.
/// For one-shot hashing, use `Fnv1a64.hash()` or the module-level `hash64()`.
pub const Fnv1a64 = struct {
    const offset_basis: u64 = 0xCBF29CE484222325;
    const prime: u64 = 0x100000001B3;

    state: u64,

    /// Initialize with a seed. Seed is XOR'd into the offset basis.
    ///
    /// Postconditions: state is offset_basis ^ seed.
    pub fn init(seed: u64) Fnv1a64 {
        comptime {
            std.debug.assert(offset_basis != 0);
            std.debug.assert(prime != 0);
        }
        return .{ .state = offset_basis ^ seed };
    }

    /// Initialize with the default seed (0).
    ///
    /// Postconditions: state is the canonical FNV-1a offset basis.
    pub fn initDefault() Fnv1a64 {
        return init(0);
    }

    /// Feed `data` into the hasher state.
    ///
    /// Preconditions: if data.len > 0, data.ptr must be non-null.
    /// Postconditions: internal state updated with every byte of data.
    pub fn update(self: *Fnv1a64, data: []const u8) void {
        std.debug.assert(data.len == 0 or @intFromPtr(data.ptr) != 0);
        for (data) |byte| {
            self.state ^= byte;
            self.state *%= prime;
        }
    }

    /// Finalize and return the hash value.
    ///
    /// Postconditions: returns accumulated hash; hasher state is unchanged.
    pub fn final(self: *const Fnv1a64) u64 {
        return self.state;
    }

    /// One-shot hash of data.
    ///
    /// Postconditions: returns FNV-1a 64-bit hash of entire input.
    pub fn hash(data: []const u8) u64 {
        var hasher = Fnv1a64.initDefault();
        hasher.update(data);
        return hasher.final();
    }
};

/// One-shot FNV-1a 32-bit hash with explicit seed.
///
/// Postconditions: returns deterministic 32-bit hash of bytes for given seed.
pub fn hash32(seed: u32, bytes: []const u8) u32 {
    var h = Fnv1a32.init(seed);
    h.update(bytes);
    return h.final();
}

/// One-shot FNV-1a 64-bit hash with explicit seed.
///
/// Postconditions: returns deterministic 64-bit hash of bytes for given seed.
pub fn hash64(seed: u64, bytes: []const u8) u64 {
    var h = Fnv1a64.init(seed);
    h.update(bytes);
    return h.final();
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: lock in known vectors, exercise empty/seeded behavior, and validate streaming equivalence.

test "fnv1a vectors are stable" {
    // Known FNV-1a vectors. These values must never change.
    try std.testing.expectEqual(@as(u32, 0x4F9F2CAB), hash32(0, "hello"));
    try std.testing.expectEqual(@as(u64, 0xA430D84680AABD0B), hash64(0, "hello"));
}

test "fnv1a empty input returns offset basis" {
    // FNV-1a of empty input with seed 0 is the unmodified offset basis.
    try std.testing.expectEqual(@as(u32, 0x811C9DC5), hash32(0, ""));
    try std.testing.expectEqual(@as(u64, 0xCBF29CE484222325), hash64(0, ""));
}

test "fnv1a different inputs produce different hashes" {
    const a = hash32(0, "hello");
    const b = hash32(0, "world");
    try std.testing.expect(a != b);
}

test "fnv1a seed changes output" {
    const seeded = hash64(1, "hello");
    const default = hash64(0, "hello");
    try std.testing.expect(seeded != default);
}

test "fnv1a incremental update matches one-shot" {
    var h = Fnv1a32.initDefault();
    h.update("hel");
    h.update("lo");
    try std.testing.expectEqual(hash32(0, "hello"), h.final());
}

test "fnv1a64 static hash matches module-level hash" {
    try std.testing.expectEqual(Fnv1a64.hash("hello"), hash64(0, "hello"));
    try std.testing.expectEqual(Fnv1a32.hash("hello"), hash32(0, "hello"));
}

test "fnv1a64 streaming matches one-shot" {
    const data = "hello world";
    var hasher = Fnv1a64.initDefault();
    hasher.update(data[0..5]);
    hasher.update(data[5..]);
    try std.testing.expectEqual(Fnv1a64.hash(data), hasher.final());
}

test "fnv1a streaming equivalence at random split points" {
    // Property: for any split point, streaming update produces the same hash as one-shot.
    const input = "The quick brown fox jumps over the lazy dog";
    const expected32 = hash32(0, input);
    const expected64 = hash64(0, input);

    // Use a simple PRNG to generate split points.
    var rng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = rng.random();

    for (0..100) |_| {
        const split = random.uintAtMost(usize, input.len);

        var h32 = Fnv1a32.initDefault();
        h32.update(input[0..split]);
        h32.update(input[split..]);
        try std.testing.expectEqual(expected32, h32.final());

        var h64 = Fnv1a64.initDefault();
        h64.update(input[0..split]);
        h64.update(input[split..]);
        try std.testing.expectEqual(expected64, h64.final());
    }
}
