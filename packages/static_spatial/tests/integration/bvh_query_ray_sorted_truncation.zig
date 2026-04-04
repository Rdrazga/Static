const std = @import("std");
const spatial = @import("static_spatial");

const AABB3 = spatial.AABB3;
const BVH = spatial.BVH(u32);
const Ray3 = spatial.Ray3;

fn containsHit(hits: []const BVH.RayHit, needle: BVH.RayHit) bool {
    for (hits) |hit| {
        if (hit.value == needle.value and hit.t == needle.t) return true;
    }
    return false;
}

fn expectAscending(hits: []const BVH.RayHit) !void {
    if (hits.len <= 1) return;
    for (hits[1..], 1..) |hit, index| {
        try std.testing.expect(hits[index - 1].t <= hit.t);
    }
}

test "BVH queryRaySorted reports total hits when output truncates" {
    const items = [_]BVH.Item{
        .{ .bounds = AABB3.init(4, 0, 0, 5, 1, 1), .value = 30 },
        .{ .bounds = AABB3.init(0, 0, 0, 1, 1, 1), .value = 10 },
        .{ .bounds = AABB3.init(6, 0, 0, 7, 1, 1), .value = 40 },
        .{ .bounds = AABB3.init(2, 0, 0, 3, 1, 1), .value = 20 },
    };

    var bvh = try BVH.build(std.testing.allocator, &items, .{ .max_leaf_items = 1 });
    defer bvh.deinit(std.testing.allocator);

    const ray = Ray3.init(-1.0, 0.5, 0.5, 1.0, 0.0, 0.0);

    var full_hits: [4]BVH.RayHit = undefined;
    const full_count = bvh.queryRaySorted(ray, &full_hits);
    try std.testing.expectEqual(@as(u32, 4), full_count);
    try expectAscending(full_hits[0..full_count]);

    var truncated_hits: [2]BVH.RayHit = undefined;
    const truncated_count = bvh.queryRaySorted(ray, &truncated_hits);
    try std.testing.expect(truncated_count > truncated_hits.len);
    try std.testing.expectEqual(@as(u32, 4), truncated_count);
    try expectAscending(truncated_hits[0..]);

    for (truncated_hits[0..]) |hit| {
        try std.testing.expect(containsHit(full_hits[0..full_count], hit));
    }
}
