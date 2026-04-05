//! Backoff: exponential spin-wait backoff strategy.
//!
//! Thread safety: each caller holds its own Backoff instance; no shared state.
//! Single-threaded mode: safe to use; step() emits spin-loop hints regardless of threading mode.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const Backoff = struct {
    const max_supported_exponent: u8 = @intCast(@bitSizeOf(usize) - 1);

    exponent: u8 = 0,
    max_exponent: u8 = 10,

    pub fn reset(self: *Backoff) void {
        assert(self.exponent <= self.max_exponent);
        self.exponent = 0;
        assert(self.exponent == 0);
    }

    pub fn step(self: *Backoff) void {
        assert(self.max_exponent <= max_supported_exponent);
        assert(self.exponent <= self.max_exponent);

        const spins: usize = @as(usize, 1) << @intCast(self.exponent);
        assert(spins > 0);

        var i: usize = 0;
        while (i < spins) : (i += 1) {
            std.atomic.spinLoopHint();
        }

        if (self.exponent < self.max_exponent) self.exponent += 1;
        assert(self.exponent <= self.max_exponent);
    }
};

test "backoff step grows then resets" {
    // Goal: verify step increments exponent and reset clears it.
    // Method: step once, assert growth, then reset and recheck.
    var b = Backoff{};
    b.step();
    try testing.expect(b.exponent > 0);
    b.reset();
    try testing.expectEqual(@as(u8, 0), b.exponent);
}

test "backoff exponent saturates at max_exponent" {
    // Goal: verify exponent does not exceed configured maximum.
    // Method: step repeatedly beyond max and assert saturation.
    var b = Backoff{
        .exponent = 0,
        .max_exponent = 2,
    };

    var i: u8 = 0;
    while (i < 8) : (i += 1) b.step();
    try testing.expectEqual(@as(u8, 2), b.exponent);
}

test "backoff with zero max_exponent stays at zero" {
    // Goal: verify zero max exponent prevents growth.
    // Method: run one step and assert exponent remains zero.
    var b = Backoff{
        .exponent = 0,
        .max_exponent = 0,
    };
    b.step();
    try testing.expectEqual(@as(u8, 0), b.exponent);
}
