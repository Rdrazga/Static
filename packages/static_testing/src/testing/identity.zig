//! Stable run identity shared by replay, fuzz, and benchmark records.
//!
//! The identity deliberately keeps only bounded metadata:
//! - package name;
//! - run name;
//! - deterministic seed;
//! - artifact version and build mode; and
//! - caller-assigned case/run indexes.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const seed_mod = @import("seed.zig");

/// Version tag persisted into replay artifacts.
pub const ArtifactVersion = enum(u16) {
    v1 = 1,
};

/// Stable build-mode tag persisted into replay artifacts and run identity.
pub const BuildMode = enum(u8) {
    debug = 1,
    release_safe = 2,
    release_fast = 3,
    release_small = 4,

    /// Map Zig optimize modes onto the persisted build-mode vocabulary.
    pub fn fromOptimizeMode(mode: std.builtin.OptimizeMode) BuildMode {
        return switch (mode) {
            .Debug => .debug,
            .ReleaseSafe => .release_safe,
            .ReleaseFast => .release_fast,
            .ReleaseSmall => .release_small,
        };
    }
};

/// Named arguments for constructing one bounded run identity.
pub const MakeRunIdentityOptions = struct {
    package_name: []const u8,
    run_name: []const u8,
    seed: seed_mod.Seed,
    artifact_version: ArtifactVersion = .v1,
    build_mode: BuildMode,
    case_index: u32 = 0,
    run_index: u32 = 0,
};

/// Stable run identity shared across fuzzing, replay, and persisted artifacts.
pub const RunIdentity = struct {
    artifact_version: ArtifactVersion,
    build_mode: BuildMode,
    seed: seed_mod.Seed,
    package_name: []const u8,
    run_name: []const u8,
    case_index: u32,
    run_index: u32,
};

comptime {
    assert(@intFromEnum(ArtifactVersion.v1) == 1);
    assert(std.meta.fields(BuildMode).len == 4);
}

/// Construct one run identity from caller-provided bounded metadata.
pub fn makeRunIdentity(options: MakeRunIdentityOptions) RunIdentity {
    assert(options.package_name.len > 0);
    assert(options.run_name.len > 0);
    assert(options.package_name.len <= std.math.maxInt(u16));
    assert(options.run_name.len <= std.math.maxInt(u16));

    return .{
        .artifact_version = options.artifact_version,
        .build_mode = options.build_mode,
        .seed = options.seed,
        .package_name = options.package_name,
        .run_name = options.run_name,
        .case_index = options.case_index,
        .run_index = options.run_index,
    };
}

/// Stable, non-cryptographic hash for local identity matching.
///
/// This is suitable for replay/corpus correlation and diagnostics. It is not a
/// collision-proof identifier and must not be treated as a security boundary.
pub fn identityHash(identity: RunIdentity) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hashEnum(&hasher, identity.artifact_version);
    hashEnum(&hasher, identity.build_mode);
    hashU64(&hasher, identity.seed.value);
    hashU32(&hasher, identity.case_index);
    hashU32(&hasher, identity.run_index);
    hashString(&hasher, identity.package_name);
    hashString(&hasher, identity.run_name);
    return hasher.final();
}

fn hashEnum(hasher: *std.hash.Fnv1a_64, value: anytype) void {
    const TagType = @typeInfo(@TypeOf(value)).@"enum".tag_type;
    hashInteger(hasher, TagType, @intFromEnum(value));
}

fn hashU32(hasher: *std.hash.Fnv1a_64, value: u32) void {
    hashInteger(hasher, u32, value);
}

fn hashU64(hasher: *std.hash.Fnv1a_64, value: u64) void {
    hashInteger(hasher, u64, value);
}

fn hashInteger(hasher: *std.hash.Fnv1a_64, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(bytes[0..]);
}

fn hashString(hasher: *std.hash.Fnv1a_64, text: []const u8) void {
    assert(text.len > 0);
    hashU64(hasher, text.len);
    hasher.update(text);
}

test "makeRunIdentity preserves required fields" {
    const identity = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "identity_smoke",
        .seed = seed_mod.Seed.init(9),
        .build_mode = .debug,
    });

    try testing.expectEqual(ArtifactVersion.v1, identity.artifact_version);
    try testing.expectEqual(BuildMode.debug, identity.build_mode);
    try testing.expectEqual(@as(u64, 9), identity.seed.value);
}

test "identityHash is stable for identical identities" {
    const identity = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "stable_hash",
        .seed = seed_mod.Seed.init(7),
        .build_mode = .release_safe,
        .case_index = 1,
        .run_index = 2,
    });

    try testing.expectEqual(identityHash(identity), identityHash(identity));
}

test "identityHash changes when seed or run metadata changes" {
    const a = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "hash_delta",
        .seed = seed_mod.Seed.init(1),
        .build_mode = .debug,
    });
    const b = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "hash_delta",
        .seed = seed_mod.Seed.init(2),
        .build_mode = .debug,
    });
    const c = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "hash_delta_other",
        .seed = seed_mod.Seed.init(1),
        .build_mode = .debug,
    });

    try testing.expect(identityHash(a) != identityHash(b));
    try testing.expect(identityHash(a) != identityHash(c));
}

test "identityHash changes across remaining persisted fields" {
    const base = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "field_delta",
        .seed = seed_mod.Seed.init(9),
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 2,
    });
    const package_delta = makeRunIdentity(.{
        .package_name = "static_testing_other",
        .run_name = "field_delta",
        .seed = seed_mod.Seed.init(9),
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 2,
    });
    const build_mode_delta = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "field_delta",
        .seed = seed_mod.Seed.init(9),
        .build_mode = .release_safe,
        .case_index = 1,
        .run_index = 2,
    });
    const case_index_delta = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "field_delta",
        .seed = seed_mod.Seed.init(9),
        .build_mode = .debug,
        .case_index = 3,
        .run_index = 2,
    });
    const run_index_delta = makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "field_delta",
        .seed = seed_mod.Seed.init(9),
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 4,
    });

    try testing.expect(identityHash(base) != identityHash(package_delta));
    try testing.expect(identityHash(base) != identityHash(build_mode_delta));
    try testing.expect(identityHash(base) != identityHash(case_index_delta));
    try testing.expect(identityHash(base) != identityHash(run_index_delta));
}
