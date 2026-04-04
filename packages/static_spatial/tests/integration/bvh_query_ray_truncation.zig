const std = @import("std");
const spatial = @import("static_spatial");

const AABB3 = spatial.AABB3;
const BVH = spatial.BVH(u32);
const Ray3 = spatial.Ray3;

fn containsValue(values: []const u32, needle: u32) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn expectSubset(values: []const u32, expected: []const u32) !void {
    for (values) |value| {
        try std.testing.expect(containsValue(expected, value));
    }
}

test "BVH queryRay reports total hits when output truncates" {
    const items = [_]BVH.Item{
        .{ .bounds = AABB3.init(0, 0, 0, 1, 1, 1), .value = 10 },
        .{ .bounds = AABB3.init(2, 0, 0, 3, 1, 1), .value = 20 },
        .{ .bounds = AABB3.init(4, 0, 0, 5, 1, 1), .value = 30 },
        .{ .bounds = AABB3.init(6, 0, 0, 7, 1, 1), .value = 40 },
        .{ .bounds = AABB3.init(20, 20, 20, 21, 21, 21), .value = 50 },
    };
    const ray = Ray3.init(-1.0, 0.5, 0.5, 1.0, 0.0, 0.0);

    var bvh = try BVH.build(std.testing.allocator, &items, .{ .max_leaf_items = 2 });
    defer bvh.deinit(std.testing.allocator);

    var full_hits: [4]u32 = undefined;
    const full_count = bvh.queryRay(ray, &full_hits);
    try std.testing.expectEqual(@as(u32, 4), full_count);
    try expectSubset(full_hits[0..full_count], &.{ 10, 20, 30, 40 });

    var truncated_hits: [2]u32 = undefined;
    const truncated_count = bvh.queryRay(ray, &truncated_hits);
    try std.testing.expect(truncated_count > truncated_hits.len);
    try std.testing.expectEqual(@as(u32, 4), truncated_count);
    try expectSubset(truncated_hits[0..], full_hits[0..full_count]);
}
