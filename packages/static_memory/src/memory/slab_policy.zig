//! Policy helpers for controlling slab allocator fallbacks in different build modes.

const builtin = @import("builtin");
const std = @import("std");
const SlabConfig = @import("slab.zig").SlabConfig;

pub const SlabFallbackPolicy = enum {
    strict,
    dev_only,
    always,
};

pub fn allowLargeFallback(comptime policy: SlabFallbackPolicy) bool {
    const result = switch (policy) {
        .strict => false,
        .dev_only => builtin.mode == .Debug,
        .always => true,
    };
    // Pair assertion: `.strict` must always be false regardless of build mode.
    if (policy == .strict) std.debug.assert(!result);
    // Pair assertion: `.always` must always be true regardless of build mode.
    if (policy == .always) std.debug.assert(result);
    return result;
}

pub fn applyPolicy(cfg: SlabConfig, comptime policy: SlabFallbackPolicy) SlabConfig {
    // Precondition: configuration must have at least one class.
    std.debug.assert(cfg.class_sizes.len != 0);
    var out = cfg;
    out.allow_large_fallback = allowLargeFallback(policy);
    // Postcondition: all other config fields must be unchanged; only the fallback flag is overridden.
    std.debug.assert(out.class_sizes.ptr == cfg.class_sizes.ptr);
    return out;
}

test "SlabFallbackPolicy allowLargeFallback is build-mode gated" {
    // Verifies that `.dev_only` follows Debug builds while `.strict`/`.always` are stable across modes.
    const testing = std.testing;

    try testing.expectEqual(false, allowLargeFallback(.strict));
    try testing.expectEqual(true, allowLargeFallback(.always));
    try testing.expectEqual(builtin.mode == .Debug, allowLargeFallback(.dev_only));
}

test "slab_policy.applyPolicy overrides allow_large_fallback" {
    // Verifies that `applyPolicy()` overrides only the fallback flag while preserving other configuration fields.
    const testing = std.testing;

    const sizes = [_]u32{ 32, 64 };
    const counts = [_]u32{ 1, 2 };

    const cfg: SlabConfig = .{
        .class_sizes = &sizes,
        .class_counts = &counts,
        .allow_large_fallback = true,
    };

    const strict_cfg = applyPolicy(cfg, .strict);
    try testing.expectEqual(false, strict_cfg.allow_large_fallback);
    try testing.expectEqualSlices(u32, sizes[0..], strict_cfg.class_sizes);
    try testing.expectEqualSlices(u32, counts[0..], strict_cfg.class_counts);

    const always_cfg = applyPolicy(cfg, .always);
    try testing.expectEqual(true, always_cfg.allow_large_fallback);
}
