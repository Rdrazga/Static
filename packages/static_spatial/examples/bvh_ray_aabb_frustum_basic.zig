const std = @import("std");
const assert = std.debug.assert;
const spatial = @import("static_spatial");

pub fn main() !void {
    const IntBVH = spatial.BVH(u32);
    const items = [_]IntBVH.Item{
        .{ .bounds = spatial.AABB3.init(0, 0, 0, 1, 1, 1), .value = 10 },
        .{ .bounds = spatial.AABB3.init(2, 0, 0, 3, 1, 1), .value = 20 },
        .{ .bounds = spatial.AABB3.init(100, 100, 100, 101, 101, 101), .value = 30 },
    };

    var bvh = try IntBVH.build(std.heap.page_allocator, &items, .{
        .max_leaf_items = 1,
    });
    defer bvh.deinit(std.heap.page_allocator);

    var ray_hits: [8]u32 = undefined;
    const ray = spatial.Ray3.init(-1.0, 0.5, 0.5, 1.0, 0.0, 0.0);
    const ray_count = bvh.queryRay(ray, &ray_hits);
    assert(ray_count == 2);

    var aabb_hits: [8]u32 = undefined;
    const aabb_count = bvh.queryAABB(
        spatial.AABB3.init(-0.5, -0.5, -0.5, 3.5, 1.5, 1.5),
        &aabb_hits,
    );
    assert(aabb_count == 2);

    const frustum = spatial.Frustum{
        .planes = .{
            .{ .normal_x = 1, .normal_y = 0, .normal_z = 0, .d = 1 },
            .{ .normal_x = -1, .normal_y = 0, .normal_z = 0, .d = 10 },
            .{ .normal_x = 0, .normal_y = 1, .normal_z = 0, .d = 1 },
            .{ .normal_x = 0, .normal_y = -1, .normal_z = 0, .d = 10 },
            .{ .normal_x = 0, .normal_y = 0, .normal_z = 1, .d = 1 },
            .{ .normal_x = 0, .normal_y = 0, .normal_z = -1, .d = 10 },
        },
    };
    var frustum_hits: [8]u32 = undefined;
    const frustum_count = bvh.queryFrustum(frustum, &frustum_hits);
    assert(frustum_count >= 2);
}
