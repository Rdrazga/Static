//! Uniform Spatial Grid (2D)
//!
//! A bounded 2D uniform grid for broad-phase spatial queries. Each cell holds
//! up to `max_per_cell` items; the capacity is fixed at comptime. Items that
//! span multiple cells are stored in each overlapping cell (duplicates possible).
//!
//! Thread safety: none. External synchronization required.
//!
//! Allocation profile:
//! - `init`: O(cells_x * cells_y * max_per_cell) allocation.
//! - All operations after init are allocation-free.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const primitives = @import("primitives.zig");
const AABB2 = primitives.AABB2;
const GridConfig = primitives.GridConfig;

pub const UniformGridError = error{ CellFull, OutOfBounds };

pub fn UniformGrid(comptime T: type, comptime max_per_cell: u32) type {
    comptime {
        if (max_per_cell == 0) @compileError("UniformGrid max_per_cell must be > 0");
        assert(@sizeOf(T) > 0);
    }
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,
        counts: []u32,
        config: GridConfig,

        pub fn init(
            allocator: std.mem.Allocator,
            config: GridConfig,
        ) !Self {
            assert(config.cells_x > 0);
            assert(config.cells_y > 0);
            const total = config.totalCells();
            const items = try allocator.alloc(
                T,
                total * max_per_cell,
            );
            errdefer allocator.free(items);
            const counts = try allocator.alloc(u32, total);
            @memset(counts, 0);
            return .{
                .allocator = allocator,
                .items = items,
                .counts = counts,
                .config = config,
            };
        }

        pub fn deinit(self: *Self) void {
            // Precondition: items slice must have the expected size.
            assert(self.items.len == self.config.totalCells() * max_per_cell);
            assert(self.counts.len == self.config.totalCells());
            self.allocator.free(self.items);
            self.allocator.free(self.counts);
            self.* = undefined;
        }

        pub fn insertPoint(
            self: *Self,
            x: f32,
            y: f32,
            item: T,
        ) UniformGridError!void {
            const cell = self.config.cellIndex(x, y) orelse
                return UniformGridError.OutOfBounds;
            const idx = self.config.linearIndex(
                cell.cx,
                cell.cy,
            );
            const count = self.counts[idx];
            // Precondition: cell index must be within bounds.
            assert(idx < self.counts.len);
            if (count >= max_per_cell)
                return UniformGridError.CellFull;
            self.items[idx * max_per_cell + count] = item;
            self.counts[idx] = count + 1;
            // Postcondition: cell count must have increased by one.
            assert(self.counts[idx] == count + 1);
        }

        pub fn insertAABB(
            self: *Self,
            aabb: AABB2,
            item: T,
        ) UniformGridError!void {
            const r = self.cellRangeForAABB(aabb);

            // Pre-check: verify all target cells have capacity before
            // mutating any, so the function is atomic on CellFull error.
            assert(r.max_cx < self.config.cells_x);
            assert(r.max_cy < self.config.cells_y);
            var check_cy = r.min_cy;
            while (check_cy <= r.max_cy) : (check_cy += 1) {
                var check_cx = r.min_cx;
                while (check_cx <= r.max_cx) : (check_cx += 1) {
                    const idx = self.config.linearIndex(check_cx, check_cy);
                    if (self.counts[idx] >= max_per_cell)
                        return UniformGridError.CellFull;
                }
            }

            var cy = r.min_cy;
            while (cy <= r.max_cy) : (cy += 1) {
                var cx = r.min_cx;
                while (cx <= r.max_cx) : (cx += 1) {
                    const idx = self.config.linearIndex(cx, cy);
                    const count = self.counts[idx];
                    // Capacity guaranteed by pre-check above.
                    assert(count < max_per_cell);
                    self.items[idx * max_per_cell + count] = item;
                    self.counts[idx] = count + 1;
                }
            }
        }

        pub fn queryPoint(
            self: *const Self,
            x: f32,
            y: f32,
        ) []const T {
            const cell = self.config.cellIndex(x, y) orelse
                return &.{};
            const idx = self.config.linearIndex(
                cell.cx,
                cell.cy,
            );
            // Precondition: cell index is within the allocated counts array.
            assert(idx < self.counts.len);
            const count = self.counts[idx];
            // Precondition: per-cell item count must not exceed the per-cell capacity.
            assert(count <= max_per_cell);
            const base = idx * max_per_cell;
            return self.items[base..base + count];
        }

        pub fn queryAABB(
            self: *const Self,
            aabb: AABB2,
            out: []T,
        ) u32 {
            var written: u32 = 0;
            const r = self.cellRangeForAABB(aabb);

            var cy = r.min_cy;
            while (cy <= r.max_cy) : (cy += 1) {
                var cx = r.min_cx;
                while (cx <= r.max_cx) : (cx += 1) {
                    const idx = self.config.linearIndex(
                        cx,
                        cy,
                    );
                    const count = self.counts[idx];
                    const base = idx * max_per_cell;
                    for (
                        self.items[base..base + count],
                    ) |item| {
                        if (written < out.len) {
                            out[written] = item;
                            written += 1;
                        }
                    }
                }
            }
            return written;
        }

        pub fn clear(self: *Self) void {
            // Precondition: counts slice must match the grid's total cell count.
            assert(self.counts.len == self.config.totalCells());
            @memset(self.counts, 0);
            // Postcondition: all cells are empty.
            assert(self.counts[0] == 0);
        }

        pub fn remove(
            self: *Self,
            x: f32,
            y: f32,
            item: T,
        ) bool {
            const cell = self.config.cellIndex(x, y) orelse
                return false;
            const idx = self.config.linearIndex(
                cell.cx,
                cell.cy,
            );
            // Precondition: cell index is within the allocated counts array.
            assert(idx < self.counts.len);
            const count = self.counts[idx];
            // Precondition: per-cell count must not exceed capacity.
            assert(count <= max_per_cell);
            const base = idx * max_per_cell;
            for (0..count) |i| {
                if (std.meta.eql(
                    self.items[base + i],
                    item,
                )) {
                    self.items[base + i] =
                        self.items[base + count - 1];
                    self.counts[idx] = @intCast(count - 1);
                    return true;
                }
            }
            return false;
        }

        // -----------------------------------------------------------------
        // Private helpers
        // -----------------------------------------------------------------

        const CellRange = struct {
            min_cx: u32,
            max_cx: u32,
            min_cy: u32,
            max_cy: u32,
        };

        /// Compute the inclusive cell-index range that an AABB overlaps.
        ///
        /// Clamps to grid bounds so callers can iterate without further checks.
        /// Called from both `insertAABB` and `queryAABB` to eliminate the
        /// duplicated range-computation code.
        fn cellRangeForAABB(self: *const Self, aabb: AABB2) CellRange {
            // Precondition: AABB must not be inverted.
            assert(aabb.min_x <= aabb.max_x);
            assert(aabb.min_y <= aabb.max_y);
            const cw = self.config.cellWidth();
            const ch = self.config.cellHeight();
            const min_cx: u32 = @intFromFloat(
                @max(0.0, @floor((aabb.min_x - self.config.min_x) / cw)),
            );
            const min_cy: u32 = @intFromFloat(
                @max(0.0, @floor((aabb.min_y - self.config.min_y) / ch)),
            );
            const max_cx: u32 = @intFromFloat(
                @min(
                    @as(f32, @floatFromInt(self.config.cells_x - 1)),
                    @floor((aabb.max_x - self.config.min_x) / cw),
                ),
            );
            const max_cy: u32 = @intFromFloat(
                @min(
                    @as(f32, @floatFromInt(self.config.cells_y - 1)),
                    @floor((aabb.max_y - self.config.min_y) / ch),
                ),
            );
            // Postcondition: outputs are within grid bounds.
            assert(max_cx < self.config.cells_x);
            assert(max_cy < self.config.cells_y);
            return .{
                .min_cx = min_cx,
                .max_cx = max_cx,
                .min_cy = min_cy,
                .max_cy = max_cy,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testConfig() GridConfig {
    return .{
        .min_x = 0.0,
        .min_y = 0.0,
        .max_x = 100.0,
        .max_y = 100.0,
        .cells_x = 10,
        .cells_y = 10,
    };
}

test "UniformGrid insertPoint and queryPoint" {
    const Grid = UniformGrid(u32, 4);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 42);
    try grid.insertPoint(5.0, 5.0, 99);

    const results = grid.queryPoint(5.0, 5.0);
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqual(@as(u32, 42), results[0]);
    try testing.expectEqual(@as(u32, 99), results[1]);

    const empty = grid.queryPoint(55.0, 55.0);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "UniformGrid insertAABB" {
    const Grid = UniformGrid(u32, 4);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    // AABB spanning cells (0,0) through (1,1) in a 10x10 grid
    // with cell size 10x10.
    const aabb = AABB2{
        .min_x = 0.0,
        .min_y = 0.0,
        .max_x = 15.0,
        .max_y = 15.0,
    };
    try grid.insertAABB(aabb, 7);

    // All four cells should contain item 7.
    const r00 = grid.queryPoint(5.0, 5.0);
    try testing.expectEqual(@as(usize, 1), r00.len);
    try testing.expectEqual(@as(u32, 7), r00[0]);

    const r10 = grid.queryPoint(15.0, 5.0);
    try testing.expectEqual(@as(usize, 1), r10.len);

    const r01 = grid.queryPoint(5.0, 15.0);
    try testing.expectEqual(@as(usize, 1), r01.len);

    const r11 = grid.queryPoint(15.0, 15.0);
    try testing.expectEqual(@as(usize, 1), r11.len);
}

test "UniformGrid queryAABB" {
    const Grid = UniformGrid(u32, 4);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 1);
    try grid.insertPoint(15.0, 5.0, 2);
    try grid.insertPoint(55.0, 55.0, 3);

    var buf: [16]u32 = undefined;
    const query = AABB2{
        .min_x = 0.0,
        .min_y = 0.0,
        .max_x = 20.0,
        .max_y = 20.0,
    };
    const n = grid.queryAABB(query, &buf);
    try testing.expectEqual(@as(u32, 2), n);
}

test "UniformGrid clear" {
    const Grid = UniformGrid(u32, 4);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 1);
    grid.clear();

    const results = grid.queryPoint(5.0, 5.0);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "UniformGrid remove" {
    const Grid = UniformGrid(u32, 4);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 10);
    try grid.insertPoint(5.0, 5.0, 20);
    try grid.insertPoint(5.0, 5.0, 30);

    const removed = grid.remove(5.0, 5.0, 20);
    try testing.expect(removed);

    const results = grid.queryPoint(5.0, 5.0);
    try testing.expectEqual(@as(usize, 2), results.len);

    // Item 20 should no longer be present.
    for (results) |v| {
        try testing.expect(v != 20);
    }

    // Removing a non-existent item returns false.
    const not_found = grid.remove(5.0, 5.0, 999);
    try testing.expect(!not_found);
}

test "UniformGrid capacity overflow" {
    const Grid = UniformGrid(u32, 2);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 1);
    try grid.insertPoint(5.0, 5.0, 2);

    const result = grid.insertPoint(5.0, 5.0, 3);
    try testing.expectError(
        UniformGridError.CellFull,
        result,
    );
}

test "UniformGrid out of bounds" {
    const Grid = UniformGrid(u32, 4);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    const result = grid.insertPoint(-1.0, -1.0, 1);
    try testing.expectError(
        UniformGridError.OutOfBounds,
        result,
    );

    const result2 = grid.insertPoint(200.0, 200.0, 2);
    try testing.expectError(
        UniformGridError.OutOfBounds,
        result2,
    );
}
