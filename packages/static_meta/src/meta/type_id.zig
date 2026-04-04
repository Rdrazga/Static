//! Type identity — stable u64 handles derived from type names.
//!
//! Key types: `TypeId`.
//! Usage pattern: call `fromType(T)` to obtain a stable identifier for a type;
//! use `fromName(name)` when the identifier must be derived from a string key.
//! Thread safety: unrestricted — all functions are pure.

const std = @import("std");
const static_hash = @import("static_hash");

// Comptime invariant: TypeId must be exactly 64 bits so it fits in a u64 hash table key.
comptime {
    std.debug.assert(@bitSizeOf(u64) == 64);
}

pub const TypeId = u64;

/// Derive a TypeId from an arbitrary non-empty name string.
///
/// Preconditions: name.len > 0 — an empty name has no meaningful identity.
/// Postconditions: returns deterministic 64-bit fingerprint of name.
pub fn fromName(name: []const u8) TypeId {
    // Precondition: an empty name is a programmer error; identities must be non-empty.
    std.debug.assert(name.len > 0);
    const result = static_hash.fingerprint64(name);
    // Postcondition: result type is the declared TypeId alias.
    std.debug.assert(@TypeOf(result) == TypeId);
    return result;
}

/// Derive a TypeId from a Zig type's compiler-assigned name.
///
/// Postconditions: same call with the same type always returns the same value.
pub fn fromType(comptime T: type) TypeId {
    // Precondition: @typeName always returns a non-empty string for valid types.
    comptime std.debug.assert(@typeName(T).len > 0);
    return fromName(@typeName(T));
}

test "fromType returns stable value for same type" {
    const Example = struct {
        value: u32,
    };

    const a = fromType(Example);
    const b = fromType(Example);
    try std.testing.expectEqual(a, b);
}

test "fromType differs for different type names" {
    const A = struct {};
    const B = struct {
        value: u8,
    };

    const a = fromType(A);
    const b = fromType(B);
    try std.testing.expect(a != b);
}

test "fromName returns stable value for same input" {
    const a = fromName("tests/name");
    const b = fromName("tests/name");
    try std.testing.expectEqual(a, b);
}
