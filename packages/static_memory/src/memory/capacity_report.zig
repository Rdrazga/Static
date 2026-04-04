//! Helpers for reporting bounded capacity and usage across allocator types.
//!
//! Key types: `CapacityReport`, `CapacityUnit`.
//! Usage pattern: allocators return a `CapacityReport` from their `report()` method. Callers use
//! `remaining()` and `isSaturated()` to check headroom and saturation without accessing internals.
//! Thread safety: `CapacityReport` is a plain value type; thread safety depends on how the report
//! was obtained from the underlying allocator.
//! Memory budget: value type with no heap allocation.

const std = @import("std");

pub const CapacityUnit = enum { bytes, blocks, items };

pub const CapacityReport = struct {
    unit: CapacityUnit,
    used: u64,
    high_water: u64,
    capacity: u64,
    overflow_count: u32 = 0,

    pub fn remaining(self: CapacityReport) u64 {
        std.debug.assert(self.high_water >= self.used);
        if (self.capacity != 0) std.debug.assert(self.capacity >= self.used);

        if (self.capacity == 0) return 0;
        if (self.used >= self.capacity) return 0;
        return self.capacity - self.used;
    }

    pub fn isSaturated(self: CapacityReport) bool {
        std.debug.assert(self.high_water >= self.used);
        if (self.capacity != 0) std.debug.assert(self.capacity >= self.used);

        if (self.capacity == 0) return false;
        return self.used >= self.capacity;
    }
};

test "capacity report helper methods" {
    // Verifies boundary behavior for `remaining()`/`isSaturated()` across saturation and "no capacity" cases.
    const report = CapacityReport{ .unit = .bytes, .used = 10, .high_water = 20, .capacity = 64 };
    try std.testing.expectEqual(@as(u64, 54), report.remaining());
    try std.testing.expect(!report.isSaturated());

    const full = CapacityReport{ .unit = .bytes, .used = 64, .high_water = 64, .capacity = 64 };
    try std.testing.expectEqual(@as(u64, 0), full.remaining());
    try std.testing.expect(full.isSaturated());

    const no_capacity = CapacityReport{ .unit = .bytes, .used = 123, .high_water = 123, .capacity = 0 };
    try std.testing.expectEqual(@as(u64, 0), no_capacity.remaining());
    try std.testing.expect(!no_capacity.isSaturated());
}
