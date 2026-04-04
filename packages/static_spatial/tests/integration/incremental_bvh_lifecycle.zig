const std = @import("std");
const spatial = @import("static_spatial");

const AABB3 = spatial.AABB3;
const Ray3 = spatial.Ray3;

fn containsValue(values: []const u32, needle: u32) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn expectQueryValues(
    values: []const u32,
    expected: []const u32,
) !void {
    try std.testing.expectEqual(expected.len, values.len);
    for (expected) |needle| {
        try std.testing.expect(containsValue(values, needle));
    }
    for (values) |value| {
        try std.testing.expect(containsValue(expected, value));
    }
}

test "IncrementalBVH reports total hit counts when output buffers truncate" {
    const BVH = spatial.IncrementalBVH(u32);
    var bvh = BVH.init(std.testing.allocator);
    defer bvh.deinit();

    _ = try bvh.insert(AABB3.init(0, 0, 0, 1, 1, 1), 10);
    _ = try bvh.insert(AABB3.init(5, 0, 0, 6, 1, 1), 20);
    _ = try bvh.insert(AABB3.init(10, 0, 0, 11, 1, 1), 30);

    const expected = [_]u32{ 10, 20, 30 };

    var aabb_hits: [2]u32 = undefined;
    const aabb_count = bvh.queryAABB(AABB3.init(-1, -1, -1, 12, 12, 12), &aabb_hits);
    try std.testing.expectEqual(@as(u32, 3), aabb_count);
    try std.testing.expect(aabb_count > aabb_hits.len);
    for (aabb_hits) |value| {
        try std.testing.expect(containsValue(expected[0..], value));
    }

    var ray_hits: [1]u32 = undefined;
    const ray = Ray3.init(-5.0, 0.5, 0.5, 1.0, 0.0, 0.0);
    const ray_count = bvh.queryRay(ray, &ray_hits);
    try std.testing.expectEqual(@as(u32, 3), ray_count);
    try std.testing.expect(ray_count > ray_hits.len);
    try std.testing.expect(containsValue(expected[0..], ray_hits[0]));
}

test "IncrementalBVH lifecycle keeps inserts, refits, and removals aligned with queries" {
    const BVH = spatial.IncrementalBVH(u32);
    var bvh = BVH.init(std.testing.allocator);
    defer bvh.deinit();

    const first = try bvh.insert(AABB3.init(0, 0, 0, 1, 1, 1), 10);
    const second = try bvh.insert(AABB3.init(5, 5, 5, 6, 6, 6), 20);
    const third = try bvh.insert(AABB3.init(10, 10, 10, 11, 11, 11), 30);

    try std.testing.expectEqual(@as(u32, 3), bvh.count());

    var buf: [8]u32 = undefined;
    const all_hit_count = bvh.queryAABB(AABB3.init(-1, -1, -1, 12, 12, 12), &buf);
    try expectQueryValues(buf[0..all_hit_count], &.{ 10, 20, 30 });

    var ray_hits: [8]u32 = undefined;
    const ray = Ray3.init(-5.0, 0.5, 0.5, 1.0, 0.0, 0.0);
    const ray_hit_count = bvh.queryRay(ray, &ray_hits);
    try std.testing.expect(containsValue(ray_hits[0..ray_hit_count], 10));

    bvh.refit(first, AABB3.init(50, 50, 50, 51, 51, 51));
    const old_hit_count = bvh.queryAABB(AABB3.init(-1, -1, -1, 2, 2, 2), &buf);
    try std.testing.expect(!containsValue(buf[0..old_hit_count], 10));
    const new_hit_count = bvh.queryAABB(AABB3.init(49, 49, 49, 52, 52, 52), &buf);
    try expectQueryValues(buf[0..new_hit_count], &.{ 10 });

    const moved_ray_hits = bvh.queryRay(ray, &ray_hits);
    try std.testing.expect(!containsValue(ray_hits[0..moved_ray_hits], 10));

    bvh.remove(second);
    try std.testing.expectEqual(@as(u32, 2), bvh.count());
    const after_remove_count = bvh.queryAABB(AABB3.init(4, 4, 4, 7, 7, 7), &buf);
    try std.testing.expect(!containsValue(buf[0..after_remove_count], 20));

    bvh.remove(first);
    bvh.remove(third);
    try std.testing.expectEqual(@as(u32, 0), bvh.count());
    try std.testing.expectEqual(@as(u32, 0), bvh.queryAABB(AABB3.init(-100, -100, -100, 100, 100, 100), &buf));
    try std.testing.expectEqual(@as(u32, 0), bvh.queryRay(ray, &ray_hits));
}

test "IncrementalBVH can empty out and accept new inserts after removals" {
    const BVH = spatial.IncrementalBVH(u32);
    var bvh = BVH.init(std.testing.allocator);
    defer bvh.deinit();

    const handle = try bvh.insert(AABB3.init(1, 1, 1, 2, 2, 2), 77);
    try std.testing.expectEqual(@as(u32, 1), bvh.count());

    var buf: [4]u32 = undefined;
    const first_hit_count = bvh.queryAABB(AABB3.init(0, 0, 0, 3, 3, 3), &buf);
    try expectQueryValues(buf[0..first_hit_count], &.{ 77 });

    bvh.remove(handle);
    try std.testing.expectEqual(@as(u32, 0), bvh.count());
    try std.testing.expectEqual(@as(u32, 0), bvh.queryAABB(AABB3.init(0, 0, 0, 3, 3, 3), &buf));

    const reinsertion = try bvh.insert(AABB3.init(8, 8, 8, 9, 9, 9), 88);
    try std.testing.expect(reinsertion != BVH.INVALID);
    try std.testing.expectEqual(@as(u32, 1), bvh.count());
    const reinsertion_hit_count = bvh.queryAABB(AABB3.init(7, 7, 7, 10, 10, 10), &buf);
    try expectQueryValues(buf[0..reinsertion_hit_count], &.{ 88 });
}
