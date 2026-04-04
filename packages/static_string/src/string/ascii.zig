//! ASCII byte utilities — case folding, whitespace trimming, and equality.
//!
//! Key types: none (free functions only).
//! Usage pattern: call `isAscii(bytes)` to verify all bytes are 7-bit clean;
//! `toLowerInPlace(bytes)` for in-place case normalization; `eqIgnoreCase(a, b)`
//! for case-insensitive comparison; `trimWhitespace(bytes)` to strip leading/trailing
//! ASCII whitespace. All functions are byte-oriented and do not claim UTF-8 semantics.
//! Thread safety: not thread-safe — `toLowerInPlace` mutates the slice in place.

const std = @import("std");

pub fn isAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte > 0x7f) return false;
    }
    // Postcondition: every byte has its high bit clear (all are 7-bit ASCII).
    // We only reach this point when no byte exceeded 0x7f, so the loop below
    // is a pair assertion validating that the scan above was correct.
    for (bytes) |byte| {
        std.debug.assert(byte & 0x80 == 0);
    }
    return true;
}

pub fn toLowerInPlace(bytes: []u8) void {
    for (bytes) |*byte| {
        if (byte.* >= 'A' and byte.* <= 'Z') {
            byte.* += 'a' - 'A';
        }
    }
    // Postcondition: no uppercase ASCII letter (A-Z) should remain in the buffer.
    // The transform is byte-level only; non-ASCII bytes are left untouched.
    for (bytes) |byte| {
        std.debug.assert(byte < 'A' or byte > 'Z');
    }
}

pub fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (toLowerByte(a[index]) != toLowerByte(b[index])) return false;
    }
    // Postcondition: slices are the same length when we reach this point
    // (the early return above handles the unequal-length case).
    std.debug.assert(a.len == b.len);
    return true;
}

pub fn trimWhitespace(bytes: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = bytes.len;

    while (start < end and isAsciiWhitespace(bytes[start])) : (start += 1) {}
    while (end > start and isAsciiWhitespace(bytes[end - 1])) : (end -= 1) {}
    const result = bytes[start..end];
    // Postcondition: the result is a valid sub-slice of the input.
    std.debug.assert(result.len <= bytes.len);
    // Postcondition: no leading or trailing ASCII whitespace remains in the result.
    if (result.len > 0) {
        std.debug.assert(!isAsciiWhitespace(result[0]));
        std.debug.assert(!isAsciiWhitespace(result[result.len - 1]));
    }
    return result;
}

fn toLowerByte(value: u8) u8 {
    if (value >= 'A' and value <= 'Z') {
        return value + ('a' - 'A');
    }
    return value;
}

fn isAsciiWhitespace(value: u8) bool {
    return switch (value) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

test "isAscii detects ascii and non ascii bytes" {
    try std.testing.expect(isAscii("hello"));
    try std.testing.expect(!isAscii("\xc3\xa9"));
}

test "toLowerInPlace lowercases ascii letters" {
    var bytes = [_]u8{ 'A', 'b', 'C', '1' };
    toLowerInPlace(bytes[0..]);
    try std.testing.expectEqualSlices(u8, "abc1", bytes[0..]);
}

test "eqIgnoreCase works for ascii data" {
    try std.testing.expect(eqIgnoreCase("Header-Name", "header-name"));
    try std.testing.expect(!eqIgnoreCase("Header", "Headers"));
}

test "trimWhitespace removes leading and trailing ascii whitespace" {
    const trimmed = trimWhitespace(" \t value \n");
    try std.testing.expectEqualStrings("value", trimmed);
}

test "trimWhitespace returns empty slice for all whitespace" {
    const trimmed = trimWhitespace(" \t\r\n");
    try std.testing.expectEqual(@as(usize, 0), trimmed.len);
}

test "eqIgnoreCase returns true for empty slices" {
    try std.testing.expect(eqIgnoreCase("", ""));
}
