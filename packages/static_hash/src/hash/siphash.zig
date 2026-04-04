//! SipHash - Keyed Hashing for Untrusted Inputs.
//!
//! SipHash is a keyed PRF designed to protect hash tables against adversarial
//! inputs (hash-flooding DoS). When input includes untrusted content, a secret
//! key is required to make the hash output unpredictable to an attacker.
//!
//! This module wraps Zig std's SipHash implementation and provides one-shot helpers.
//!
//! ## Thread Safety
//! - One-shot helpers (`hash64_24`, `hash128_24`): unrestricted (pure functions).
//! - Streaming hashers (`SipHash64_24`, etc.): none (single-threaded per instance).
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).
//!
//! ## Design
//! - Explicit key required (no hidden randomness).
//! - Multiple round configurations for different security/performance tradeoffs:
//!   - 1-3: fast, lower security margin.
//!   - 2-4: standard (recommended default).
//!   - 4-8: conservative, higher security margin.

const std = @import("std");

/// A 128-bit SipHash key, stored as 16 bytes.
pub const Key = [16]u8;

/// Build a SipHash key from two u64 words, encoded little-endian.
///
/// Postconditions: returns a 16-byte key suitable for any SipHash variant.
/// Round-trip integrity: the returned key decodes back to k0 and k1.
pub fn keyFromU64s(k0: u64, k1: u64) Key {
    var key: Key = undefined;
    std.mem.writeInt(u64, key[0..8], k0, .little);
    std.mem.writeInt(u64, key[8..16], k1, .little);
    // Postcondition: round-trip integrity.
    std.debug.assert(std.mem.readInt(u64, key[0..8], .little) == k0);
    std.debug.assert(std.mem.readInt(u64, key[8..16], .little) == k1);
    return key;
}

fn makeSipHasher64(comptime c_rounds: usize, comptime d_rounds: usize) type {
    return struct {
        const Raw = std.crypto.auth.siphash.SipHash64(c_rounds, d_rounds);

        ctx: Raw,

        pub fn init(key: *const Key) @This() {
            std.debug.assert(@intFromPtr(key) != 0);
            return .{ .ctx = Raw.init(key) };
        }

        pub fn update(self: *@This(), msg: []const u8) void {
            std.debug.assert(msg.len == 0 or @intFromPtr(msg.ptr) != 0);
            self.ctx.update(msg);
        }

        pub fn final(self: *@This()) u64 {
            var out: [8]u8 = undefined;
            self.ctx.final(&out);
            return std.mem.readInt(u64, &out, .little);
        }
    };
}

fn makeSipHasher128(comptime c_rounds: usize, comptime d_rounds: usize) type {
    return struct {
        const Raw = std.crypto.auth.siphash.SipHash128(c_rounds, d_rounds);

        ctx: Raw,

        pub fn init(key: *const Key) @This() {
            std.debug.assert(@intFromPtr(key) != 0);
            return .{ .ctx = Raw.init(key) };
        }

        pub fn update(self: *@This(), msg: []const u8) void {
            std.debug.assert(msg.len == 0 or @intFromPtr(msg.ptr) != 0);
            self.ctx.update(msg);
        }

        pub fn final(self: *@This()) u128 {
            var out: [16]u8 = undefined;
            self.ctx.final(&out);
            return std.mem.readInt(u128, &out, .little);
        }
    };
}

pub const SipHasher64_13 = makeSipHasher64(1, 3);
pub const SipHasher64_24 = makeSipHasher64(2, 4);
pub const SipHasher64_48 = makeSipHasher64(4, 8);

pub const SipHasher128_13 = makeSipHasher128(1, 3);
pub const SipHasher128_24 = makeSipHasher128(2, 4);
pub const SipHasher128_48 = makeSipHasher128(4, 8);

// Raw std round configurations for callers that need the upstream surface.
pub const StdSipHash64_13 = std.crypto.auth.siphash.SipHash64(1, 3);
pub const StdSipHash64_24 = std.crypto.auth.siphash.SipHash64(2, 4);
pub const StdSipHash64_48 = std.crypto.auth.siphash.SipHash64(4, 8);

pub const StdSipHash128_13 = std.crypto.auth.siphash.SipHash128(1, 3);
pub const StdSipHash128_24 = std.crypto.auth.siphash.SipHash128(2, 4);
pub const StdSipHash128_48 = std.crypto.auth.siphash.SipHash128(4, 8);

// Backward-compatible raw std re-exports.
pub const SipHash64_13 = StdSipHash64_13;
pub const SipHash64_24 = StdSipHash64_24;
pub const SipHash64_48 = StdSipHash64_48;

pub const SipHash128_13 = StdSipHash128_13;
pub const SipHash128_24 = StdSipHash128_24;
pub const SipHash128_48 = StdSipHash128_48;

/// One-shot SipHash-2-4 with 64-bit output.
///
/// Preconditions: key must be a valid 16-byte key pointer.
/// Postconditions: returns deterministic 64-bit keyed hash of msg.
pub fn hash64_24(key: *const Key, msg: []const u8) u64 {
    // Precondition: key pointer must be valid.
    std.debug.assert(@intFromPtr(key) != 0);
    // Precondition: non-empty message must have valid pointer.
    std.debug.assert(msg.len == 0 or @intFromPtr(msg.ptr) != 0);
    var h = SipHash64_24.init(key);
    h.update(msg);
    var out: [8]u8 = undefined;
    h.final(&out);
    return std.mem.readInt(u64, &out, .little);
}

/// One-shot SipHash-2-4 with 128-bit output.
///
/// Preconditions: key must be a valid 16-byte key pointer.
/// Postconditions: returns deterministic 128-bit keyed hash of msg.
pub fn hash128_24(key: *const Key, msg: []const u8) u128 {
    // Precondition: key pointer must be valid.
    std.debug.assert(@intFromPtr(key) != 0);
    // Precondition: non-empty message must have valid pointer.
    std.debug.assert(msg.len == 0 or @intFromPtr(msg.ptr) != 0);
    var h = SipHash128_24.init(key);
    h.update(msg);
    var out: [16]u8 = undefined;
    h.final(&out);
    return std.mem.readInt(u128, &out, .little);
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: validate determinism, key separation, and published reference vectors for SipHash-2-4.

test "siphash hash64_24 deterministic" {
    const key = keyFromU64s(1, 2);
    try std.testing.expectEqual(hash64_24(&key, "hello"), hash64_24(&key, "hello"));
    try std.testing.expect(hash64_24(&key, "hello") != hash64_24(&key, "world"));
}

test "siphash hash64_24 differs across keys" {
    const k1 = keyFromU64s(1, 2);
    const k2 = keyFromU64s(3, 4);
    try std.testing.expect(hash64_24(&k1, "hello") != hash64_24(&k2, "hello"));
}

test "siphash hash128_24 deterministic" {
    const key = keyFromU64s(0xABCD, 0xEF01);
    try std.testing.expectEqual(hash128_24(&key, "test"), hash128_24(&key, "test"));
}

test "siphash hash128_24 differs across keys" {
    const k1 = keyFromU64s(1, 2);
    const k2 = keyFromU64s(3, 4);
    try std.testing.expect(hash128_24(&k1, "data") != hash128_24(&k2, "data"));
}

test "siphash keyFromU64s produces correct layout" {
    const key = keyFromU64s(0x0123456789ABCDEF, 0xFEDCBA9876543210);
    // First 8 bytes are k0 in little-endian.
    try std.testing.expectEqual(@as(u64, 0x0123456789ABCDEF), std.mem.readInt(u64, key[0..8], .little));
    // Last 8 bytes are k1 in little-endian.
    try std.testing.expectEqual(@as(u64, 0xFEDCBA9876543210), std.mem.readInt(u64, key[8..16], .little));
}

test "siphash-2-4 reference vectors" {
    // Reference vectors from the SipHash paper (Aumasson & Bernstein).
    // Key: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f.
    const key = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    // Empty message.
    try std.testing.expectEqual(@as(u64, 0x726fdb47dd0e0e31), hash64_24(&key, ""));
    // Message: 00.
    try std.testing.expectEqual(@as(u64, 0x74f839c593dc67fd), hash64_24(&key, &[_]u8{0}));
    // Message: 00 01 02 03 04 05 06.
    try std.testing.expectEqual(
        @as(u64, 0xab0200f58b01d137),
        hash64_24(&key, &[_]u8{ 0, 1, 2, 3, 4, 5, 6 }),
    );
}

test "siphash streaming wrappers match one-shot helpers" {
    const key = keyFromU64s(0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210);

    var hasher64 = SipHasher64_24.init(&key);
    hasher64.update("hello ");
    hasher64.update("world");
    try std.testing.expectEqual(hash64_24(&key, "hello world"), hasher64.final());

    var hasher128 = SipHasher128_24.init(&key);
    hasher128.update("hello ");
    hasher128.update("world");
    try std.testing.expectEqual(hash128_24(&key, "hello world"), hasher128.final());
}

test "siphash raw std re-exports remain available" {
    const key = keyFromU64s(1, 2);
    var raw64 = SipHash64_24.init(&key);
    raw64.update("hello");
    var out64: [8]u8 = undefined;
    raw64.final(&out64);
    try std.testing.expectEqual(hash64_24(&key, "hello"), std.mem.readInt(u64, &out64, .little));

    var raw128 = SipHash128_24.init(&key);
    raw128.update("hello");
    var out128: [16]u8 = undefined;
    raw128.final(&out128);
    try std.testing.expectEqual(hash128_24(&key, "hello"), std.mem.readInt(u128, &out128, .little));
}
