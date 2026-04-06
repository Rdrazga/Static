const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const hash = @import("static_hash");
const component_registry_mod = @import("component_registry.zig");

pub fn ArchetypeKey(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const component_universe_count_u32 = Registry.count();
    const component_universe_count: usize = component_universe_count_u32;
    const word_bits: usize = @bitSizeOf(usize);
    const word_count: usize = if (component_universe_count == 0) 0 else (component_universe_count + word_bits - 1) / word_bits;

    return struct {
        const Self = @This();

        pub const Error = error{
            ComponentOutOfRange,
            DuplicateComponent,
            TooManyComponents,
            UnsortedComponentIds,
        };

        words: [word_count]usize = [_]usize{0} ** word_count,
        ids_len: u32 = 0,

        pub fn empty() Self {
            const key: Self = .{};
            assert(key.count() == 0);
            assert(key.fingerprint64() == 0);
            return key;
        }

        pub fn fromSortedIds(sorted_ids: []const component_registry_mod.ComponentTypeId) Error!Self {
            var key = Self.empty();
            try key.assignSortedIds(sorted_ids);
            key.assertInvariants();
            return key;
        }

        pub fn fromTypes(comptime Included: anytype) Self {
            comptime validateIncludedSubset(Included, Registry);

            var key = Self.empty();
            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                if (tupleContainsType(Included, T)) {
                    key.appendAssumeSorted(.{ .value = @intCast(index) });
                }
            }
            key.assertInvariants();
            return key;
        }

        pub fn count(self: Self) u32 {
            self.assertInvariants();
            return self.ids_len;
        }

        pub fn containsId(self: Self, id: component_registry_mod.ComponentTypeId) bool {
            self.assertInvariants();
            if (id.value >= component_universe_count_u32) return false;
            return self.containsIdUnchecked(id);
        }

        pub fn containsType(self: Self, comptime T: type) bool {
            self.assertInvariants();
            const maybe_id = Registry.typeId(T);
            if (maybe_id == null) return false;
            return self.containsIdUnchecked(maybe_id.?);
        }

        pub fn withId(self: Self, id: component_registry_mod.ComponentTypeId) Error!Self {
            self.assertInvariants();
            if (id.value >= component_universe_count_u32) return error.ComponentOutOfRange;
            if (self.containsIdUnchecked(id)) return self;
            if (self.ids_len >= component_universe_count_u32) return error.TooManyComponents;

            var key = self;
            key.setBit(id, true);
            key.ids_len += 1;
            key.assertInvariants();
            return key;
        }

        pub fn withoutId(self: Self, id: component_registry_mod.ComponentTypeId) Self {
            self.assertInvariants();
            if (id.value >= component_universe_count_u32) return self;
            if (!self.containsIdUnchecked(id)) return self;

            var key = self;
            key.setBit(id, false);
            assert(key.ids_len > 0);
            key.ids_len -= 1;
            key.assertInvariants();
            return key;
        }

        pub fn withType(self: Self, comptime T: type) Error!Self {
            comptime validateComponentType(T, Registry);
            return self.withId(Registry.typeId(T).?);
        }

        pub fn withoutType(self: Self, comptime T: type) Self {
            comptime validateComponentType(T, Registry);
            return self.withoutId(Registry.typeId(T).?);
        }

        pub fn fingerprint64(self: Self) u64 {
            self.assertInvariants();

            var fingerprint: u64 = 0;
            var word_index: usize = 0;
            while (word_index < word_count) : (word_index += 1) {
                var word = self.words[word_index];
                while (word != 0) {
                    const trailing: usize = @ctz(word);
                    const bit_index = word_index * word_bits + trailing;
                    if (bit_index >= component_universe_count) break;
                    fingerprint = hash.combineOrdered64(.{
                        .left = fingerprint,
                        .right = @as(u64, @intCast(bit_index)),
                    });
                    word &= word - 1;
                }
            }

            assert(self.ids_len == 0 or fingerprint != 0);
            return fingerprint;
        }

        fn assignSortedIds(self: *Self, sorted_ids: []const component_registry_mod.ComponentTypeId) Error!void {
            if (sorted_ids.len > component_universe_count) return error.TooManyComponents;

            self.words = [_]usize{0} ** word_count;
            self.ids_len = 0;
            for (sorted_ids, 0..) |id, index| {
                if (id.value >= component_universe_count_u32) return error.ComponentOutOfRange;
                if (index > 0) {
                    const prev = sorted_ids[index - 1];
                    if (prev.value == id.value) return error.DuplicateComponent;
                    if (prev.value > id.value) return error.UnsortedComponentIds;
                }
                self.setBit(id, true);
            }
            self.ids_len = @intCast(sorted_ids.len);
        }

        fn appendAssumeSorted(self: *Self, id: component_registry_mod.ComponentTypeId) void {
            assert(id.value < component_universe_count_u32);
            if (self.ids_len > 0) {
                const last = self.lastId().?;
                assert(last.value < id.value);
            }
            assert(!self.containsIdUnchecked(id));

            self.setBit(id, true);
            self.ids_len += 1;
            assert(self.ids_len <= component_universe_count_u32);
        }

        fn containsIdUnchecked(self: Self, id: component_registry_mod.ComponentTypeId) bool {
            const bit_index: usize = id.value;
            const word_index = bit_index / word_bits;
            const bit_offset = bit_index % word_bits;
            return (self.words[word_index] & (@as(usize, 1) << @intCast(bit_offset))) != 0;
        }

        fn setBit(self: *Self, id: component_registry_mod.ComponentTypeId, present: bool) void {
            const bit_index: usize = id.value;
            const word_index = bit_index / word_bits;
            const bit_offset = bit_index % word_bits;
            const mask = @as(usize, 1) << @intCast(bit_offset);
            if (present) {
                self.words[word_index] |= mask;
            } else {
                self.words[word_index] &= ~mask;
            }
        }

        fn lastId(self: Self) ?component_registry_mod.ComponentTypeId {
            if (self.ids_len == 0) return null;

            var word_index: usize = word_count;
            while (word_index > 0) {
                word_index -= 1;
                const word = self.words[word_index];
                if (word == 0) continue;

                const leading = @clz(word);
                const highest_bit = word_bits - 1 - @as(usize, leading);
                const bit_index = word_index * word_bits + highest_bit;
                if (bit_index < component_universe_count) {
                    return .{ .value = @intCast(bit_index) };
                }
            }
            return null;
        }

        fn assertInvariants(self: Self) void {
            assert(self.ids_len <= component_universe_count_u32);

            var counted: u32 = 0;
            var previous: ?u32 = null;
            var word_index: usize = 0;
            while (word_index < word_count) : (word_index += 1) {
                var word = self.words[word_index];
                while (word != 0) {
                    const trailing: usize = @ctz(word);
                    const bit_index = word_index * word_bits + trailing;
                    if (bit_index >= component_universe_count) break;
                    if (previous) |prev| {
                        assert(prev < bit_index);
                    }
                    previous = @intCast(bit_index);
                    counted += 1;
                    word &= word - 1;
                }
            }
            assert(counted == self.ids_len);
        }
    };
}

fn includedFields(comptime Included: anytype) []const std.builtin.Type.StructField {
    const info = @typeInfo(@TypeOf(Included));
    switch (info) {
        .@"struct" => |struct_info| {
            if (!struct_info.is_tuple) {
                @compileError("ArchetypeKey.fromTypes expects a comptime tuple of component types.");
            }
            return struct_info.fields;
        },
        else => @compileError("ArchetypeKey.fromTypes expects a comptime tuple of component types."),
    }
}

fn tupleContainsType(comptime Included: anytype, comptime T: type) bool {
    const fields = includedFields(Included);
    inline for (fields) |field| {
        const candidate = @field(Included, field.name);
        if (@TypeOf(candidate) != type) {
            @compileError("ArchetypeKey.fromTypes entries must be types.");
        }
        if (candidate == T) return true;
    }
    return false;
}

fn validateIncludedSubset(comptime Included: anytype, comptime Registry: type) void {
    const fields = includedFields(Included);
    inline for (fields, 0..) |field_i, index_i| {
        const component_i = @field(Included, field_i.name);
        if (@TypeOf(component_i) != type) {
            @compileError("ArchetypeKey.fromTypes entries must be types.");
        }
        if (!Registry.contains(component_i)) {
            @compileError("ArchetypeKey.fromTypes entries must come from the component universe.");
        }

        inline for (fields[0..index_i]) |field_j| {
            const component_j = @field(Included, field_j.name);
            if (component_i == component_j) {
                @compileError("ArchetypeKey.fromTypes must not contain duplicate component types.");
            }
        }
    }
}

fn validateComponentType(comptime T: type, comptime Registry: type) void {
    if (!Registry.contains(T)) {
        @compileError("ArchetypeKey component helpers require a type from the component universe.");
    }
}

test "archetype key preserves deterministic sorted ids and ordered fingerprint" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Tag = struct {};
    const Key = ArchetypeKey(.{ Position, Velocity, Tag });

    const key = try Key.fromSortedIds(&.{
        .{ .value = 0 },
        .{ .value = 2 },
    });

    try testing.expectEqual(@as(u32, 2), key.count());
    try testing.expect(key.containsType(Position));
    try testing.expect(!key.containsType(Velocity));
    try testing.expect(key.containsType(Tag));
    try testing.expect(key.fingerprint64() != 0);
}

test "archetype key rejects duplicate and unsorted ids" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Key = ArchetypeKey(.{ Position, Velocity });

    try testing.expectError(error.DuplicateComponent, Key.fromSortedIds(&.{
        .{ .value = 0 },
        .{ .value = 0 },
    }));
    try testing.expectError(error.UnsortedComponentIds, Key.fromSortedIds(&.{
        .{ .value = 1 },
        .{ .value = 0 },
    }));
}

test "archetype key adds and removes ids while preserving sorted membership" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Tag = struct {};
    const Key = ArchetypeKey(.{ Position, Velocity, Tag });

    const empty = Key.empty();
    const with_position = try empty.withType(Position);
    try testing.expect(with_position.containsType(Position));
    try testing.expect(!with_position.containsType(Velocity));

    const with_all = try with_position.withType(Tag);
    try testing.expect(with_all.containsType(Position));
    try testing.expect(with_all.containsType(Tag));
    try testing.expectEqual(@as(u32, 2), with_all.count());

    const without_position = with_all.withoutType(Position);
    try testing.expect(!without_position.containsType(Position));
    try testing.expect(without_position.containsType(Tag));
    try testing.expectEqual(@as(u32, 1), without_position.count());
}
