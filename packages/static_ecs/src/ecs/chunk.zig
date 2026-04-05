const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const memory = @import("static_memory");
const component_registry_mod = @import("component_registry.zig");
const archetype_key_mod = @import("archetype_key.zig");

pub fn Chunk(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const Key = archetype_key_mod.ArchetypeKey(Components);
    const component_universe_count_u32 = Registry.count();
    const component_universe_count: usize = component_universe_count_u32;

    return struct {
        const Self = @This();

        pub const Error = Key.Error || error{
            InvalidConfig,
            OutOfMemory,
            NoSpaceLeft,
            Overflow,
        };

        pub const ColumnLayout = struct {
            present: bool,
            materialized: bool,
            element_size: u32,
            alignment: u32,
            stride: u32,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        key: Key,
        rows_capacity: u32,
        rows_len: u32,
        reserved_bytes: usize,
        column_addrs: [component_universe_count]usize,

        pub fn init(
            allocator: std.mem.Allocator,
            key: Key,
            rows_capacity: u32,
            budget: ?*memory.budget.Budget,
        ) Error!Self {
            if (rows_capacity == 0) return error.InvalidConfig;

            const reserved_bytes = try totalAllocBytes(Components, key, rows_capacity);
            if (budget) |tracked_budget| {
                try tracked_budget.tryReserve(reserved_bytes);
            }
            errdefer if (budget) |tracked_budget| tracked_budget.release(reserved_bytes);

            var self: Self = .{
                .allocator = allocator,
                .budget = budget,
                .key = key,
                .rows_capacity = rows_capacity,
                .rows_len = 0,
                .reserved_bytes = reserved_bytes,
                .column_addrs = [_]usize{0} ** component_universe_count,
            };
            errdefer self.deinitPartial();

            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                if (key.containsId(id) and @sizeOf(T) != 0) {
                    const column = allocator.alloc(T, rows_capacity) catch return error.OutOfMemory;
                    self.column_addrs[index] = @intFromPtr(column.ptr);
                    assert(self.column_addrs[index] % @alignOf(T) == 0);
                }
            }

            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            self.deinitPartial();
            self.* = undefined;
        }

        pub fn rowCount(self: *const Self) u32 {
            self.assertInvariants();
            return self.rows_len;
        }

        pub fn capacity(self: *const Self) u32 {
            self.assertInvariants();
            return self.rows_capacity;
        }

        pub fn setRowCount(self: *Self, rows_len: u32) Error!void {
            self.assertInvariants();
            if (rows_len > self.rows_capacity) return error.NoSpaceLeft;

            self.rows_len = rows_len;
            assert(self.rows_len <= self.rows_capacity);
            self.assertInvariants();
        }

        pub fn hasComponent(self: *const Self, comptime T: type) bool {
            self.assertInvariants();
            return self.key.containsType(T);
        }

        pub fn hasMaterializedColumn(self: *const Self, comptime T: type) bool {
            self.assertInvariants();
            const maybe_id = Registry.typeId(T);
            if (maybe_id == null) return false;
            if (!self.key.containsId(maybe_id.?)) return false;
            return @sizeOf(T) != 0;
        }

        pub fn columnLayout(self: *const Self, comptime T: type) ColumnLayout {
            self.assertInvariants();
            const maybe_id = Registry.typeId(T);
            if (maybe_id == null) {
                return .{
                    .present = false,
                    .materialized = false,
                    .element_size = 0,
                    .alignment = @intCast(@alignOf(T)),
                    .stride = 0,
                };
            }

            const present = self.key.containsId(maybe_id.?);
            const materialized = present and @sizeOf(T) != 0;
            const element_size: u32 = @intCast(@sizeOf(T));
            const alignment: u32 = @intCast(@alignOf(T));
            const stride: u32 = if (materialized) element_size else 0;

            if (materialized) assert(stride == element_size);
            if (!materialized) assert(stride == 0);

            return .{
                .present = present,
                .materialized = materialized,
                .element_size = element_size,
                .alignment = alignment,
                .stride = stride,
            };
        }

        pub fn columnSlice(self: *Self, comptime T: type) ?[]T {
            self.assertInvariants();
            const maybe_id = Registry.typeId(T);
            if (maybe_id == null) return null;
            if (!self.key.containsId(maybe_id.?)) return null;
            if (@sizeOf(T) == 0) return null;

            const index = maybe_id.?.value;
            const addr = self.column_addrs[index];
            assert(addr != 0);
            assert(addr % @alignOf(T) == 0);

            const ptr: [*]T = @ptrFromInt(addr);
            const slice = ptr[0..self.rows_len];
            assert(slice.len == self.rows_len);
            return slice;
        }

        pub fn columnSliceConst(self: *const Self, comptime T: type) ?[]const T {
            const mutable_self: *Self = @constCast(self);
            const slice = mutable_self.columnSlice(T) orelse return null;
            return slice;
        }

        fn deinitPartial(self: *Self) void {
            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                if (@sizeOf(T) != 0) {
                    const addr = self.column_addrs[index];
                    if (addr != 0) {
                        assert(addr % @alignOf(T) == 0);
                        const ptr: [*]T = @ptrFromInt(addr);
                        self.allocator.free(ptr[0..self.rows_capacity]);
                        self.column_addrs[index] = 0;
                    }
                }
            }

            if (self.budget) |tracked_budget| {
                tracked_budget.release(self.reserved_bytes);
                self.budget = null;
            }
        }

        fn assertInvariants(self: *const Self) void {
            assert(self.rows_capacity > 0);
            assert(self.rows_len <= self.rows_capacity);
            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                const present = self.key.containsId(id);
                const addr = self.column_addrs[index];

                if (!present or @sizeOf(T) == 0) {
                    assert(addr == 0);
                } else {
                    assert(addr != 0);
                    assert(addr % @alignOf(T) == 0);
                }
            }
        }
    };
}

fn totalAllocBytes(
    comptime Components: anytype,
    key: archetype_key_mod.ArchetypeKey(Components),
    rows_capacity: u32,
) error{Overflow}!usize {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const component_universe_count: usize = comptime Registry.count();
    var total_bytes: usize = 0;

    inline for (0..component_universe_count) |index| {
        const T = Registry.typeAt(index);
        const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
        if (key.containsId(id) and @sizeOf(T) != 0) {
            const column_bytes = std.math.mul(usize, rows_capacity, @sizeOf(T)) catch return error.Overflow;
            total_bytes = std.math.add(usize, total_bytes, column_bytes) catch return error.Overflow;
        }
    }

    return total_bytes;
}

test "chunk materializes only present non-zero-sized columns" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Tag = struct {};
    const Key = archetype_key_mod.ArchetypeKey(.{ Position, Velocity, Tag });
    const TestChunk = Chunk(.{ Position, Velocity, Tag });

    const key = Key.fromTypes(.{ Position, Tag });
    var chunk = try TestChunk.init(testing.allocator, key, 8, null);
    defer chunk.deinit();

    try chunk.setRowCount(3);
    try testing.expectEqual(@as(u32, 3), chunk.rowCount());
    try testing.expectEqual(@as(u32, 8), chunk.capacity());
    try testing.expect(chunk.hasComponent(Position));
    try testing.expect(!chunk.hasComponent(Velocity));
    try testing.expect(chunk.hasComponent(Tag));
    try testing.expect(chunk.hasMaterializedColumn(Position));
    try testing.expect(!chunk.hasMaterializedColumn(Tag));
    try testing.expect(chunk.columnSlice(Position) != null);
    try testing.expect(chunk.columnSlice(Velocity) == null);
    try testing.expect(chunk.columnSlice(Tag) == null);
}

test "chunk reports layout for present tags and typed columns" {
    const Position = struct { x: f32, y: f32 };
    const Tag = struct {};
    const Key = archetype_key_mod.ArchetypeKey(.{ Position, Tag });
    const TestChunk = Chunk(.{ Position, Tag });

    const key = Key.fromTypes(.{ Position, Tag });
    var chunk = try TestChunk.init(testing.allocator, key, 4, null);
    defer chunk.deinit();

    const position_layout = chunk.columnLayout(Position);
    try testing.expect(position_layout.present);
    try testing.expect(position_layout.materialized);
    try testing.expectEqual(@as(u32, @sizeOf(Position)), position_layout.element_size);
    try testing.expectEqual(@as(u32, @alignOf(Position)), position_layout.alignment);
    try testing.expectEqual(@as(u32, @sizeOf(Position)), position_layout.stride);

    const tag_layout = chunk.columnLayout(Tag);
    try testing.expect(tag_layout.present);
    try testing.expect(!tag_layout.materialized);
    try testing.expectEqual(@as(u32, 0), tag_layout.element_size);
    try testing.expectEqual(@as(u32, 0), tag_layout.stride);
}

test "chunk rejects row counts above capacity" {
    const Position = struct { x: f32, y: f32 };
    const Key = archetype_key_mod.ArchetypeKey(.{ Position });
    const TestChunk = Chunk(.{ Position });

    const key = Key.fromTypes(.{ Position });
    var chunk = try TestChunk.init(testing.allocator, key, 2, null);
    defer chunk.deinit();

    try testing.expectError(error.NoSpaceLeft, chunk.setRowCount(3));
}
