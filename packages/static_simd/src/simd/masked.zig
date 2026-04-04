//! Lane masks — boolean vector wrappers for conditional SIMD operations.
//!
//! Each mask wraps a `@Vector(N, bool)` and provides construction from
//! bit patterns, conversion back to bits, and aggregate queries.

const std = @import("std");

pub const Mask2 = MaskType(2);
pub const Mask4 = MaskType(4);
pub const Mask8 = MaskType(8);
pub const Mask16 = MaskType(16);

// Aliases for documentation clarity in typed contexts.
pub const Mask4d = Mask4;
pub const Mask8i = Mask8;

fn MaskType(comptime N: u32) type {
    const IntN = std.meta.Int(.unsigned, N);
    return struct {
        const Self = @This();

        v: @Vector(N, bool),

        pub inline fn splat(val: bool) Self {
            return .{ .v = @splat(val) };
        }

        /// Construct from a bit pattern. Bit 0 maps to lane 0.
        pub inline fn fromBits(bits: IntN) Self {
            var result: @Vector(N, bool) = @splat(false);
            inline for (0..N) |i| {
                result[i] = (bits >> @intCast(i)) & 1 == 1;
            }
            return .{ .v = result };
        }

        /// Convert to a bit pattern. Lane 0 maps to bit 0.
        pub inline fn toBits(self: Self) IntN {
            var result: IntN = 0;
            inline for (0..N) |i| {
                if (self.v[i]) {
                    result |= @as(IntN, 1) << @intCast(i);
                }
            }
            return result;
        }

        /// True if any lane is set.
        pub inline fn any(self: Self) bool {
            return @reduce(.Or, self.v);
        }

        /// True if all lanes are set.
        pub inline fn all(self: Self) bool {
            return @reduce(.And, self.v);
        }
    };
}

test "Mask4 fromBits -> toBits roundtrip" {
    // Test all 16 possible 4-bit patterns.
    inline for (0..16) |i| {
        const bits: u4 = @intCast(i);
        const mask = Mask4.fromBits(bits);
        try std.testing.expectEqual(bits, mask.toBits());
    }
}

test "Mask4 splat and aggregate" {
    const all_true = Mask4.splat(true);
    try std.testing.expect(all_true.all());
    try std.testing.expect(all_true.any());
    try std.testing.expectEqual(@as(u4, 0b1111), all_true.toBits());

    const all_false = Mask4.splat(false);
    try std.testing.expect(!all_false.all());
    try std.testing.expect(!all_false.any());
    try std.testing.expectEqual(@as(u4, 0b0000), all_false.toBits());
}

test "Mask2 roundtrip" {
    inline for (0..4) |i| {
        const bits: u2 = @intCast(i);
        const mask = Mask2.fromBits(bits);
        try std.testing.expectEqual(bits, mask.toBits());
    }
}

test "Mask8 any/all" {
    const one_set = Mask8.fromBits(0b00010000);
    try std.testing.expect(one_set.any());
    try std.testing.expect(!one_set.all());

    const all_set = Mask8.fromBits(0b11111111);
    try std.testing.expect(all_set.all());
}

test "Mask8 fromBits -> toBits roundtrip" {
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const bits: u8 = @intCast(i);
        const mask = Mask8.fromBits(bits);
        try std.testing.expectEqual(bits, mask.toBits());
    }
}

test "Mask16 fromBits -> toBits roundtrip" {
    var i: u32 = 0;
    while (i <= std.math.maxInt(u16)) : (i += 1) {
        const bits: u16 = @intCast(i);
        const mask = Mask16.fromBits(bits);
        try std.testing.expectEqual(bits, mask.toBits());
    }

    try std.testing.expect(!Mask16.fromBits(0).any());
    try std.testing.expect(Mask16.fromBits(0xFFFF).all());
}
