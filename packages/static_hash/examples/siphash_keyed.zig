const std = @import("std");
const hash = @import("static_hash");

pub fn main() !void {
    // SipHash requires an explicit key for DoS resistance.
    const key = hash.siphash.keyFromU64s(0x0123456789ABCDEF, 0xFEDCBA9876543210);
    const h = hash.siphash.hash64_24(&key, "untrusted input");
    std.debug.print("siphash64_24(\"untrusted input\") = 0x{x}\n", .{h});
}
