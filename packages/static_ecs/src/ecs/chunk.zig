const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const memory = @import("static_memory");
const entity_mod = @import("entity.zig");
const component_registry_mod = @import("component_registry.zig");
const archetype_key_mod = @import("archetype_key.zig");

pub fn Chunk(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const Key = archetype_key_mod.ArchetypeKey(Components);
    const component_universe_count: usize = comptime Registry.count();

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

        const ColumnMeta = struct {
            id: component_registry_mod.ComponentTypeId,
            offset: usize,
        };

        const storage_alignment = storageAlignment();

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        key: Key,
        rows_capacity: u32,
        rows_len: u32,
        reserved_bytes: usize,
        storage: []align(storage_alignment) u8,
        column_meta_len: u32,
        entities_offset: usize,
        column_meta_offset: usize,

        pub fn init(
            allocator: std.mem.Allocator,
            key: Key,
            rows_capacity: u32,
            budget: ?*memory.budget.Budget,
        ) Error!Self {
            if (rows_capacity == 0) return error.InvalidConfig;

            const layout = try computeLayout(key, rows_capacity);
            if (budget) |tracked_budget| {
                try tracked_budget.tryReserve(layout.total_bytes);
            }
            errdefer if (budget) |tracked_budget| tracked_budget.release(layout.total_bytes);

            const storage = allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(storage_alignment), layout.total_bytes) catch return error.OutOfMemory;
            errdefer allocator.free(storage);
            @memset(storage, 0);

            var self: Self = .{
                .allocator = allocator,
                .budget = budget,
                .key = key,
                .rows_capacity = rows_capacity,
                .rows_len = 0,
                .reserved_bytes = layout.total_bytes,
                .storage = storage,
                .column_meta_len = layout.column_meta_len,
                .entities_offset = layout.entities_offset,
                .column_meta_offset = layout.column_meta_offset,
            };
            self.initColumnMeta();
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            self.allocator.free(self.storage);
            if (self.budget) |tracked_budget| {
                tracked_budget.release(self.reserved_bytes);
            }
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

        pub fn entitySlice(self: *Self) []entity_mod.Entity {
            self.assertInvariants();
            return self.entityStorage()[0..self.rows_len];
        }

        pub fn entitySliceConst(self: *const Self) []const entity_mod.Entity {
            const mutable_self: *Self = @constCast(self);
            return mutable_self.entitySlice();
        }

        pub fn entityStorage(self: *Self) []entity_mod.Entity {
            self.assertInvariants();
            const ptr = self.ptrAt(entity_mod.Entity, self.entities_offset);
            return ptr[0..self.rows_capacity];
        }

        pub fn entityStorageConst(self: *const Self) []const entity_mod.Entity {
            const mutable_self: *Self = @constCast(self);
            return mutable_self.entityStorage();
        }

        pub fn columnSlice(self: *Self, comptime T: type) ?[]T {
            self.assertInvariants();
            const maybe_id = Registry.typeId(T);
            if (maybe_id == null) return null;
            if (!self.key.containsId(maybe_id.?)) return null;
            if (@sizeOf(T) == 0) return null;

            const meta = self.findColumnMeta(maybe_id.?) orelse return null;
            const ptr = self.ptrAt(T, meta.offset);
            const slice = ptr[0..self.rows_len];
            assert(slice.len == self.rows_len);
            return slice;
        }

        pub fn columnSliceConst(self: *const Self, comptime T: type) ?[]const T {
            const mutable_self: *Self = @constCast(self);
            const slice = mutable_self.columnSlice(T) orelse return null;
            return slice;
        }

        fn initColumnMeta(self: *Self) void {
            const metas = self.columnMetaStorage();
            const layout = computeLayout(self.key, self.rows_capacity) catch unreachable;
            assert(metas.len == layout.column_meta_len);

            var next_meta_index: usize = 0;
            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                if (self.key.containsId(id) and @sizeOf(T) != 0) {
                    metas[next_meta_index] = .{
                        .id = id,
                        .offset = layout.column_offsets[next_meta_index],
                    };
                    next_meta_index += 1;
                }
            }
            assert(next_meta_index == metas.len);
        }

        fn columnMetaStorage(self: *Self) []ColumnMeta {
            const ptr = self.ptrAt(ColumnMeta, self.column_meta_offset);
            return ptr[0..self.column_meta_len];
        }

        fn columnMetaStorageConst(self: *const Self) []const ColumnMeta {
            const mutable_self: *Self = @constCast(self);
            return mutable_self.columnMetaStorage();
        }

        fn findColumnMeta(self: *const Self, id: component_registry_mod.ComponentTypeId) ?ColumnMeta {
            for (self.columnMetaStorageConst()) |meta| {
                if (meta.id.value == id.value) return meta;
                if (meta.id.value > id.value) return null;
            }
            return null;
        }

        fn ptrAt(self: *Self, comptime T: type, offset: usize) [*]T {
            const base: [*]align(storage_alignment) u8 = self.storage.ptr;
            const addr = @intFromPtr(base) + offset;
            assert(addr % @alignOf(T) == 0);
            return @ptrFromInt(addr);
        }

        fn assertInvariants(self: *const Self) void {
            if (!std.debug.runtime_safety) return;
            assert(self.rows_capacity > 0);
            assert(self.rows_len <= self.rows_capacity);
            assert(self.storage.len == self.reserved_bytes);

            const metas = self.columnMetaStorageConst();
            var previous_id: ?u32 = null;
            for (metas) |meta| {
                assert(meta.id.value < component_universe_count);
                if (previous_id) |prev| {
                    assert(prev < meta.id.value);
                }
                previous_id = meta.id.value;
            }

            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                const present = self.key.containsId(id);
                const meta = self.findColumnMeta(id);
                if (!present or @sizeOf(T) == 0) {
                    assert(meta == null);
                } else {
                    assert(meta != null);
                    const addr = @intFromPtr(self.storage.ptr) + meta.?.offset;
                    assert(addr % @alignOf(T) == 0);
                }
            }
        }

        fn storageAlignment() usize {
            var align_max: usize = @alignOf(entity_mod.Entity);
            align_max = @max(align_max, @alignOf(ColumnMeta));
            inline for (0..component_universe_count) |index| {
                align_max = @max(align_max, @alignOf(Registry.typeAt(index)));
            }
            return align_max;
        }

        const Layout = struct {
            total_bytes: usize,
            column_meta_len: u32,
            entities_offset: usize,
            column_meta_offset: usize,
            column_offsets: [component_universe_count]usize,
        };

        fn computeLayout(key: Key, rows_capacity: u32) error{Overflow}!Layout {
            var total_bytes: usize = 0;
            var column_offsets = [_]usize{0} ** component_universe_count;
            var column_meta_len: u32 = 0;
            var next_column_offset_index: usize = 0;

            const column_meta_offset = 0;
            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                if (key.containsId(id) and @sizeOf(T) != 0) {
                    column_meta_len += 1;
                }
            }

            const meta_bytes = std.math.mul(usize, column_meta_len, @sizeOf(ColumnMeta)) catch return error.Overflow;
            total_bytes = std.mem.alignForward(usize, total_bytes, @alignOf(ColumnMeta));
            assert(total_bytes == column_meta_offset);
            total_bytes = std.math.add(usize, total_bytes, meta_bytes) catch return error.Overflow;

            total_bytes = std.mem.alignForward(usize, total_bytes, @alignOf(entity_mod.Entity));
            const entities_offset = total_bytes;
            const entity_bytes = std.math.mul(usize, rows_capacity, @sizeOf(entity_mod.Entity)) catch return error.Overflow;
            total_bytes = std.math.add(usize, total_bytes, entity_bytes) catch return error.Overflow;

            inline for (0..component_universe_count) |index| {
                const T = Registry.typeAt(index);
                const id: component_registry_mod.ComponentTypeId = .{ .value = @intCast(index) };
                if (key.containsId(id) and @sizeOf(T) != 0) {
                    total_bytes = std.mem.alignForward(usize, total_bytes, @alignOf(T));
                    column_offsets[next_column_offset_index] = total_bytes;
                    next_column_offset_index += 1;
                    const column_bytes = std.math.mul(usize, rows_capacity, @sizeOf(T)) catch return error.Overflow;
                    total_bytes = std.math.add(usize, total_bytes, column_bytes) catch return error.Overflow;
                }
            }

            if (total_bytes == 0) return error.Overflow;
            return .{
                .total_bytes = total_bytes,
                .column_meta_len = column_meta_len,
                .entities_offset = entities_offset,
                .column_meta_offset = column_meta_offset,
                .column_offsets = column_offsets,
            };
        }
    };
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
