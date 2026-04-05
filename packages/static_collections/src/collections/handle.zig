//! Handle type for stable, versioned references into slot-based containers.
//!
//! Key type: `Handle`. A packed 64-bit value encoding a 32-bit index and a 32-bit
//! generation counter. The generation counter allows containers to detect stale
//! references to slots that have been freed and reused.
//!
//! A null/invalid sentinel is provided via `Handle.invalid()`.
//!
//! Thread safety: value type; no shared state.
const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

pub const Handle = packed struct {
    index: u32,
    generation: u32,

    comptime {
        if (@sizeOf(Handle) != 8) @compileError("Handle layout must remain 64 bits.");
    }

    pub fn invalid() Handle {
        const out: Handle = .{ .index = std.math.maxInt(u32), .generation = 0 };
        assert(!out.isValid());
        return out;
    }

    pub fn isValid(self: Handle) bool {
        return self.generation != 0 and self.index != std.math.maxInt(u32);
    }
};

test "handle invalid sentinel and isValid" {
    // Goal: validate handle sentinel and validity predicates across boundaries.
    // Method: check invalid sentinel, known-valid handle, and each invalid dimension.
    const h = Handle.invalid();
    assert(h.generation == 0);
    try testing.expect(!h.isValid());

    const valid: Handle = .{ .index = 0, .generation = 1 };
    assert(valid.generation != 0);
    try testing.expect(valid.isValid());

    // Generation 0 is always invalid regardless of index.
    const zero_gen: Handle = .{ .index = 0, .generation = 0 };
    try testing.expect(!zero_gen.isValid());

    // Max index sentinel is always invalid regardless of generation.
    const max_idx: Handle = .{ .index = std.math.maxInt(u32), .generation = 1 };
    try testing.expect(!max_idx.isValid());
}

test "handle remains packed to 8 bytes" {
    // Goal: keep ABI and storage expectations stable for handle-based tables.
    // Method: assert compile-time and runtime size observations match 8 bytes.
    comptime assert(@sizeOf(Handle) == 8);
    try testing.expectEqual(@as(usize, 8), @sizeOf(Handle));
}
