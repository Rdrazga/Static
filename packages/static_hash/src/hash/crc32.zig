//! CRC32 - Cyclic Redundancy Checks.
//!
//! Provides CRC32 (IEEE polynomial, used in Ethernet/ZIP) and CRC32C (Castagnoli
//! polynomial, hardware-accelerated on x86 SSE4.2 and aarch64 CRC extension).
//!
//! ## Thread Safety
//! - Stateful hashers (`Crc32`, `Crc32c`): none (single-threaded per instance).
//! - One-shot functions (`checksum`, `checksumCastagnoli`): unrestricted (pure).
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).
//!
//! ## Design
//! - CRC32 (IEEE) is the standard checksum for network/storage protocols.
//! - CRC32C (Castagnoli) is preferred when hardware acceleration is available
//!   (used by ext4, RocksDB, SCTP). On x86/x86_64 with SSE4.2, the CPU provides
//!   dedicated CRC32C instructions. On aarch64 with the CRC extension, both
//!   CRC32 and CRC32C are hardware-accelerated.

const std = @import("std");
const builtin = @import("builtin");

/// Direct std re-export for callers that need the raw IEEE CRC32 type.
pub const StdCrc32 = std.hash.Crc32;

/// Direct std re-export for callers that need the raw Castagnoli CRC32C type.
pub const StdCrc32c = std.hash.crc.Crc32Iscsi;

// =============================================================================
// CRC32 IEEE
// =============================================================================

/// CRC32 with the IEEE polynomial (0xEDB88320 reflected).
///
/// Streaming hasher: call `update()` one or more times, then `final()`.
pub const Crc32 = struct {
    ctx: std.hash.Crc32 = .init(),

    /// Initialize a new CRC32 IEEE hasher.
    ///
    /// Postconditions: internal state is the CRC32 initial value.
    pub fn init() Crc32 {
        return .{};
    }

    /// Feed `bytes` into the checksum.
    ///
    /// Preconditions: if bytes.len > 0, bytes.ptr must be non-null.
    /// Postconditions: internal state updated with bytes.
    pub fn update(self: *Crc32, bytes: []const u8) void {
        std.debug.assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
        self.ctx.update(bytes);
    }

    /// Finalize and return the CRC32 checksum.
    ///
    /// Postconditions: returns accumulated CRC32 value.
    pub fn final(self: *Crc32) u32 {
        return self.ctx.final();
    }
};

/// One-shot CRC32 IEEE checksum.
///
/// Postconditions: returns deterministic CRC32 of bytes.
pub fn checksum(bytes: []const u8) u32 {
    var ctx = Crc32.init();
    ctx.update(bytes);
    return ctx.final();
}

// =============================================================================
// CRC32C Castagnoli
// =============================================================================

/// CRC32C with the Castagnoli polynomial.
///
/// On x86/x86_64 with SSE4.2, this uses hardware CRC32C instructions.
/// On aarch64 with the CRC extension, hardware acceleration is available.
/// Streaming hasher: call `update()` one or more times, then `final()`.
pub const Crc32c = struct {
    ctx: std.hash.crc.Crc32Iscsi = .init(),

    /// Initialize a new CRC32C hasher.
    ///
    /// Postconditions: internal state is the CRC32C initial value.
    pub fn init() Crc32c {
        return .{};
    }

    /// Feed `bytes` into the checksum.
    ///
    /// Preconditions: if bytes.len > 0, bytes.ptr must be non-null.
    /// Postconditions: internal state updated with bytes.
    pub fn update(self: *Crc32c, bytes: []const u8) void {
        std.debug.assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
        self.ctx.update(bytes);
    }

    /// Finalize and return the CRC32C checksum.
    ///
    /// Postconditions: returns accumulated CRC32C value.
    pub fn final(self: *Crc32c) u32 {
        return self.ctx.final();
    }
};

/// One-shot CRC32C Castagnoli checksum.
///
/// Postconditions: returns deterministic CRC32C of bytes.
pub fn checksumCastagnoli(bytes: []const u8) u32 {
    var ctx = Crc32c.init();
    ctx.update(bytes);
    return ctx.final();
}

// =============================================================================
// Hardware Detection
// =============================================================================

/// Check if the build target has CPU instructions for CRC32-family operations.
///
/// Postconditions:
/// - Returns true if the target CPU features include:
///   - x86/x86_64: SSE4.2 (CRC32C instructions; Castagnoli polynomial)
///   - aarch64: `+crc` (CRC32 and CRC32C instructions)
/// - This is a build-target feature check, not a runtime probe.
pub fn hasCrc32Hardware() bool {
    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2),
        .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc),
        else => false,
    };
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: validate against published check vectors, and ensure streaming updates match one-shot helpers.

test "crc32 known vector" {
    // Check value from the CRC-32/ISO-HDLC standard: "123456789" -> 0xCBF43926.
    try std.testing.expectEqual(@as(u32, 0xCBF43926), checksum("123456789"));
}

test "crc32 empty input is stable" {
    const v = checksum("");
    try std.testing.expectEqual(v, checksum(""));
}

test "crc32 incremental matches one-shot" {
    var ctx = Crc32.init();
    ctx.update("123456");
    ctx.update("789");
    try std.testing.expectEqual(checksum("123456789"), ctx.final());
}

test "crc32 different inputs differ" {
    try std.testing.expect(checksum("hello") != checksum("world"));
}

test "crc32c one-shot is deterministic" {
    const a = checksumCastagnoli("hello");
    const b = checksumCastagnoli("hello");
    try std.testing.expectEqual(a, b);
}

test "crc32c incremental matches one-shot" {
    var ctx = Crc32c.init();
    ctx.update("hel");
    ctx.update("lo");
    try std.testing.expectEqual(checksumCastagnoli("hello"), ctx.final());
}

test "crc32c differs from crc32 ieee" {
    // The two polynomials must produce different results for non-trivial input.
    const ieee = checksum("hello");
    const castagnoli = checksumCastagnoli("hello");
    try std.testing.expect(ieee != castagnoli);
}

test "crc32c known vector" {
    // Check value from the CRC-32C/iSCSI standard: "123456789" -> 0xE3069283.
    try std.testing.expectEqual(@as(u32, 0xE3069283), checksumCastagnoli("123456789"));
}

test "crc32 wrappers match raw std implementations" {
    var raw_ieee = StdCrc32.init();
    raw_ieee.update("static ");
    raw_ieee.update("hash");
    try std.testing.expectEqual(checksum("static hash"), raw_ieee.final());

    var raw_castagnoli = StdCrc32c.init();
    raw_castagnoli.update("static ");
    raw_castagnoli.update("hash");
    try std.testing.expectEqual(checksumCastagnoli("static hash"), raw_castagnoli.final());
}

test "crc32 raw std re-exports remain available" {
    var raw_ieee = StdCrc32.init();
    raw_ieee.update("hello");
    try std.testing.expectEqual(checksum("hello"), raw_ieee.final());

    var raw_castagnoli = StdCrc32c.init();
    raw_castagnoli.update("hello");
    try std.testing.expectEqual(checksumCastagnoli("hello"), raw_castagnoli.final());
}

test "hasCrc32Hardware compiles" {
    _ = hasCrc32Hardware();
}
