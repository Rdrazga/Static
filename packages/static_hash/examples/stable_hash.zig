const std = @import("std");
const hash = @import("static_hash");

pub fn main() !void {
    // Stable hash is cross-architecture deterministic.
    const value: u32 = 42;
    const h = hash.stableHashAny(value);
    std.debug.print("stableHashAny(42) = 0x{x}\n", .{h});

    // Stable fingerprint of raw bytes.
    const fp = hash.stableFingerprint64("hello world");
    std.debug.print("stableFingerprint64(\"hello world\") = 0x{x}\n", .{fp});
}
