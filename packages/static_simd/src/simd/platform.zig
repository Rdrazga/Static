//! Platform detection and SIMD capabilities.
//!
//! Provides comptime-known platform identification and capability queries.
//! The caller chooses vector widths; this module reports what hardware supports.

const std = @import("std");
const builtin = @import("builtin");

/// Detected SIMD platform tier.
pub const Platform = enum {
    x86_64_sse2,
    x86_64_sse4_1,
    x86_64_avx,
    x86_64_avx2,
    x86_64_avx512f,
    arm64_neon,
    arm64_sve,
    wasm_simd128,
    scalar,
};

/// Comptime-detected best available platform.
pub const platform: Platform = detect();

fn detect() Platform {
    const arch = builtin.cpu.arch;
    const features = builtin.cpu.features;

    if (arch == .x86_64) {
        if (features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx512f))) {
            return .x86_64_avx512f;
        }
        if (features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
            return .x86_64_avx2;
        }
        if (features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx))) {
            return .x86_64_avx;
        }
        if (features.isEnabled(@intFromEnum(std.Target.x86.Feature.sse4_1))) {
            return .x86_64_sse4_1;
        }
        if (features.isEnabled(@intFromEnum(std.Target.x86.Feature.sse2))) {
            return .x86_64_sse2;
        }
    }

    if (arch == .aarch64) {
        // SVE detection: check for sve feature flag.
        if (features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.sve))) {
            return .arm64_sve;
        }
        // NEON is always available on aarch64.
        return .arm64_neon;
    }

    if (arch == .wasm32 or arch == .wasm64) {
        if (features.isEnabled(@intFromEnum(std.Target.wasm.Feature.simd128))) {
            return .wasm_simd128;
        }
    }

    return .scalar;
}

/// Capability queries for the current compile target.
pub const Capabilities = struct {
    pub fn hasAvx512() bool {
        return platform == .x86_64_avx512f;
    }

    pub fn hasAvx() bool {
        return switch (platform) {
            .x86_64_avx, .x86_64_avx2, .x86_64_avx512f => true,
            else => false,
        };
    }

    pub fn hasFma() bool {
        if (builtin.cpu.arch == .x86_64) {
            return builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.fma));
        }
        return switch (platform) {
            .arm64_neon, .arm64_sve => true,
            else => false,
        };
    }

    /// Maximum hardware vector width in bits.
    /// Returns 128 for scalar (Zig scalarizes wider vectors).
    pub fn maxVectorWidthBits() u32 {
        return switch (platform) {
            .x86_64_avx512f => 512,
            .x86_64_avx, .x86_64_avx2 => 256,
            .x86_64_sse2, .x86_64_sse4_1 => 128,
            .arm64_neon => 128,
            .arm64_sve => 128, // SVE minimum guaranteed width; actual width is runtime-variable.
            .wasm_simd128 => 128,
            .scalar => 128,
        };
    }
};

test "platform detection returns a valid variant" {
    // The detected platform must be one of the enum values.
    const p = platform;
    _ = p;
    // Capabilities must be consistent with the platform.
    if (Capabilities.hasAvx512()) {
        std.debug.assert(Capabilities.hasAvx());
        std.debug.assert(Capabilities.maxVectorWidthBits() >= 512);
    }
    if (Capabilities.hasAvx()) {
        std.debug.assert(Capabilities.maxVectorWidthBits() >= 256);
    }
    if (builtin.cpu.arch == .x86_64 and Capabilities.hasFma()) {
        std.debug.assert(Capabilities.hasAvx());
    }
    const width = Capabilities.maxVectorWidthBits();
    std.debug.assert(width == 128 or width == 256 or width == 512);
}
