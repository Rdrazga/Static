//! Sparse unbounded spatial grids: `SparseGrid` (2D) and `SparseGrid3D` (3D).
//!
//! This is the dynamic grid family in `static_spatial`.
//!
//! Unlike `UniformGrid`, sparse grids have no fixed world bounds. Cells are created
//! on demand via a hash map keyed on integer cell coordinates, which makes them a
//! better fit for sparse or unbounded worlds where a fixed grid would waste memory.
//!
//! Allocation profile:
//! - `init` creates the top-level map state;
//! - `insertPoint` may allocate when a new cell is created or an existing cell grows.
//!
//! This makes sparse grids a control-plane or sparse-world structure rather than a
//! fixed-cost hot-path structure. Prefer `UniformGrid` or `LooseGrid` when bounded
//! allocation behavior matters more than sparse-world flexibility.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const primitives = @import("primitives.zig");
const AABB2 = primitives.AABB2;
const AABB3 = primitives.AABB3;

pub const SparseGridError = error{OutOfMemory};

// ---------------------------------------------------------------------------
// SparseGrid (2D)
// ---------------------------------------------------------------------------

pub fn SparseGrid(comptime T: type) type {
    return struct {
        const Self = @This();
        const CellKey = struct { cx: i32, cy: i32 };
        const CellList = std.ArrayListUnmanaged(T);
        const CellMap = std.AutoHashMap(CellKey, CellList);

        cells: CellMap,
        cell_size: f32,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, cell_size: f32) Self {
            std.debug.assert(cell_size > 0.0);
            // Postcondition: cell_size is stored accurately (not NaN or inf).
            const self = Self{
                .cells = CellMap.init(allocator),
                .cell_size = cell_size,
                .allocator = allocator,
            };
            std.debug.assert(self.cell_size > 0.0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: cell_size must still be valid (catches double-deinit).
            std.debug.assert(self.cell_size > 0.0);
            var it = self.cells.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.cells.deinit();
        }

        fn cellKey(self: *const Self, x: f32, y: f32) CellKey {
            // Precondition: cell_size must be positive (verified at init).
            std.debug.assert(self.cell_size > 0.0);
            return .{
                .cx = @intFromFloat(@floor(x / self.cell_size)),
                .cy = @intFromFloat(@floor(y / self.cell_size)),
            };
        }

        pub fn insertPoint(self: *Self, x: f32, y: f32, item: T) SparseGridError!void {
            const key = self.cellKey(x, y);
            const gop = self.cells.getOrPut(key) catch return SparseGridError.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            gop.value_ptr.append(self.allocator, item) catch return SparseGridError.OutOfMemory;
        }

        pub fn queryPoint(self: *const Self, x: f32, y: f32) []const T {
            const key = self.cellKey(x, y);
            if (self.cells.get(key)) |list| {
                return list.items;
            }
            return &.{};
        }

        pub fn clear(self: *Self) void {
            // Precondition: cell_size must still be valid.
            std.debug.assert(self.cell_size > 0.0);
            var it = self.cells.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.cells.clearRetainingCapacity();
            // Postcondition: all cells are removed.
            std.debug.assert(self.cells.count() == 0);
        }
    };
}

// ---------------------------------------------------------------------------
// SparseGrid3D
// ---------------------------------------------------------------------------

pub fn SparseGrid3D(comptime T: type) type {
    return struct {
        const Self = @This();
        const CellKey = struct { cx: i32, cy: i32, cz: i32 };
        const CellList = std.ArrayListUnmanaged(T);
        const CellMap = std.AutoHashMap(CellKey, CellList);

        cells: CellMap,
        cell_size: f32,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, cell_size: f32) Self {
            std.debug.assert(cell_size > 0.0);
            // Postcondition: cell_size is stored accurately (not NaN or inf).
            const self = Self{
                .cells = CellMap.init(allocator),
                .cell_size = cell_size,
                .allocator = allocator,
            };
            std.debug.assert(self.cell_size > 0.0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: cell_size must still be valid (catches double-deinit).
            std.debug.assert(self.cell_size > 0.0);
            var it = self.cells.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.cells.deinit();
        }

        fn cellKey(self: *const Self, x: f32, y: f32, z: f32) CellKey {
            // Precondition: cell_size must be positive (verified at init).
            std.debug.assert(self.cell_size > 0.0);
            return .{
                .cx = @intFromFloat(@floor(x / self.cell_size)),
                .cy = @intFromFloat(@floor(y / self.cell_size)),
                .cz = @intFromFloat(@floor(z / self.cell_size)),
            };
        }

        pub fn insertPoint(self: *Self, x: f32, y: f32, z: f32, item: T) SparseGridError!void {
            const key = self.cellKey(x, y, z);
            const gop = self.cells.getOrPut(key) catch return SparseGridError.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            gop.value_ptr.append(self.allocator, item) catch return SparseGridError.OutOfMemory;
        }

        pub fn queryPoint(self: *const Self, x: f32, y: f32, z: f32) []const T {
            const key = self.cellKey(x, y, z);
            if (self.cells.get(key)) |list| {
                return list.items;
            }
            return &.{};
        }

        pub fn clear(self: *Self) void {
            // Precondition: cell_size must still be valid.
            std.debug.assert(self.cell_size > 0.0);
            var it = self.cells.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.cells.clearRetainingCapacity();
            // Postcondition: all cells are removed.
            std.debug.assert(self.cells.count() == 0);
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "SparseGrid insertPoint and queryPoint" {
    var grid = SparseGrid(u32).init(testing.allocator, 10.0);
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 1);
    try grid.insertPoint(7.0, 3.0, 2);
    try grid.insertPoint(15.0, 25.0, 3);

    // Both (5,5) and (7,3) fall into cell (0,0) with cell_size=10.
    const items_a = grid.queryPoint(5.0, 5.0);
    try testing.expectEqual(@as(usize, 2), items_a.len);
    try testing.expectEqual(@as(u32, 1), items_a[0]);
    try testing.expectEqual(@as(u32, 2), items_a[1]);

    // (15,25) falls into cell (1,2).
    const items_b = grid.queryPoint(15.0, 25.0);
    try testing.expectEqual(@as(usize, 1), items_b.len);
    try testing.expectEqual(@as(u32, 3), items_b[0]);

    // Query an empty cell returns empty slice.
    const items_c = grid.queryPoint(100.0, 100.0);
    try testing.expectEqual(@as(usize, 0), items_c.len);
}

test "SparseGrid clear" {
    var grid = SparseGrid(u32).init(testing.allocator, 10.0);
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 1);
    try grid.insertPoint(15.0, 25.0, 2);

    grid.clear();

    // After clear, all queries return empty.
    const items = grid.queryPoint(5.0, 5.0);
    try testing.expectEqual(@as(usize, 0), items.len);

    // Can re-insert after clear.
    try grid.insertPoint(5.0, 5.0, 42);
    const items2 = grid.queryPoint(5.0, 5.0);
    try testing.expectEqual(@as(usize, 1), items2.len);
    try testing.expectEqual(@as(u32, 42), items2[0]);
}

test "SparseGrid3D insertPoint and queryPoint" {
    var grid = SparseGrid3D(u32).init(testing.allocator, 10.0);
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 5.0, 1);
    try grid.insertPoint(7.0, 3.0, 8.0, 2);
    try grid.insertPoint(15.0, 25.0, 35.0, 3);

    // Both (5,5,5) and (7,3,8) fall into cell (0,0,0) with cell_size=10.
    const items_a = grid.queryPoint(5.0, 5.0, 5.0);
    try testing.expectEqual(@as(usize, 2), items_a.len);
    try testing.expectEqual(@as(u32, 1), items_a[0]);
    try testing.expectEqual(@as(u32, 2), items_a[1]);

    // (15,25,35) falls into cell (1,2,3).
    const items_b = grid.queryPoint(15.0, 25.0, 35.0);
    try testing.expectEqual(@as(usize, 1), items_b.len);
    try testing.expectEqual(@as(u32, 3), items_b[0]);

    // Query an empty cell returns empty slice.
    const items_c = grid.queryPoint(100.0, 100.0, 100.0);
    try testing.expectEqual(@as(usize, 0), items_c.len);
}
