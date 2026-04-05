const std = @import("std");
const assert = std.debug.assert;
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

fn expectSubset(values: []const u32, expected: []const u32) !void {
    for (values) |value| {
        try testing.expect(containsValue(expected, value));
    }
}

test "BVH queryAABB reports total hits when output truncates" {
    const items = [_]BVH.Item{
        .{ .bounds = AABB3.init(0, 0, 0, 1, 1, 1), .value = 10 },
        .{ .bounds = AABB3.init(1, 0, 0, 2, 1, 1), .value = 20 },
        .{ .bounds = AABB3.init(2, 0, 0, 3, 1, 1), .value = 30 },
        .{ .bounds = AABB3.init(3, 0, 0, 4, 1, 1), .value = 40 },
    };

    var bvh = try BVH.build(testing.allocator, &items, .{ .max_leaf_items = 2 });
    defer bvh.deinit(testing.allocator);

    var truncated_hits: [2]u32 = undefined;
    const query = AABB3.init(-0.5, -0.5, -0.5, 4.0, 1.5, 1.5);
    const total_hits = bvh.queryAABB(query, &truncated_hits);

    assert(total_hits > truncated_hits.len);
    try testing.expectEqual(@as(u32, 4), total_hits);
    try expectSubset(truncated_hits[0..], &.{ 10, 20, 30, 40 });

    var full_hits: [4]u32 = undefined;
    const full_count = bvh.queryAABB(query, &full_hits);
    try testing.expectEqual(@as(u32, 4), full_count);
    try expectSubset(full_hits[0..full_count], &.{ 10, 20, 30, 40 });
}
