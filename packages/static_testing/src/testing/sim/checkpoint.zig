//! Stable digest helpers for deterministic state comparison.

const std = @import("std");
const testing = std.testing;
const checker = @import("../checker.zig");

/// Digest equality classification.
pub const CheckpointResult = enum(u8) {
    equal = 1,
    different = 2,
};

/// Fixed-width checkpoint digest.
pub const CheckpointDigest = checker.CheckpointDigest;

const digest_tag_hi: u64 = 0x53545f43484b5054; // "ST_CHKPT"
const digest_tag_lo: u64 = 0x53545f4449474553; // "ST_DIGES"

/// Compute a deterministic digest for opaque state bytes.
pub fn computeDigest(bytes: []const u8) CheckpointDigest {
    const hash_hi = std.hash.Wyhash.hash(digest_tag_hi, bytes);
    const hash_lo = std.hash.Wyhash.hash(digest_tag_lo, bytes);
    return .{
        .value = (@as(u128, hash_hi) << 64) | @as(u128, hash_lo),
    };
}

/// Compare two checkpoint digests without embedding domain-specific state logic.
pub fn compareCheckpoints(a: CheckpointDigest, b: CheckpointDigest) CheckpointResult {
    return if (a.eql(b)) .equal else .different;
}

test "checkpoint digest is stable for identical state" {
    const digest_a = computeDigest("same-state");
    const digest_b = computeDigest("same-state");

    try testing.expect(digest_a.eql(digest_b));
    try testing.expectEqual(CheckpointResult.equal, compareCheckpoints(digest_a, digest_b));
}

test "checkpoint digest differs for different state" {
    const digest_a = computeDigest("a");
    const digest_b = computeDigest("b");

    try testing.expect(!digest_a.eql(digest_b));
    try testing.expectEqual(CheckpointResult.different, compareCheckpoints(digest_a, digest_b));
}
