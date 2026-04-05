//! Type registry — bounded fixed-capacity catalog of registered types.
//!
//! Key types: `TypeRegistry`, `Entry`.
//! Usage pattern: allocate an `Entry` array, call `TypeRegistry.init(entries)`,
//! then `registerType(T)` for each type; use `get(id)` or `contains(id)` to query.
//! This registry stays intentionally minimal: append-only insertion order and
//! linear lookup keep the identity policy easy to audit until real registry
//! sizes justify hashed or indexed variants.
//! Thread safety: not thread-safe — external synchronization required for concurrent use.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const type_id = @import("type_id.zig");
const type_name = @import("type_name.zig");
const type_fingerprint = @import("type_fingerprint.zig");

pub const TypeId = type_id.TypeId;
pub const TypeFingerprint64 = type_fingerprint.TypeFingerprint64;

pub const Entry = struct {
    type_id: TypeId,
    runtime_name: []const u8,
    runtime_fingerprint64: TypeFingerprint64,
    stable_name: ?[]const u8,
    stable_version: ?u32,
    stable_fingerprint64: ?TypeFingerprint64,
};

pub const RegistryError = error{
    InvalidConfig,
    NoSpaceLeft,
    AlreadyExists,
    NotFound,
};

pub const TypeRegistry = struct {
    entries: []Entry,
    len_used: usize,

    /// Initialize a registry backed by the caller-provided entries slice.
    ///
    /// Preconditions: entries.len > 0 — a zero-capacity registry cannot hold anything.
    /// Postconditions: len_used == 0 on success.
    pub fn init(entries: []Entry) RegistryError!TypeRegistry {
        if (entries.len == 0) return error.InvalidConfig;
        const result: TypeRegistry = .{
            .entries = entries,
            .len_used = 0,
        };
        // Postcondition: registry starts empty.
        assert(result.len_used == 0);
        // Postcondition: capacity matches the provided slice.
        assert(result.entries.len == entries.len);
        return result;
    }

    /// Return the number of registered entries.
    ///
    /// Postconditions: result <= capacity().
    pub fn len(self: *const TypeRegistry) usize {
        // Invariant: used count never exceeds the backing slice.
        assert(self.len_used <= self.entries.len);
        return self.len_used;
    }

    /// Return the maximum number of entries the registry can hold.
    ///
    /// Postconditions: result >= len().
    pub fn capacity(self: *const TypeRegistry) usize {
        assert(self.entries.len >= self.len_used);
        return self.entries.len;
    }

    /// Return a slice of all registered entries in insertion order.
    ///
    /// Postconditions: returned slice length == len().
    pub fn list(self: *const TypeRegistry) []const Entry {
        assert(self.len_used <= self.entries.len);
        const result = self.entries[0..self.len_used];
        // Postcondition: returned slice length matches internal count.
        assert(result.len == self.len_used);
        return result;
    }

    pub fn register(self: *TypeRegistry, entry: Entry) RegistryError!void {
        assert(entry.runtime_name.len > 0);
        if (entry.stable_name) |stable_name| {
            assert(stable_name.len > 0);
            assert(entry.stable_version != null);
            assert(entry.stable_fingerprint64 != null);
        } else {
            assert(entry.stable_version == null);
            assert(entry.stable_fingerprint64 == null);
        }

        if (self.contains(entry.type_id)) return error.AlreadyExists;
        if (self.len_used >= self.entries.len) return error.NoSpaceLeft;

        self.entries[self.len_used] = entry;
        self.len_used += 1;
        assert(self.len_used <= self.entries.len);
    }

    /// Register all metadata for a comptime-known type T.
    ///
    /// Postconditions: on success, contains(fromType(T)) is true.
    pub fn registerType(self: *TypeRegistry, comptime T: type) RegistryError!void {
        // Precondition: type name is always non-empty for valid Zig types.
        comptime assert(@typeName(T).len > 0);
        const len_before = self.len_used;
        const runtime_name = type_name.runtimeTypeName(T);
        const runtime_fp = type_fingerprint.runtime64(T);
        const stable_identity = type_name.tryStableIdentity(T);
        const stable_fp = type_fingerprint.stable64(T);

        const entry: Entry = .{
            .type_id = type_id.fromType(T),
            .runtime_name = runtime_name,
            .runtime_fingerprint64 = runtime_fp,
            .stable_name = if (stable_identity) |identity| identity.name else null,
            .stable_version = if (stable_identity) |identity| identity.version else null,
            .stable_fingerprint64 = stable_fp,
        };
        try self.register(entry);
        // Postcondition: len increased by exactly one.
        assert(self.len_used == len_before + 1);
    }

    /// Return true if a type with the given id has been registered.
    pub fn contains(self: *const TypeRegistry, id: TypeId) bool {
        // Invariant: used count is always within capacity.
        assert(self.len_used <= self.entries.len);
        return self.findIndex(id) != null;
    }

    /// Retrieve a registered entry by id, or return NotFound.
    ///
    /// Postconditions: on success, returned entry.type_id == id.
    pub fn get(self: *const TypeRegistry, id: TypeId) RegistryError!Entry {
        const index = self.findIndex(id) orelse return error.NotFound;
        const result = self.entries[index];
        // Postcondition: returned entry matches the queried id.
        assert(result.type_id == id);
        return result;
    }

    fn findIndex(self: *const TypeRegistry, id: TypeId) ?usize {
        assert(self.len_used <= self.entries.len);
        var index: usize = 0;
        while (index < self.len_used) : (index += 1) {
            if (self.entries[index].type_id == id) return index;
        }
        return null;
    }
};

test "init rejects zero capacity storage" {
    var empty: [0]Entry = .{};
    try testing.expectError(error.InvalidConfig, TypeRegistry.init(empty[0..]));
}

test "registerType inserts entry and lookup works" {
    const First = struct {
        pub const static_name: []const u8 = "tests/first";
        pub const static_version: u32 = 1;
    };

    var storage: [4]Entry = undefined;
    var registry = try TypeRegistry.init(storage[0..]);
    try registry.registerType(First);

    const id = type_id.fromType(First);
    try testing.expect(registry.contains(id));
    const entry = try registry.get(id);
    try testing.expectEqualStrings(@typeName(First), entry.runtime_name);
    try testing.expectEqualStrings("tests/first", entry.stable_name.?);
    try testing.expectEqual(@as(u32, 1), entry.stable_version.?);
}

test "registerType returns AlreadyExists for duplicate registration" {
    const Item = struct {};

    var storage: [2]Entry = undefined;
    var registry = try TypeRegistry.init(storage[0..]);
    try registry.registerType(Item);
    try testing.expectError(error.AlreadyExists, registry.registerType(Item));
}

test "registerType returns NoSpaceLeft when full" {
    const A = struct {};
    const B = struct {};

    var storage: [1]Entry = undefined;
    var registry = try TypeRegistry.init(storage[0..]);
    try registry.registerType(A);
    try testing.expectError(error.NoSpaceLeft, registry.registerType(B));
}

test "get returns NotFound for missing type id" {
    const Known = struct {};

    var storage: [2]Entry = undefined;
    var registry = try TypeRegistry.init(storage[0..]);
    try registry.registerType(Known);

    try testing.expectError(error.NotFound, registry.get(type_id.fromName("tests/missing")));
}

test "list preserves insertion order" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    var storage: [3]Entry = undefined;
    var registry = try TypeRegistry.init(storage[0..]);
    try registry.registerType(A);
    try registry.registerType(B);
    try registry.registerType(C);

    const entries = registry.list();
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqual(type_id.fromType(A), entries[0].type_id);
    try testing.expectEqual(type_id.fromType(B), entries[1].type_id);
    try testing.expectEqual(type_id.fromType(C), entries[2].type_id);
}

test "registry remains append only and linear by construction" {
    var storage: [2]Entry = undefined;
    var registry = try TypeRegistry.init(storage[0..]);

    // This package intentionally keeps a single ordered storage slice rather than
    // hidden secondary indexes so callers can reason about capacity and order directly.
    try testing.expectEqual(@as(usize, 0), registry.len());
    try testing.expectEqual(@as(usize, 2), registry.capacity());
    try testing.expectEqual(@as(usize, 0), registry.list().len);
}
