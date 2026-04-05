const std = @import("std");
const testing = std.testing;
const spatial = @import("static_spatial");

const AABB3 = spatial.AABB3;
const BVH = spatial.BVH(u32);

fn containsValue(values: []const u32, needle: u32) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn expectQueryValues(values: []const u32, expected: []const u32) !void {
    try testing.expectEqual(expected.len, values.len);
    for (expected) |needle| {
        try testing.expect(containsValue(values, needle));
    }
    for (values) |value| {
        try testing.expect(containsValue(expected, value));
    }
}

test "BVH includes face, edge, and corner touching AABB intersections" {
    const items = [_]BVH.Item{
        .{ .bounds = AABB3.init(0, 0, 0, 1, 1, 1), .value = 10 },
        .{ .bounds = AABB3.init(1, 0, 0, 2, 1, 1), .value = 20 },
        .{ .bounds = AABB3.init(1, 1, 0, 2, 2, 1), .value = 30 },
        .{ .bounds = AABB3.init(1, 1, 1, 2, 2, 2), .value = 40 },
        .{ .bounds = AABB3.init(4, 4, 4, 5, 5, 5), .value = 50 },
    };

    var bvh = try BVH.build(testing.allocator, &items, .{ .max_leaf_items = 2 });
    defer bvh.deinit(testing.allocator);

    var hits: [8]u32 = undefined;
    const touching_count = bvh.queryAABB(AABB3.init(0, 0, 0, 1, 1, 1), &hits);
    try testing.expectEqual(@as(u32, 4), touching_count);
    try expectQueryValues(hits[0..touching_count], &.{ 10, 20, 30, 40 });

    const miss_count = bvh.queryAABB(AABB3.init(2.1, 2.1, 2.1, 3.0, 3.0, 3.0), &hits);
    try testing.expectEqual(@as(u32, 0), miss_count);
}
