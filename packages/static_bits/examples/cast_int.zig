//! Demonstrates checked integer casts with explicit overflow classification.

const std = @import("std");
const bits = @import("static_bits");

pub fn main() !void {
    const small = try bits.cast.castInt(u8, @as(u16, 42));
    std.debug.assert(small == 42);

    if (bits.cast.castInt(u8, @as(i16, -1))) |_| {
        unreachable;
    } else |err| {
        std.debug.assert(err == error.Underflow);
    }

    if (bits.cast.castInt(u8, @as(u16, 300))) |_| {
        unreachable;
    } else |err| {
        std.debug.assert(err == error.Overflow);
    }
}
