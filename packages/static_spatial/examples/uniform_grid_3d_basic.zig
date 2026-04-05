const std = @import("std");
const assert = std.debug.assert;
const spatial = @import("static_spatial");

pub fn main() !void {
    const Grid = spatial.UniformGrid3D(u32, 4);
    var grid = try Grid.init(std.heap.page_allocator, .{
        .min_x = 0.0,
        .min_y = 0.0,
        .min_z = 0.0,
        .max_x = 8.0,
        .max_y = 8.0,
        .max_z = 8.0,
        .cells_x = 2,
        .cells_y = 2,
        .cells_z = 2,
    });
    defer grid.deinit();

    try grid.insertPoint(1.0, 1.0, 1.0, 10);
    try grid.insertAABB(
        spatial.AABB3.init(0.5, 0.5, 0.5, 7.5, 7.5, 7.5),
        20,
    );

    const point_hits = grid.queryPoint(1.0, 1.0, 1.0);
    assert(point_hits.len == 2);

    var out: [16]u32 = undefined;
    const total = grid.queryAABB(
        spatial.AABB3.init(0.0, 0.0, 0.0, 8.0, 8.0, 8.0),
        out[0..],
    );
    assert(total == 9);

    const removed = grid.remove(1.0, 1.0, 1.0, 10);
    assert(removed);
    assert(grid.queryPoint(1.0, 1.0, 1.0).len == 1);
}
