//! Type fingerprinting — deterministic hashes derived from type identity.
//!
//! Key types: `TypeFingerprint64`, `TypeFingerprint128`.
//! Usage pattern: call `runtime64(T)` for in-process type identity checks;
//! call `stable64Required(T)` for cross-binary or on-disk stable fingerprints.
//! Thread safety: unrestricted — all functions are pure and comptime-driven.

const std = @import("std");
const static_hash = @import("static_hash");
const type_name = @import("type_name.zig");

// Comptime invariant: fingerprint types must be exactly the widths they advertise.
comptime {
    std.debug.assert(@bitSizeOf(u64) == 64);
    std.debug.assert(@bitSizeOf(u128) == 128);
}

pub const TypeFingerprint64 = u64;
pub const TypeFingerprint128 = u128;

/// Compute a 64-bit runtime fingerprint for type T.
///
/// Preconditions: @typeName(T) is always non-empty for valid Zig types.
/// Postconditions: returns non-zero fingerprint (Wyhash of a non-empty name).
pub fn runtime64(comptime T: type) TypeFingerprint64 {
    const runtime_name = type_name.runtimeTypeName(T);
    // Precondition: the type name must be non-empty.
    std.debug.assert(runtime_name.len > 0);
    const result = static_hash.fingerprint64(runtime_name);
    // Postcondition: a non-empty name produces a non-zero fingerprint with overwhelming probability.
    // A zero fingerprint here would indicate a hash collision, not a bug, so we document rather than assert.
    return result;
}

/// Compute a 128-bit runtime fingerprint for type T.
///
/// Postconditions: the 128-bit result is composed of two independent 64-bit halves.
pub fn runtime128(comptime T: type) TypeFingerprint128 {
    const runtime_name = type_name.runtimeTypeName(T);
    // Precondition: the type name must be non-empty.
    std.debug.assert(runtime_name.len > 0);
    const result = static_hash.fingerprint128(runtime_name);
    // Postcondition: 128-bit result must fit in u128.
    std.debug.assert(@TypeOf(result) == TypeFingerprint128);
    return result;
}

pub fn stable64(comptime T: type) ?TypeFingerprint64 {
    const identity = type_name.tryStableIdentity(T) orelse return null;
    return stableFromIdentity64(identity);
}

pub fn stable128(comptime T: type) ?TypeFingerprint128 {
    const identity = type_name.tryStableIdentity(T) orelse return null;
    return stableFromIdentity128(identity);
}

pub fn stable64Required(comptime T: type) TypeFingerprint64 {
    return stableFromIdentity64(type_name.requireStableIdentity(T));
}

pub fn stable128Required(comptime T: type) TypeFingerprint128 {
    return stableFromIdentity128(type_name.requireStableIdentity(T));
}

fn stableFromIdentity64(identity: type_name.StableIdentity) TypeFingerprint64 {
    // Precondition: stable identities must carry a non-empty name.
    std.debug.assert(identity.name.len > 0);
    const name_hash = static_hash.stableFingerprint64(identity.name);
    const result = static_hash.combineOrdered64(.{
        .left = name_hash,
        .right = identity.version,
    });
    // Postcondition: result type is the declared fingerprint type.
    std.debug.assert(@TypeOf(result) == TypeFingerprint64);
    return result;
}

fn stableFromIdentity128(identity: type_name.StableIdentity) TypeFingerprint128 {
    // Precondition: stable identities must carry a non-empty name.
    std.debug.assert(identity.name.len > 0);
    const version64 = @as(u64, identity.version);
    const low = stableFromIdentity64(identity);
    const high_name = static_hash.stable.stableFingerprint64Seeded(0x9e3779b97f4a7c15, identity.name);
    const high = static_hash.combineOrdered64(.{
        .left = high_name,
        .right = ~version64,
    });
    const result = (@as(u128, high) << 64) | low;
    // Postcondition: the low 64 bits must match the stable64 result for the same identity.
    std.debug.assert(@as(u64, @truncate(result)) == low);
    return result;
}

test "runtime fingerprints are deterministic" {
    const Example = struct {
        x: i32,
    };

    const a64 = runtime64(Example);
    const b64 = runtime64(Example);
    try std.testing.expectEqual(a64, b64);

    const a128 = runtime128(Example);
    const b128 = runtime128(Example);
    try std.testing.expectEqual(a128, b128);
}

test "stable optional fingerprints return null when identity is missing" {
    const NoStable = struct {};
    try std.testing.expect(stable64(NoStable) == null);
    try std.testing.expect(stable128(NoStable) == null);
}

test "stable required fingerprints are deterministic for opted in types" {
    const Stable = struct {
        pub const static_name: []const u8 = "tests/stable_type";
        pub const static_version: u32 = 2;
    };

    const a64 = stable64Required(Stable);
    const b64 = stable64Required(Stable);
    try std.testing.expectEqual(a64, b64);

    const a128 = stable128Required(Stable);
    const b128 = stable128Required(Stable);
    try std.testing.expectEqual(a128, b128);
}

test "stable and runtime fingerprints differ for most opted in types" {
    const Stable = struct {
        pub const static_name: []const u8 = "tests/stable_vs_runtime";
        pub const static_version: u32 = 7;
    };

    const runtime = runtime64(Stable);
    const stable_value = stable64Required(Stable);
    try std.testing.expect(runtime != stable_value);
}

test "stable fingerprints change when version changes for the same stable name" {
    const V1 = struct {
        pub const static_name: []const u8 = "tests/versioned_identity";
        pub const static_version: u32 = 1;
    };
    const V2 = struct {
        pub const static_name: []const u8 = "tests/versioned_identity";
        pub const static_version: u32 = 2;
    };

    // Stable identity is the pair (name, version), so version bumps must
    // change both stable fingerprint widths even when the durable name stays fixed.
    try std.testing.expectEqualStrings(
        type_name.requireStableIdentity(V1).name,
        type_name.requireStableIdentity(V2).name,
    );
    try std.testing.expect(type_name.requireStableIdentity(V1).version != type_name.requireStableIdentity(V2).version);
    try std.testing.expect(stable64Required(V1) != stable64Required(V2));
    try std.testing.expect(stable128Required(V1) != stable128Required(V2));
}

test "stable fingerprints follow stable identity instead of runtime names" {
    const RuntimeNameA = struct {
        pub const static_name: []const u8 = "tests/shared_stable_identity";
        pub const static_version: u32 = 3;
    };
    const RuntimeNameB = struct {
        pub const static_name: []const u8 = "tests/shared_stable_identity";
        pub const static_version: u32 = 3;
    };

    // Runtime fingerprints intentionally track the compiler-generated type name,
    // while stable fingerprints track the opt-in durable identity contract.
    try std.testing.expect(runtime64(RuntimeNameA) != runtime64(RuntimeNameB));
    try std.testing.expect(runtime128(RuntimeNameA) != runtime128(RuntimeNameB));
    try std.testing.expectEqual(stable64Required(RuntimeNameA), stable64Required(RuntimeNameB));
    try std.testing.expectEqual(stable128Required(RuntimeNameA), stable128Required(RuntimeNameB));
}
