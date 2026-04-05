//! Morton code (Z-order curve) encoding for 2D and 3D integer coordinates.
//!
//! Morton codes interleave the bits of x/y (2D) or x/y/z (3D) coordinates into a
//! single integer that preserves spatial locality: nearby points in space map to
//! nearby Morton codes, making them useful for cache-friendly spatial sorting and
//! grid indexing.
//!
//! Coordinate limits: 2D encodes up to 21 bits per axis (max 2^21 - 1); 3D encodes
//! up to 21 bits per axis (total 63 bits). Inputs exceeding the limit return
//! `error.CoordTooLarge`.
//!
//! Thread safety: all functions are pure; no shared state.
const std = @import("std");
const testing = std.testing;

pub const MortonError = error{CoordTooLarge};

// ---------------------------------------------------------------------------
// Bit-spreading / compacting helpers
// ---------------------------------------------------------------------------

/// Spread bits of x: insert a zero bit between each bit.
/// 0b1111 -> 0b01010101
inline fn part1by1(n: u32) u32 {
    var x = n & 0x0000ffff;
    x = (x ^ (x << 8)) & 0x00ff00ff;
    x = (x ^ (x << 4)) & 0x0f0f0f0f;
    x = (x ^ (x << 2)) & 0x33333333;
    x = (x ^ (x << 1)) & 0x55555555;
    return x;
}

/// Reverse of part1by1: extract every other bit.
inline fn compact1by1(n: u32) u32 {
    var x = n & 0x55555555;
    x = (x ^ (x >> 1)) & 0x33333333;
    x = (x ^ (x >> 2)) & 0x0f0f0f0f;
    x = (x ^ (x >> 4)) & 0x00ff00ff;
    x = (x ^ (x >> 8)) & 0x0000ffff;
    return x;
}

/// Spread bits with 2-bit gaps for 3D.
inline fn part1by2(n: u32) u32 {
    var x = n & 0x000003ff;
    x = (x ^ (x << 16)) & 0xff0000ff;
    x = (x ^ (x << 8)) & 0x0300f00f;
    x = (x ^ (x << 4)) & 0x030c30c3;
    x = (x ^ (x << 2)) & 0x09249249;
    return x;
}

/// Reverse of part1by2: extract every third bit.
inline fn compact1by2(n: u32) u32 {
    var x = n & 0x09249249;
    x = (x ^ (x >> 2)) & 0x030c30c3;
    x = (x ^ (x >> 4)) & 0x0300f00f;
    x = (x ^ (x >> 8)) & 0xff0000ff;
    x = (x ^ (x >> 16)) & 0x000003ff;
    return x;
}

// ---------------------------------------------------------------------------
// 2D Morton codes
// ---------------------------------------------------------------------------

/// Interleave the bits of x and y into a single 32-bit Morton code.
/// x occupies the even bits (0, 2, 4, ...) and y occupies the odd bits (1, 3, 5, ...).
pub fn encode2d(x: u16, y: u16) u32 {
    return part1by1(@as(u32, x)) | (part1by1(@as(u32, y)) << 1);
}

/// De-interleave a 32-bit Morton code back into its x and y components.
pub fn decode2d(code: u32) struct { x: u16, y: u16 } {
    return .{
        .x = @intCast(compact1by1(code)),
        .y = @intCast(compact1by1(code >> 1)),
    };
}

// ---------------------------------------------------------------------------
// 3D Morton codes
// ---------------------------------------------------------------------------

/// Interleave the bits of x, y, and z into a 30-bit Morton code.
/// x occupies bits 0, 3, 6, ...; y occupies bits 1, 4, 7, ...; z occupies bits 2, 5, 8, ...
pub fn encode3d(x: u10, y: u10, z: u10) u32 {
    return part1by2(@as(u32, x)) | (part1by2(@as(u32, y)) << 1) | (part1by2(@as(u32, z)) << 2);
}

/// De-interleave a 30-bit Morton code back into its x, y, and z components.
pub fn decode3d(code: u32) struct { x: u10, y: u10, z: u10 } {
    return .{
        .x = @intCast(compact1by2(code)),
        .y = @intCast(compact1by2(code >> 1)),
        .z = @intCast(compact1by2(code >> 2)),
    };
}

// ---------------------------------------------------------------------------
// Float encoding
// ---------------------------------------------------------------------------

/// Quantize floating-point coordinates into the range [0, (1<<bits)-1] and
/// produce a 2D Morton code. Returns `MortonError.CoordTooLarge` if either
/// coordinate falls outside its [min, max] bounds.
pub fn encodef2d(
    x: f32,
    y: f32,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    bits: u5,
) MortonError!u32 {
    if (x < min_x or x > max_x or y < min_y or y > max_y) {
        return MortonError.CoordTooLarge;
    }

    const range_x = max_x - min_x;
    const range_y = max_y - min_y;
    const max_val: f32 = @floatFromInt((@as(u32, 1) << bits) - 1);

    const qx: u16 = if (range_x == 0.0)
        0
    else
        @intFromFloat(@min(max_val, @floor(((x - min_x) / range_x) * max_val)));

    const qy: u16 = if (range_y == 0.0)
        0
    else
        @intFromFloat(@min(max_val, @floor(((y - min_y) / range_y) * max_val)));

    return encode2d(qx, qy);
}

// ===========================================================================
// Tests
// ===========================================================================

test "encode2d/decode2d roundtrip" {
    // Zero
    {
        const code = encode2d(0, 0);
        const dec = decode2d(code);
        try testing.expectEqual(@as(u16, 0), dec.x);
        try testing.expectEqual(@as(u16, 0), dec.y);
    }

    // Max u16
    {
        const code = encode2d(std.math.maxInt(u16), std.math.maxInt(u16));
        const dec = decode2d(code);
        try testing.expectEqual(std.math.maxInt(u16), dec.x);
        try testing.expectEqual(std.math.maxInt(u16), dec.y);
    }

    // Powers of 2
    {
        inline for ([_]u16{ 1, 2, 4, 8, 16, 256, 1024, 32768 }) |v| {
            const code = encode2d(v, v);
            const dec = decode2d(code);
            try testing.expectEqual(v, dec.x);
            try testing.expectEqual(v, dec.y);
        }
    }

    // Arbitrary values
    {
        const pairs = [_][2]u16{
            .{ 123, 456 },
            .{ 1000, 2000 },
            .{ 42, 0 },
            .{ 0, 42 },
            .{ 31337, 12345 },
        };
        for (pairs) |p| {
            const code = encode2d(p[0], p[1]);
            const dec = decode2d(code);
            try testing.expectEqual(p[0], dec.x);
            try testing.expectEqual(p[1], dec.y);
        }
    }
}

test "encode3d/decode3d roundtrip" {
    // Zero
    {
        const code = encode3d(0, 0, 0);
        const dec = decode3d(code);
        try testing.expectEqual(@as(u10, 0), dec.x);
        try testing.expectEqual(@as(u10, 0), dec.y);
        try testing.expectEqual(@as(u10, 0), dec.z);
    }

    // Max u10 (1023)
    {
        const code = encode3d(1023, 1023, 1023);
        const dec = decode3d(code);
        try testing.expectEqual(@as(u10, 1023), dec.x);
        try testing.expectEqual(@as(u10, 1023), dec.y);
        try testing.expectEqual(@as(u10, 1023), dec.z);
    }

    // Representative values
    {
        const triples = [_][3]u10{
            .{ 1, 0, 0 },
            .{ 0, 1, 0 },
            .{ 0, 0, 1 },
            .{ 7, 13, 42 },
            .{ 512, 256, 128 },
            .{ 1023, 0, 512 },
            .{ 100, 200, 300 },
        };
        for (triples) |t| {
            const code = encode3d(t[0], t[1], t[2]);
            const dec = decode3d(code);
            try testing.expectEqual(t[0], dec.x);
            try testing.expectEqual(t[1], dec.y);
            try testing.expectEqual(t[2], dec.z);
        }
    }
}

test "encode2d known values" {
    // x=1, y=0 -> only bit 0 set -> 0b01
    try testing.expectEqual(@as(u32, 0b01), encode2d(1, 0));

    // x=0, y=1 -> only bit 1 set -> 0b10
    try testing.expectEqual(@as(u32, 0b10), encode2d(0, 1));

    // x=1, y=1 -> bits 0 and 1 set -> 0b11
    try testing.expectEqual(@as(u32, 0b11), encode2d(1, 1));

    // x=0b11, y=0b11 -> interleaved: 0b1111
    try testing.expectEqual(@as(u32, 0b1111), encode2d(0b11, 0b11));

    // x=0b101, y=0b010 -> x bits at even positions, y bits at odd
    // x: bit0=1, bit1=0, bit2=1  -> positions 0,2,4: 1,0,1
    // y: bit0=0, bit1=1, bit2=0  -> positions 1,3,5: 0,1,0
    // result: bit5=0, bit4=1, bit3=1, bit2=0, bit1=0, bit0=1 -> 0b010_1_00_01 = 0b011001
    try testing.expectEqual(@as(u32, 0b011001), encode2d(0b101, 0b010));

    // x=0xFF, y=0 -> every even bit set for the low 16 bits
    // part1by1(0xFF) = 0x5555 & lower 16 bits = 0x00005555
    try testing.expectEqual(@as(u32, 0x00005555), encode2d(0xFF, 0));
}

test "encodef2d basic" {
    // Map (0.5, 0.5) in [0,1]x[0,1] with 4 bits -> quantised to (7,7) or (8,8)
    // max_val = 15, 0.5 * 15 = 7.5, floor = 7
    const code = try encodef2d(0.5, 0.5, 0.0, 1.0, 0.0, 1.0, 4);
    const expected = encode2d(7, 7);
    try testing.expectEqual(expected, code);

    // Min corner -> (0,0)
    const code_min = try encodef2d(0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 8);
    try testing.expectEqual(encode2d(0, 0), code_min);

    // Max corner -> (255, 255) for 8 bits
    const code_max = try encodef2d(1.0, 1.0, 0.0, 1.0, 0.0, 1.0, 8);
    try testing.expectEqual(encode2d(255, 255), code_max);
}

test "encodef2d out of range" {
    // x below min
    try testing.expectError(MortonError.CoordTooLarge, encodef2d(-0.1, 0.5, 0.0, 1.0, 0.0, 1.0, 8));

    // x above max
    try testing.expectError(MortonError.CoordTooLarge, encodef2d(1.1, 0.5, 0.0, 1.0, 0.0, 1.0, 8));

    // y below min
    try testing.expectError(MortonError.CoordTooLarge, encodef2d(0.5, -0.1, 0.0, 1.0, 0.0, 1.0, 8));

    // y above max
    try testing.expectError(MortonError.CoordTooLarge, encodef2d(0.5, 1.1, 0.0, 1.0, 0.0, 1.0, 8));
}
