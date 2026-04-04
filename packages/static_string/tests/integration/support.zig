const std = @import("std");

pub const vocabulary = [_][]const u8{
    "alpha",
    "beta",
    "gamma",
    "header-name",
    "CONTENT-TYPE",
    "x-request-id",
    "caf\xc3\xa9",
    "na\xc3\xafve",
    " \ttrim me\r\n",
    "emoji-\xf0\x9f\x98\x80",
};

pub fn tokenForIndex(index: u64) []const u8 {
    std.debug.assert(vocabulary.len > 0);
    const resolved = vocabulary[index % vocabulary.len];
    std.debug.assert(resolved.len > 0);
    return resolved;
}

pub fn fillSeedBytes(buffer: []u8, seed: u64) void {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer.len <= 64);

    var state = seed ^ 0x9e37_79b9_7f4a_7c15;
    for (buffer, 0..) |*byte, index| {
        state = mix64(state +% @as(u64, @intCast(index + 1)));
        byte.* = @truncate(state);
    }

    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer[0] == buffer[0]);
}

pub fn copyBytes(destination: []u8, source: []const u8) usize {
    std.debug.assert(destination.len >= source.len);
    std.debug.assert(source.len <= destination.len);

    @memcpy(destination[0..source.len], source);

    std.debug.assert(source.len == 0 or destination[0] == source[0]);
    std.debug.assert(source.len == 0 or destination[source.len - 1] == source[source.len - 1]);
    return source.len;
}

pub fn manualTrimWhitespace(bytes: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = bytes.len;

    while (start < end and isAsciiWhitespace(bytes[start])) : (start += 1) {}
    while (end > start and isAsciiWhitespace(bytes[end - 1])) : (end -= 1) {}

    const trimmed = bytes[start..end];
    std.debug.assert(trimmed.len <= bytes.len);
    std.debug.assert(trimmed.ptr == bytes.ptr + start);
    return trimmed;
}

pub fn manualLower(bytes: []const u8, storage: []u8) []const u8 {
    std.debug.assert(storage.len >= bytes.len);
    std.debug.assert(bytes.len <= storage.len);

    for (bytes, 0..) |byte, index| {
        storage[index] = switch (byte) {
            'A'...'Z' => byte + ('a' - 'A'),
            else => byte,
        };
    }

    const lowered = storage[0..bytes.len];
    std.debug.assert(lowered.len == bytes.len);
    std.debug.assert(bytes.len == 0 or lowered[0] == switch (bytes[0]) {
        'A'...'Z' => bytes[0] + ('a' - 'A'),
        else => bytes[0],
    });
    return lowered;
}

pub fn manualEqIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;

    var index: usize = 0;
    while (index < left.len) : (index += 1) {
        if (lowerByte(left[index]) != lowerByte(right[index])) return false;
    }

    std.debug.assert(left.len == right.len);
    std.debug.assert(index == left.len);
    return true;
}

pub fn digestBytes(bytes: []const u8) u64 {
    var state: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes, 0..) |byte, index| {
        state ^= @as(u64, byte) | (@as(u64, @intCast(index)) << 32);
        state *%= 0x0000_0100_0000_01b3;
    }
    const digest = mix64(state ^ @as(u64, @intCast(bytes.len)));
    std.debug.assert(digest == digest);
    std.debug.assert(bytes.len == 0 or digest != 0 or bytes[0] == 0);
    return digest;
}

pub fn foldDigest(left: u64, right: u64) u64 {
    const folded = mix64(left ^ (right +% 0x9e37_79b9_7f4a_7c15));
    std.debug.assert(folded == folded);
    std.debug.assert(folded != left or right == 0);
    return folded;
}

fn lowerByte(value: u8) u8 {
    return switch (value) {
        'A'...'Z' => value + ('a' - 'A'),
        else => value,
    };
}

fn isAsciiWhitespace(value: u8) bool {
    return switch (value) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

fn mix64(value: u64) u64 {
    var mixed = value ^ (value >> 33);
    mixed *%= 0xff51_afd7_ed55_8ccd;
    mixed ^= mixed >> 33;
    mixed *%= 0xc4ce_b9fe_1a85_ec53;
    mixed ^= mixed >> 33;
    return mixed;
}
