//! UTF-8 validation — allocation-free codepoint-by-codepoint byte slice validation.
//!
//! Key types: `Utf8Error`.
//! Usage pattern: call `isValid(bytes)` to test whether a byte slice is valid UTF-8;
//! call `validate(bytes)` when an error return is preferred over a boolean result.
//! Both functions reject overlong encodings, surrogate halves, and out-of-range
//! codepoints (> U+10FFFF) per RFC 3629.
//! Thread safety: unrestricted — all functions are pure and read-only.

const std = @import("std");

pub const Utf8Error = error{
    InvalidInput,
};

/// Validates one UTF-8 codepoint starting at `bytes[pos]`.
/// Returns the number of bytes consumed on success, or null if the sequence
/// is invalid or truncated. The caller is responsible for bounds checking
/// (remaining bytes >= 1) before calling this function.
fn decodeSingleCodepoint(bytes: []const u8, pos: usize) ?usize {
    // Precondition: pos must be within the slice.
    std.debug.assert(pos < bytes.len);
    const b0 = bytes[pos];
    const remaining = bytes.len - pos;
    std.debug.assert(remaining > 0);

    if (b0 <= 0x7f) return 1;

    if (b0 >= 0xc2 and b0 <= 0xdf) {
        if (remaining < 2) return null;
        if (!isContinuation(bytes[pos + 1])) return null;
        return 2;
    }

    if (b0 == 0xe0) {
        if (remaining < 3) return null;
        const b1 = bytes[pos + 1];
        const b2 = bytes[pos + 2];
        if (b1 < 0xa0 or b1 > 0xbf) return null;
        if (!isContinuation(b2)) return null;
        return 3;
    }

    if ((b0 >= 0xe1 and b0 <= 0xec) or (b0 >= 0xee and b0 <= 0xef)) {
        if (remaining < 3) return null;
        if (!isContinuation(bytes[pos + 1])) return null;
        if (!isContinuation(bytes[pos + 2])) return null;
        return 3;
    }

    if (b0 == 0xed) {
        if (remaining < 3) return null;
        const b1 = bytes[pos + 1];
        const b2 = bytes[pos + 2];
        if (b1 < 0x80 or b1 > 0x9f) return null;
        if (!isContinuation(b2)) return null;
        return 3;
    }

    if (b0 == 0xf0) {
        if (remaining < 4) return null;
        const b1 = bytes[pos + 1];
        const b2 = bytes[pos + 2];
        const b3 = bytes[pos + 3];
        if (b1 < 0x90 or b1 > 0xbf) return null;
        if (!isContinuation(b2) or !isContinuation(b3)) return null;
        return 4;
    }

    if (b0 >= 0xf1 and b0 <= 0xf3) {
        if (remaining < 4) return null;
        if (!isContinuation(bytes[pos + 1])) return null;
        if (!isContinuation(bytes[pos + 2])) return null;
        if (!isContinuation(bytes[pos + 3])) return null;
        return 4;
    }

    if (b0 == 0xf4) {
        if (remaining < 4) return null;
        const b1 = bytes[pos + 1];
        const b2 = bytes[pos + 2];
        const b3 = bytes[pos + 3];
        if (b1 < 0x80 or b1 > 0x8f) return null;
        if (!isContinuation(b2) or !isContinuation(b3)) return null;
        return 4;
    }

    return null;
}

pub fn isValid(bytes: []const u8) bool {
    var index: usize = 0;
    // Bound: each iteration consumes at least one byte, so the loop terminates
    // in at most bytes.len iterations.
    while (index < bytes.len) {
        const consumed = decodeSingleCodepoint(bytes, index) orelse return false;
        // Postcondition of the helper: consumed must be 1..4 bytes and must not
        // advance index beyond the slice boundary.
        std.debug.assert(consumed >= 1);
        std.debug.assert(consumed <= 4);
        std.debug.assert(index + consumed <= bytes.len);
        index += consumed;
    }
    return true;
}

pub fn validate(bytes: []const u8) Utf8Error!void {
    if (!isValid(bytes)) return error.InvalidInput;
}

fn isContinuation(value: u8) bool {
    return value >= 0x80 and value <= 0xbf;
}

test "utf8 validates ascii and multibyte utf8" {
    try std.testing.expect(isValid("ascii"));
    try std.testing.expect(isValid("caf\xc3\xa9"));
    try validate("Hello");
}

test "utf8 rejects truncated and invalid continuation sequences" {
    try std.testing.expect(!isValid("\xc3"));
    try std.testing.expect(!isValid("\xe2\x28\xa1"));
    try std.testing.expectError(error.InvalidInput, validate("\xf0\x28\x8c\xbc"));
}

test "utf8 rejects surrogate range encoding" {
    // U+D800 encoded as UTF-8 should be rejected.
    try std.testing.expect(!isValid("\xed\xa0\x80"));
}

test "utf8 rejects overlong and out-of-range encodings" {
    try std.testing.expect(!isValid("\x80"));
    try std.testing.expect(!isValid("\xc0\x80"));
    try std.testing.expect(!isValid("\xe0\x80\x80"));
    try std.testing.expect(!isValid("\xf0\x80\x80\x80"));
    try std.testing.expect(!isValid("\xf4\x90\x80\x80"));
}

test "utf8 accepts the maximum scalar value encoding" {
    // U+10FFFF encoded as UTF-8.
    try std.testing.expect(isValid("\xf4\x8f\xbf\xbf"));
}
