//! Stable deterministic seed parsing, formatting, and derivation.
//!
//! Text formats:
//! - decimal: `"42"`;
//! - explicit hexadecimal: `"0x2a"`; and
//! - bare hexadecimal for commit-like identifiers: `"deadbeef"`.
//!
//! Decimal-only text is always parsed as decimal, even when it is also valid
//! hexadecimal. Bare hexadecimal therefore requires at least one `a-f` digit.

const std = @import("std");
const core = @import("static_core");
const rng = @import("static_rng");

/// Errors surfaced by seed parsing.
pub const SeedParseError = error{
    InvalidInput,
    Overflow,
};

/// Errors surfaced by deterministic child-seed derivation helpers.
pub const SeedDeriveError = error{
    InvalidInput,
};

/// Width of `formatSeed()` output, including the `0x` prefix.
pub const formatted_seed_len: usize = 18;

const split_seed_tag: u64 = 0x53545f53504c4954; // "ST_SPLIT"
const named_seed_tag: u64 = 0x53545f4c4142454c; // "ST_LABEL"

comptime {
    core.errors.assertVocabularySubset(SeedParseError);
    core.errors.assertVocabularySubset(SeedDeriveError);
    std.debug.assert(split_seed_tag != named_seed_tag);
}

/// Stable deterministic seed wrapper.
pub const Seed = struct {
    value: u64,

    /// Construct a seed from one raw `u64`.
    pub fn init(value: u64) Seed {
        return .{ .value = value };
    }
};

/// Parse one seed from decimal, explicit hexadecimal, or bare hexadecimal text.
pub fn parseSeed(text: []const u8) SeedParseError!Seed {
    if (text.len == 0) return error.InvalidInput;

    if (hasHexPrefix(text)) {
        return parseHexDigits(text[2..]);
    }
    if (isDecimalText(text)) {
        return parseDecimalDigits(text);
    }
    if (isBareHexText(text)) {
        return parseHexDigits(text);
    }
    return error.InvalidInput;
}

/// Format one seed as lowercase fixed-width hexadecimal with `0x` prefix.
pub fn formatSeed(seed: Seed) [formatted_seed_len]u8 {
    var buffer: [formatted_seed_len]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buffer, "0x{x:0>16}", .{seed.value}) catch unreachable;
    std.debug.assert(formatted.len == buffer.len);
    std.debug.assert(formatted[0] == '0');
    return buffer;
}

/// Derive a deterministic child seed for one numeric stream identifier.
pub fn splitSeed(seed: Seed, stream_id: u64) Seed {
    var splitter = rng.SplitMix64.init(seed.value ^ split_seed_tag ^ stream_id);
    const derived_value = splitter.next();
    return Seed.init(derived_value);
}

/// Derive a deterministic child seed for one textual label.
pub fn deriveNamedSeed(seed: Seed, label: []const u8) SeedDeriveError!Seed {
    if (label.len == 0) return error.InvalidInput;

    const label_hash = std.hash.Fnv1a_64.hash(label);
    return splitSeed(seed, label_hash ^ named_seed_tag);
}

fn hasHexPrefix(text: []const u8) bool {
    std.debug.assert(text.len > 0);
    if (text.len < 2) return false;
    return text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
}

fn isDecimalText(text: []const u8) bool {
    std.debug.assert(text.len > 0);

    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn isBareHexText(text: []const u8) bool {
    std.debug.assert(text.len > 0);
    if (text.len > 16) return false;

    var saw_hex_alpha = false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
        if (std.ascii.toLower(byte) >= 'a' and std.ascii.toLower(byte) <= 'f') {
            saw_hex_alpha = true;
        }
    }
    return saw_hex_alpha;
}

fn parseDecimalDigits(text: []const u8) SeedParseError!Seed {
    std.debug.assert(text.len > 0);
    const parsed = std.fmt.parseUnsigned(u64, text, 10) catch |err| return switch (err) {
        error.InvalidCharacter => error.InvalidInput,
        error.Overflow => error.Overflow,
    };
    return Seed.init(parsed);
}

fn parseHexDigits(text: []const u8) SeedParseError!Seed {
    if (text.len == 0) return error.InvalidInput;

    const parsed = std.fmt.parseUnsigned(u64, text, 16) catch |err| return switch (err) {
        error.InvalidCharacter => error.InvalidInput,
        error.Overflow => error.Overflow,
    };
    return Seed.init(parsed);
}

test "parseSeed accepts decimal and hexadecimal formats" {
    try std.testing.expectEqual(@as(u64, 42), (try parseSeed("42")).value);
    try std.testing.expectEqual(@as(u64, 42), (try parseSeed("0x2a")).value);
    try std.testing.expectEqual(@as(u64, 42), (try parseSeed("0X2A")).value);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), (try parseSeed("deadbeef")).value);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), (try parseSeed("DEADBEEF")).value);
    try std.testing.expectEqual(std.math.maxInt(u64), (try parseSeed("0xffffffffffffffff")).value);
    try std.testing.expectEqual(std.math.maxInt(u64), (try parseSeed("ffffffffffffffff")).value);
}

test "parseSeed rejects empty or malformed input" {
    try std.testing.expectError(error.InvalidInput, parseSeed(""));
    try std.testing.expectError(error.InvalidInput, parseSeed("0x"));
    try std.testing.expectError(error.InvalidInput, parseSeed("xyz"));
    try std.testing.expectError(error.Overflow, parseSeed("18446744073709551616"));
    try std.testing.expectError(error.Overflow, parseSeed("0x10000000000000000"));
}

test "formatSeed round-trips through parseSeed" {
    const seed = Seed.init(0x0123_4567_89ab_cdef);
    const formatted = formatSeed(seed);
    const reparsed = try parseSeed(&formatted);
    try std.testing.expectEqual(seed.value, reparsed.value);
}

test "splitSeed is stable and stream-separated" {
    const base_seed = Seed.init(1234);
    const child_a = splitSeed(base_seed, 1);
    const child_b = splitSeed(base_seed, 1);
    const child_c = splitSeed(base_seed, 2);

    try std.testing.expectEqual(child_a.value, child_b.value);
    try std.testing.expect(child_a.value != child_c.value);
}

test "deriveNamedSeed is stable and rejects empty labels" {
    const base_seed = Seed.init(55);
    const derived_a = try deriveNamedSeed(base_seed, "worker-a");
    const derived_b = try deriveNamedSeed(base_seed, "worker-a");
    const derived_c = try deriveNamedSeed(base_seed, "worker-b");

    try std.testing.expectEqual(derived_a.value, derived_b.value);
    try std.testing.expect(derived_a.value != derived_c.value);
    try std.testing.expectError(error.InvalidInput, deriveNamedSeed(base_seed, ""));
}
