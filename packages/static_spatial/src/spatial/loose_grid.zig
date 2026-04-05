//! Loose Spatial Grid (2D)
//!
//! A 2D spatial grid where each cell tracks a "loose" bounding box that
//! expands to enclose all items stored in that cell. Queries test the loose
//! bounds first (fast rejection) then test each individual item bound.
//!
//! Items are assigned to cells by their AABB center; queries expand the search
//! range by one cell in each direction to account for items whose loose bounds
//! spill into neighboring cells.
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

pub const LooseGridError = error{ CellFull, OutOfBounds };

pub fn LooseGrid(comptime T: type, comptime max_per_cell: u32) type {
    comptime {
        if (max_per_cell == 0) @compileError("LooseGrid max_per_cell must be > 0");
        assert(@sizeOf(T) > 0);
    }
    return struct {
        const Self = @This();

        const Entry = struct {
            bounds: AABB2,
            value: T,
        };

        /// Sentinel AABB representing an empty (invalid) loose bounds.
        /// min > max so that the first `merge` produces the inserted bounds.
        /// Uses AABB2.empty (floatMax-based) for consistency with bvh.zig and
        /// to avoid IEEE inf edge cases in arithmetic.
        const empty_bounds = AABB2.empty;

        allocator: std.mem.Allocator,
        items: []Entry,
        counts: []u32,
        loose_bounds: []AABB2,
        config: GridConfig,

        pub fn init(
            allocator: std.mem.Allocator,
            config: GridConfig,
        ) !Self {
            assert(config.cells_x > 0);
            assert(config.cells_y > 0);
            const total = config.totalCells();
            const items = try allocator.alloc(
                Entry,
                total * max_per_cell,
            );
            errdefer allocator.free(items);
            const counts = try allocator.alloc(u32, total);
            errdefer allocator.free(counts);
            const loose = try allocator.alloc(AABB2, total);
            @memset(counts, 0);
            @memset(loose, empty_bounds);
            return .{
                .allocator = allocator,
                .items = items,
                .counts = counts,
                .loose_bounds = loose,
                .config = config,
            };
        }

        pub fn deinit(self: *Self) void {
            // Precondition: all slices must be consistent with the grid config.
            assert(self.counts.len == self.config.totalCells());
            assert(self.loose_bounds.len == self.config.totalCells());
            self.allocator.free(self.items);
            self.allocator.free(self.counts);
            self.allocator.free(self.loose_bounds);
            self.* = undefined;
        }

        pub fn insertAABB(
            self: *Self,
            aabb: AABB2,
            item: T,
        ) LooseGridError!void {
            // Precondition: AABB must not be inverted (AABB2.init asserts this,
            // but we pair-assert here for insertions that bypass init).
            assert(aabb.min_x <= aabb.max_x);
            assert(aabb.min_y <= aabb.max_y);
            const c = aabb.center();
            const cell = self.config.cellIndex(c.x, c.y) orelse
                return LooseGridError.OutOfBounds;
            const idx = self.config.linearIndex(
                cell.cx,
                cell.cy,
            );
            const count = self.counts[idx];
            if (count >= max_per_cell)
                return LooseGridError.CellFull;
            self.items[idx * max_per_cell + count] = .{
                .bounds = aabb,
                .value = item,
            };
            self.counts[idx] = count + 1;
            // Postcondition: the cell count must have incremented.
            assert(self.counts[idx] == count + 1);
            self.loose_bounds[idx] = AABB2.merge(
                self.loose_bounds[idx],
                aabb,
            );
        }

        pub fn insertPoint(
            self: *Self,
            x: f32,
            y: f32,
            item: T,
        ) LooseGridError!void {
            const aabb = AABB2{
                .min_x = x,
                .min_y = y,
                .max_x = x,
                .max_y = y,
            };
            return self.insertAABB(aabb, item);
        }

        pub fn queryPoint(
            self: *const Self,
            x: f32,
            y: f32,
            out: []T,
        ) u32 {
            const cell = self.config.cellIndex(x, y) orelse
                return 0;
            const idx = self.config.linearIndex(
                cell.cx,
                cell.cy,
            );
            // Precondition: cell index must be within the counts array.
            assert(idx < self.counts.len);
            var written: u32 = 0;
            const count = self.counts[idx];
            // Precondition: per-cell count must not exceed the per-cell capacity.
            assert(count <= max_per_cell);
            const base = idx * max_per_cell;
            for (self.items[base..base + count]) |entry| {
                if (entry.bounds.contains(x, y)) {
                    if (written < out.len) {
                        out[written] = entry.value;
                        written += 1;
                    }
                }
            }
            return written;
        }

        pub fn queryAABB(
            self: *const Self,
            aabb: AABB2,
            out: []T,
        ) u32 {
            var written: u32 = 0;
            const cw = self.config.cellWidth();
            const ch = self.config.cellHeight();

            // Expand search range by one cell in each direction to
            // account for items whose loose bounds spill into
            // neighboring cells.
            const raw_min_cx = @floor(
                (aabb.min_x - self.config.min_x) / cw,
            );
            const raw_min_cy = @floor(
                (aabb.min_y - self.config.min_y) / ch,
            );
            const raw_max_cx = @floor(
                (aabb.max_x - self.config.min_x) / cw,
            );
            const raw_max_cy = @floor(
                (aabb.max_y - self.config.min_y) / ch,
            );

            const min_cx: u32 = @intFromFloat(@max(
                0.0,
                raw_min_cx - 1.0,
            ));
            const min_cy: u32 = @intFromFloat(@max(
                0.0,
                raw_min_cy - 1.0,
            ));
            const max_cx: u32 = @intFromFloat(@min(
                @as(
                    f32,
                    @floatFromInt(self.config.cells_x - 1),
                ),
                raw_max_cx + 1.0,
            ));
            const max_cy: u32 = @intFromFloat(@min(
                @as(
                    f32,
                    @floatFromInt(self.config.cells_y - 1),
                ),
                raw_max_cy + 1.0,
            ));

            var cy = min_cy;
            while (cy <= max_cy) : (cy += 1) {
                var cx = min_cx;
                while (cx <= max_cx) : (cx += 1) {
                    const idx = self.config.linearIndex(cx, cy);

                    // Skip cell entirely when its loose bounds
                    // do not intersect the query.
                    const count = self.counts[idx];
                    if (count == 0) continue;
                    if (!self.loose_bounds[idx].intersects(aabb))
                        continue;

                    const base = idx * max_per_cell;
                    for (
                        self.items[base..base + count],
                    ) |entry| {
                        if (entry.bounds.intersects(aabb)) {
                            if (written < out.len) {
                                out[written] = entry.value;
                                written += 1;
                            }
                        }
                    }
                }
            }
            return written;
        }

        pub fn clear(self: *Self) void {
            // Precondition: counts and loose_bounds must match the grid cell count.
            assert(self.counts.len == self.config.totalCells());
            assert(self.loose_bounds.len == self.config.totalCells());
            @memset(self.counts, 0);
            @memset(self.loose_bounds, empty_bounds);
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

test "LooseGrid insertAABB and queryPoint" {
    const Grid = LooseGrid(u32, 4);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    // Insert an AABB whose center is at (10,10) -> cell (1,1),
    // but whose bounds extend into cell (0,0).
    const aabb = AABB2.init(2.0, 2.0, 18.0, 18.0);
    try grid.insertAABB(aabb, 42);

    // Query a point inside the AABB.
    var buf: [8]u32 = undefined;
    const n1 = grid.queryPoint(10.0, 10.0, &buf);
    try testing.expectEqual(@as(u32, 1), n1);
    try testing.expectEqual(@as(u32, 42), buf[0]);

    // Query a point outside the AABB but inside the same cell.
    const n2 = grid.queryPoint(19.0, 19.0, &buf);
    try testing.expectEqual(@as(u32, 0), n2);

    // Query via AABB that overlaps the inserted bounds.
    const query = AABB2.init(0.0, 0.0, 5.0, 5.0);
    const n3 = grid.queryAABB(query, &buf);
    try testing.expectEqual(@as(u32, 1), n3);
    try testing.expectEqual(@as(u32, 42), buf[0]);
}

test "LooseGrid clear" {
    const Grid = LooseGrid(u32, 4);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 1);
    grid.clear();

    var buf: [8]u32 = undefined;
    const n = grid.queryPoint(5.0, 5.0, &buf);
    try testing.expectEqual(@as(u32, 0), n);
}

test "LooseGrid capacity overflow" {
    const Grid = LooseGrid(u32, 2);
    var grid = try Grid.init(
        testing.allocator,
        testConfig(),
    );
    defer grid.deinit();

    try grid.insertPoint(5.0, 5.0, 1);
    try grid.insertPoint(5.0, 5.0, 2);

    const result = grid.insertPoint(5.0, 5.0, 3);
    try testing.expectError(
        LooseGridError.CellFull,
        result,
    );
}
