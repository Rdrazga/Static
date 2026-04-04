const std = @import("std");
const spatial = @import("static_spatial");

pub fn main() !void {
    const DynamicBVH = spatial.IncrementalBVH(u32);
    var bvh = DynamicBVH.init(std.heap.page_allocator);
    defer bvh.deinit();

    const first = try bvh.insert(spatial.AABB3.init(0, 0, 0, 1, 1, 1), 10);
    _ = try bvh.insert(spatial.AABB3.init(5, 5, 5, 6, 6, 6), 20);

    var truncated_out: [1]u32 = undefined;
    const truncated = bvh.queryAABB(
        spatial.AABB3.init(-1, -1, -1, 6, 6, 6),
        &truncated_out,
    );
    std.debug.assert(truncated == 2);
    std.debug.assert(truncated_out[0] == 10 or truncated_out[0] == 20);

    var out: [8]u32 = undefined;
    const before_move = bvh.queryAABB(
        spatial.AABB3.init(-1, -1, -1, 2, 2, 2),
        &out,
    );
    std.debug.assert(before_move == 1);
    std.debug.assert(out[0] == 10);

    bvh.refit(first, spatial.AABB3.init(50, 50, 50, 51, 51, 51));
    const after_move = bvh.queryAABB(
        spatial.AABB3.init(49, 49, 49, 52, 52, 52),
        &out,
    );
    std.debug.assert(after_move == 1);
    std.debug.assert(out[0] == 10);

    bvh.remove(first);
    const after_remove = bvh.queryAABB(
        spatial.AABB3.init(49, 49, 49, 52, 52, 52),
        &out,
    );
    std.debug.assert(after_remove == 0);
}
