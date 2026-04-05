//! Type naming — runtime and stable identity extraction from Zig types.
//!
//! Key types: `StableIdentity`.
//! Usage pattern: call `runtimeTypeName(T)` for in-process diagnostics;
//! declare `pub const static_name` and `pub const static_version` on a type
//! to opt into cross-binary stable identity, then call `tryStableIdentity(T)`.
//! Thread safety: unrestricted — all functions are pure and comptime-driven.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const StableIdentity = struct {
    name: []const u8,
    version: u32,
};

/// Return the Zig compiler-assigned name for type T.
///
/// Postconditions: returned slice is always non-empty for any valid Zig type.
pub fn runtimeTypeName(comptime T: type) []const u8 {
    const name = @typeName(T);
    // Postcondition: the compiler never produces an empty type name for valid types.
    assert(name.len > 0);
    return name;
}

/// Return true if T declares both `static_name` and `static_version`.
pub fn hasStableIdentity(comptime T: type) bool {
    return @hasDecl(T, "static_name") and @hasDecl(T, "static_version");
}

/// Extract stable identity from T, or return null if not opted in.
///
/// Postconditions: when non-null, identity.name.len > 0.
pub fn tryStableIdentity(comptime T: type) ?StableIdentity {
    if (comptime hasStableIdentity(T)) {
        const stable_name = @field(T, "static_name");
        const stable_version = @field(T, "static_version");

        comptime {
            if (@TypeOf(stable_name) != []const u8) {
                @compileError("static_meta: stable identity requires `static_name: []const u8`");
            }
            if (@TypeOf(stable_version) != u32) {
                @compileError("static_meta: stable identity requires `static_version: u32`");
            }
        }

        // Postcondition: the stable name must be non-empty.
        assert(stable_name.len > 0);
        const result: StableIdentity = .{
            .name = stable_name,
            .version = stable_version,
        };
        // Postcondition: returned identity name matches the declaration.
        assert(result.name.len > 0);
        return result;
    }
    return null;
}

/// Extract stable identity from T, or halt compilation if not opted in.
///
/// Postconditions: identity.name.len > 0.
pub fn requireStableIdentity(comptime T: type) StableIdentity {
    if (!@hasDecl(T, "static_name")) {
        @compileError("static_meta: type is missing `static_name` declaration");
    }
    if (!@hasDecl(T, "static_version")) {
        @compileError("static_meta: type is missing `static_version` declaration");
    }

    const identity = tryStableIdentity(T) orelse unreachable;
    // Postcondition: required identity must have a non-empty name.
    assert(identity.name.len > 0);
    return identity;
}

test "runtimeTypeName is deterministic for same type" {
    const A = struct {};
    const first = runtimeTypeName(A);
    const second = runtimeTypeName(A);
    try testing.expectEqualStrings(first, second);
    try testing.expect(first.len > 0);
}

test "hasStableIdentity detects opt in declarations" {
    const WithStable = struct {
        pub const static_name: []const u8 = "tests/with_stable";
        pub const static_version: u32 = 4;
    };
    const WithoutStable = struct {};

    try testing.expect(hasStableIdentity(WithStable));
    try testing.expect(!hasStableIdentity(WithoutStable));
}

test "tryStableIdentity returns null for non opted in types" {
    const WithoutStable = struct {};
    const identity = tryStableIdentity(WithoutStable);
    try testing.expect(identity == null);
}

test "tryStableIdentity returns declarations for opted in type" {
    const WithStable = struct {
        pub const static_name: []const u8 = "tests/with_stable";
        pub const static_version: u32 = 9;
    };
    const identity = tryStableIdentity(WithStable).?;
    try testing.expectEqualStrings("tests/with_stable", identity.name);
    try testing.expectEqual(@as(u32, 9), identity.version);
}
