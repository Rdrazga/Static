const std = @import("std");
const testing = std.testing;
const spatial = @import("static_spatial");

const AABB3 = spatial.AABB3;
const BVH = spatial.BVH(u32);
const Frustum = spatial.Frustum;

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

fn queryBoxFrustum() Frustum {
    return Frustum{
        .planes = .{
            .{ .normal_x = 1, .normal_y = 0, .normal_z = 0, .d = 1 },
            .{ .normal_x = -1, .normal_y = 0, .normal_z = 0, .d = 10 },
            .{ .normal_x = 0, .normal_y = 1, .normal_z = 0, .d = 1 },
            .{ .normal_x = 0, .normal_y = -1, .normal_z = 0, .d = 10 },
            .{ .normal_x = 0, .normal_y = 0, .normal_z = 1, .d = 1 },
            .{ .normal_x = 0, .normal_y = 0, .normal_z = -1, .d = 10 },
        },
    };
}

test "BVH queryFrustum reports total hits when output truncates" {
    const items = [_]BVH.Item{
        .{ .bounds = AABB3.init(0, 0, 0, 1, 1, 1), .value = 10 },
        .{ .bounds = AABB3.init(2, 0, 0, 3, 1, 1), .value = 20 },
        .{ .bounds = AABB3.init(4, 0, 0, 5, 1, 1), .value = 30 },
        .{ .bounds = AABB3.init(6, 0, 0, 7, 1, 1), .value = 40 },
        .{ .bounds = AABB3.init(20, 20, 20, 21, 21, 21), .value = 50 },
    };
    const expected_hits = [_]u32{ 10, 20, 30, 40 };
    const frustum = queryBoxFrustum();

    var bvh = try BVH.build(testing.allocator, &items, .{ .max_leaf_items = 2 });
    defer bvh.deinit(testing.allocator);

    var full_hits: [expected_hits.len]u32 = undefined;
    const full_count = bvh.queryFrustum(frustum, &full_hits);
    try testing.expectEqual(@as(u32, expected_hits.len), full_count);
    try expectSubset(full_hits[0..full_count], &expected_hits);

    var truncated_hits: [2]u32 = undefined;
    const truncated_count = bvh.queryFrustum(frustum, &truncated_hits);
    try testing.expect(truncated_count > truncated_hits.len);
    try testing.expectEqual(@as(u32, expected_hits.len), truncated_count);
    try expectSubset(truncated_hits[0..], full_hits[0..full_count]);
}
