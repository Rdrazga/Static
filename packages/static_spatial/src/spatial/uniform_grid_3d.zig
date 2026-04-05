//! Uniform Spatial Grid (3D)
//!
//! A bounded 3D uniform grid for broad-phase spatial queries. Fixed per-cell
//! capacity provides deterministic memory usage and bounded query time.
//!
//! ## Thread Safety
//!
//! Single-threaded. External synchronization required for concurrent access.
//!
//! ## Allocation Profile
//!
//! - `init`: O(cells_x * cells_y * cells_z * max_per_cell) allocation
//! - All operations after init are allocation-free
//!
//! ## Example
//!
//! ```zig
//! const Grid = UniformGrid3D(u32, 16);
//! var grid = try Grid.init(allocator, .{
//!     .min_x = 0, .min_y = 0, .min_z = 0,
//!     .max_x = 100, .max_y = 100, .max_z = 100,
//!     .cells_x = 10, .cells_y = 10, .cells_z = 10,
//! });
//! defer grid.deinit();
//!
//! try grid.insertPoint(25, 35, 45, entity_id);
//! var out: [64]u32 = undefined;
//! const count = grid.queryAABB(query_bounds, &out);
//! ```

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const primitives = @import("primitives.zig");
const AABB3 = primitives.AABB3;
const GridConfig3D = primitives.GridConfig3D;

/// Error set for UniformGrid3D operations.
pub const UniformGrid3DError = error{ CellFull, OutOfBounds };

/// 3D uniform spatial grid parameterized by value type and max items per cell.
///
/// The grid divides world space into a regular 3D grid of cells. Each cell can
/// hold up to `max_per_cell` items. Items spanning multiple cells are stored
/// in each overlapping cell (duplicates possible in query results).
pub fn UniformGrid3D(comptime T: type, comptime max_per_cell: u32) type {
    comptime {
        if (max_per_cell == 0) @compileError("UniformGrid3D max_per_cell must be > 0");
        assert(@sizeOf(T) > 0);
    }

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        cfg: GridConfig3D,

        cell_counts: []u32,
        items: []T,

        /// Initialize grid with given configuration.
        ///
        /// Preconditions: cfg.cells_x/y/z > 0, cfg.max > cfg.min for all axes.
        /// Postconditions: empty grid ready for insertions.
        /// Allocates: O(cells_x * cells_y * cells_z * max_per_cell).
        /// Thread-safety: single-threaded.
        pub fn init(allocator: std.mem.Allocator, cfg: GridConfig3D) !Self {
            assert(cfg.cells_x > 0);
            assert(cfg.cells_y > 0);
            assert(cfg.cells_z > 0);
            const cell_count: usize = @as(usize, cfg.cells_x) *
                @as(usize, cfg.cells_y) *
                @as(usize, cfg.cells_z);

            const cell_counts = try allocator.alloc(u32, cell_count);
            errdefer allocator.free(cell_counts);
            @memset(cell_counts, 0);

            const item_count = cell_count * @as(usize, max_per_cell);
            const items = try allocator.alloc(T, item_count);
            errdefer allocator.free(items);

            return .{
                .allocator = allocator,
                .cfg = cfg,
                .cell_counts = cell_counts,
                .items = items,
            };
        }

        /// Free all allocated memory.
        ///
        /// Preconditions:
        /// - `self` was initialized with `init`.
        ///
        /// Postconditions:
        /// - All owned memory is returned to the allocator.
        /// - `self` becomes invalid for further use.
        ///
        /// Allocates: no.
        /// Thread-safety: single-threaded.
        pub fn deinit(self: *Self) void {
            // Precondition: slice lengths must be consistent with the grid config.
            const expected_cells: usize = @as(usize, self.cfg.cells_x) *
                @as(usize, self.cfg.cells_y) *
                @as(usize, self.cfg.cells_z);
            assert(self.cell_counts.len == expected_cells);
            assert(self.items.len == expected_cells * @as(usize, max_per_cell));
            self.allocator.free(self.items);
            self.allocator.free(self.cell_counts);
            self.* = undefined;
        }

        /// Insert value at point (x, y, z).
        ///
        /// Preconditions:
        /// - `self` is initialized.
        ///
        /// Postconditions:
        /// - On success: `value` is stored in the cell containing `(x, y, z)`.
        /// - On error: no state change.
        ///
        /// Returns `error.OutOfBounds` if the point is outside the grid.
        /// Returns `error.CellFull` if the target cell is at capacity.
        ///
        /// Allocates: no.
        /// Thread-safety: single-threaded.
        pub fn insertPoint(self: *Self, x: f32, y: f32, z: f32, item: T) UniformGrid3DError!void {
            const idx = self.cfg.cellIndex(x, y, z) orelse return error.OutOfBounds;
            const linear = self.cfg.linearIndex(idx.cx, idx.cy, idx.cz);
            // Precondition: linear index must be within the allocated counts array.
            assert(@as(usize, linear) < self.cell_counts.len);
            try self.insertCell(linear, item);
        }

        /// Insert value into all cells overlapping the AABB.
        ///
        /// The value is duplicated into each overlapping cell. Returns OutOfBounds
        /// if AABB is outside grid, CellFull if any cell would exceed capacity
        /// (in which case no insertion is performed).
        ///
        /// Preconditions:
        /// - `self` is initialized.
        /// - `aabb` is well-formed (`min <= max` for each axis).
        ///
        /// Postconditions:
        /// - On success: `item` is inserted into every overlapped cell.
        /// - On error: no state change.
        ///
        /// Allocates: no.
        /// Thread-safety: single-threaded.
        pub fn insertAABB(self: *Self, aabb: AABB3, item: T) UniformGrid3DError!void {
            // Precondition: AABB must not be inverted.
            assert(aabb.min_x <= aabb.max_x);
            assert(aabb.min_y <= aabb.max_y);
            assert(aabb.min_z <= aabb.max_z);
            const r = self.cellRangeForAABB(aabb) orelse return error.OutOfBounds;

            // Pre-check: verify all cells have space before mutating any state.
            if (!self.cellsHaveSpace(r)) return error.CellFull;

            var iz: u32 = r.min_iz;
            while (iz <= r.max_iz) : (iz += 1) {
                var iy: u32 = r.min_iy;
                while (iy <= r.max_iy) : (iy += 1) {
                    var ix: u32 = r.min_ix;
                    while (ix <= r.max_ix) : (ix += 1) {
                        const linear = self.cfg.linearIndex(ix, iy, iz);
                        self.insertCell(linear, item) catch unreachable;
                    }
                }
            }
        }

        /// Query all values in the cell containing point `(x, y, z)`.
        ///
        /// Returns a slice of the cell contents in insertion order.
        ///
        /// Preconditions:
        /// - `self` is initialized.
        /// - `(x, y, z)` is within the grid bounds.
        ///
        /// Postconditions:
        /// - Returns the contents of the cell as a read-only slice.
        ///
        /// Allocates: no.
        /// Thread-safety: safe for concurrent reads (grid contents must not be mutating).
        pub fn queryPoint(self: *const Self, x: f32, y: f32, z: f32) []const T {
            const idx = self.cfg.cellIndex(x, y, z) orelse return &[_]T{};
            const linear = self.cfg.linearIndex(idx.cx, idx.cy, idx.cz);
            // Precondition: linear index must be within the allocated counts array.
            assert(@as(usize, linear) < self.cell_counts.len);
            return self.cellSlice(linear);
        }

        /// Query all values in cells overlapping the AABB.
        ///
        /// Returns the number of values written to `out`. Note: values spanning
        /// multiple cells may appear multiple times in results.
        ///
        /// Preconditions:
        /// - `self` is initialized.
        /// - `aabb` is well-formed (`min <= max` for each axis).
        ///
        /// Postconditions:
        /// - `out[0..count]` contains the concatenated contents of overlapped cells.
        ///
        /// Allocates: no.
        /// Thread-safety: safe for concurrent reads (grid contents must not be mutating).
        pub fn queryAABB(self: *const Self, aabb: AABB3, out: []T) u32 {
            // Precondition: query AABB must not be inverted.
            assert(aabb.min_x <= aabb.max_x);
            assert(aabb.min_y <= aabb.max_y);
            assert(aabb.min_z <= aabb.max_z);
            const r = self.cellRangeForAABB(aabb) orelse return 0;
            var out_len: u32 = 0;

            var iz: u32 = r.min_iz;
            while (iz <= r.max_iz) : (iz += 1) {
                var iy: u32 = r.min_iy;
                while (iy <= r.max_iy) : (iy += 1) {
                    var ix: u32 = r.min_ix;
                    while (ix <= r.max_ix) : (ix += 1) {
                        const linear = self.cfg.linearIndex(ix, iy, iz);
                        const cell = self.cellSlice(linear);
                        for (cell) |v| {
                            if (out_len >= out.len) return out_len;
                            out[@intCast(out_len)] = v;
                            out_len += 1;
                        }
                    }
                }
            }
            return out_len;
        }

        /// Remove all items from the grid (does not deallocate).
        ///
        /// Preconditions:
        /// - `self` is initialized.
        ///
        /// Postconditions:
        /// - All cells become empty.
        ///
        /// Allocates: no.
        /// Thread-safety: single-threaded.
        pub fn clear(self: *Self) void {
            // Precondition: cell_counts slice must match the total cell count.
            const expected_cells: usize = @as(usize, self.cfg.cells_x) *
                @as(usize, self.cfg.cells_y) *
                @as(usize, self.cfg.cells_z);
            assert(self.cell_counts.len == expected_cells);
            @memset(self.cell_counts, 0);
            // Postcondition: at least the first cell is cleared (representative sample).
            assert(self.cell_counts[0] == 0);
        }

        /// Remove the first occurrence of `item` from the cell containing point `(x, y, z)`.
        ///
        /// Removal is swap-based: the removed slot is replaced by the last item in the cell
        /// (order is not preserved).
        ///
        /// Preconditions:
        /// - `self` is initialized.
        ///
        /// Postconditions:
        /// - Returns `true` if an item was removed.
        /// - Returns `false` if the point is outside the grid or the value was not found.
        ///
        /// Allocates: no.
        /// Thread-safety: single-threaded.
        pub fn remove(self: *Self, x: f32, y: f32, z: f32, item: T) bool {
            const idx = self.cfg.cellIndex(x, y, z) orelse return false;
            const linear = self.cfg.linearIndex(idx.cx, idx.cy, idx.cz);

            const cell_index: usize = @intCast(linear);
            assert(cell_index < self.cell_counts.len);

            const count_u32 = self.cell_counts[cell_index];
            // Precondition: per-cell count must not exceed the per-cell capacity.
            assert(count_u32 <= max_per_cell);
            const count: usize = @intCast(count_u32);
            const base: usize = cell_index * @as(usize, max_per_cell);

            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (!std.meta.eql(self.items[base + i], item)) continue;

                const last_index: usize = base + count - 1;
                self.items[base + i] = self.items[last_index];
                self.cell_counts[cell_index] = count_u32 - 1;
                return true;
            }

            return false;
        }

        // -----------------------------------------------------------------
        // Private helpers
        // -----------------------------------------------------------------

        fn insertCell(self: *Self, linear: u32, item: T) UniformGrid3DError!void {
            const cell_index: usize = @intCast(linear);
            assert(cell_index < self.cell_counts.len);

            const count = self.cell_counts[cell_index];
            if (count >= max_per_cell) return error.CellFull;

            const base: usize = cell_index * @as(usize, max_per_cell);
            self.items[base + @as(usize, count)] = item;
            self.cell_counts[cell_index] = count + 1;
            // Postcondition: cell count must have incremented by exactly one.
            assert(self.cell_counts[cell_index] == count + 1);
        }

        fn cellSlice(self: *const Self, linear: u32) []const T {
            const cell_index: usize = @intCast(linear);
            assert(cell_index < self.cell_counts.len);

            const count_u32 = self.cell_counts[cell_index];
            // Precondition: per-cell count must not exceed the per-cell capacity.
            assert(count_u32 <= max_per_cell);
            const count: usize = @intCast(count_u32);
            const base: usize = cell_index * @as(usize, max_per_cell);
            return self.items[base .. base + count];
        }

        const CellRange = struct {
            min_ix: u32,
            max_ix: u32,
            min_iy: u32,
            max_iy: u32,
            min_iz: u32,
            max_iz: u32,
        };

        fn cellRangeForAABB(self: *const Self, aabb: AABB3) ?CellRange {
            const min_idx = self.cfg.cellIndex(aabb.min_x, aabb.min_y, aabb.min_z) orelse return null;
            const max_idx = self.cfg.cellIndex(aabb.max_x, aabb.max_y, aabb.max_z) orelse return null;

            if (std.debug.runtime_safety) {
                assert(min_idx.cx <= max_idx.cx);
                assert(min_idx.cy <= max_idx.cy);
                assert(min_idx.cz <= max_idx.cz);
            }

            return .{
                .min_ix = min_idx.cx,
                .max_ix = max_idx.cx,
                .min_iy = min_idx.cy,
                .max_iy = max_idx.cy,
                .min_iz = min_idx.cz,
                .max_iz = max_idx.cz,
            };
        }

        fn cellsHaveSpace(self: *const Self, r: CellRange) bool {
            var iz: u32 = r.min_iz;
            while (iz <= r.max_iz) : (iz += 1) {
                var iy: u32 = r.min_iy;
                while (iy <= r.max_iy) : (iy += 1) {
                    var ix: u32 = r.min_ix;
                    while (ix <= r.max_ix) : (ix += 1) {
                        const linear = self.cfg.linearIndex(ix, iy, iz);
                        if (self.cell_counts[@intCast(linear)] >= max_per_cell) return false;
                    }
                }
            }
            return true;
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "UniformGrid3D insertPoint and queryPoint" {
    const Grid = UniformGrid3D(u32, 4);
    var grid = try Grid.init(testing.allocator, .{
        .min_x = 0,
        .min_y = 0,
        .min_z = 0,
        .max_x = 10,
        .max_y = 10,
        .max_z = 10,
        .cells_x = 2,
        .cells_y = 2,
        .cells_z = 2,
    });
    defer grid.deinit();

    try grid.insertPoint(1, 1, 1, 42);
    try grid.insertPoint(1, 1, 1, 99);

    const result = grid.queryPoint(1, 1, 1);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(u32, 42), result[0]);
    try testing.expectEqual(@as(u32, 99), result[1]);

    // Point in a different cell returns empty.
    const empty = grid.queryPoint(9, 9, 9);
    try testing.expectEqual(@as(usize, 0), empty.len);

    // Exact max boundary maps to the last cell.
    try grid.insertPoint(10, 10, 10, 77);
    const edge = grid.queryPoint(10, 10, 10);
    try testing.expectEqual(@as(usize, 1), edge.len);
    try testing.expectEqual(@as(u32, 77), edge[0]);

    // Remove and verify.
    try testing.expect(grid.remove(1, 1, 1, 42));
    const after_remove = grid.queryPoint(1, 1, 1);
    try testing.expectEqual(@as(usize, 1), after_remove.len);
    try testing.expectEqual(@as(u32, 99), after_remove[0]);

    // Remove non-existent returns false.
    try testing.expect(!grid.remove(1, 1, 1, 42));
}

test "UniformGrid3D insertAABB" {
    const Grid = UniformGrid3D(u32, 8);
    var grid = try Grid.init(testing.allocator, .{
        .min_x = 0,
        .min_y = 0,
        .min_z = 0,
        .max_x = 10,
        .max_y = 10,
        .max_z = 10,
        .cells_x = 2,
        .cells_y = 2,
        .cells_z = 2,
    });
    defer grid.deinit();

    // AABB spanning all 8 cells (2x2x2).
    try grid.insertAABB(AABB3.init(1, 1, 1, 9, 9, 9), 7);

    var out: [64]u32 = undefined;
    const count = grid.queryAABB(AABB3.init(0, 0, 0, 10, 10, 10), out[0..]);
    // 2x2x2 = 8 cells, value duplicated into each.
    try testing.expectEqual(@as(u32, 8), count);
    for (out[0..@intCast(count)]) |v| {
        try testing.expectEqual(@as(u32, 7), v);
    }

    // Query a sub-region covering only 1 cell.
    const sub_count = grid.queryAABB(AABB3.init(0, 0, 0, 4, 4, 4), out[0..]);
    try testing.expectEqual(@as(u32, 1), sub_count);
    try testing.expectEqual(@as(u32, 7), out[0]);
}

test "UniformGrid3D clear" {
    const Grid = UniformGrid3D(u32, 4);
    var grid = try Grid.init(testing.allocator, .{
        .min_x = 0,
        .min_y = 0,
        .min_z = 0,
        .max_x = 10,
        .max_y = 10,
        .max_z = 10,
        .cells_x = 2,
        .cells_y = 2,
        .cells_z = 2,
    });
    defer grid.deinit();

    try grid.insertPoint(1, 1, 1, 42);
    try grid.insertPoint(9, 9, 9, 99);

    // Verify items are present.
    try testing.expectEqual(@as(usize, 1), grid.queryPoint(1, 1, 1).len);
    try testing.expectEqual(@as(usize, 1), grid.queryPoint(9, 9, 9).len);

    grid.clear();

    // All cells should be empty after clear.
    try testing.expectEqual(@as(usize, 0), grid.queryPoint(1, 1, 1).len);
    try testing.expectEqual(@as(usize, 0), grid.queryPoint(9, 9, 9).len);

    // Grid is still usable after clear.
    try grid.insertPoint(5, 5, 5, 123);
    try testing.expectEqual(@as(usize, 1), grid.queryPoint(5, 5, 5).len);
}

test "UniformGrid3D capacity overflow" {
    const Grid = UniformGrid3D(u8, 2);
    var grid = try Grid.init(testing.allocator, .{
        .min_x = 0,
        .min_y = 0,
        .min_z = 0,
        .max_x = 10,
        .max_y = 10,
        .max_z = 10,
        .cells_x = 1,
        .cells_y = 1,
        .cells_z = 1,
    });
    defer grid.deinit();

    try grid.insertPoint(1, 1, 1, 1);
    try grid.insertPoint(2, 2, 2, 2);

    // Third insert into the same cell exceeds capacity.
    try testing.expectError(error.CellFull, grid.insertPoint(3, 3, 3, 3));

    // Existing items are still intact (no partial mutation).
    const result = grid.queryPoint(1, 1, 1);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(u8, 1), result[0]);
    try testing.expectEqual(@as(u8, 2), result[1]);

    // insertAABB also respects capacity: no partial insertion.
    try testing.expectError(error.CellFull, grid.insertAABB(AABB3.init(0, 0, 0, 10, 10, 10), 4));
    try testing.expectEqual(@as(usize, 2), grid.queryPoint(1, 1, 1).len);

    // OutOfBounds for points outside the grid.
    try testing.expectError(error.OutOfBounds, grid.insertPoint(-1, 0, 0, 5));
}
