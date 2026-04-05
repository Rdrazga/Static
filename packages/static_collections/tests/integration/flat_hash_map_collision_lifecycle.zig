//! Verifies FlatHashMap collision handling, tombstone cleanup, and rehash under
//! forced hash collisions. Uses a custom hash context that maps all keys to the
//! same bucket, exercising the linear-probing and tombstone reclamation paths.
const std = @import("std");
const static_collections = @import("static_collections");

const CollidingCtx = struct {
    fn hash(_: u32, _: u64) u64 {
        return 0;
    }

    fn eql(a: u32, b: u32) bool {
        return a == b;
    }
};

const FlatHashMap = static_collections.flat_hash_map.FlatHashMap(u32, u32, CollidingCtx);

test "flat hash map collision cluster stays stable across removal and rehash" {
    var map = try FlatHashMap.init(std.testing.allocator, .{
        .initial_capacity = 8,
        .seed = 0xface_cafe,
    });
    defer map.deinit();

    try map.putNoClobber(1, 10);
    try map.putNoClobber(2, 20);
    try map.putNoClobber(3, 30);
    try std.testing.expectEqual(@as(usize, 3), map.len());
    try std.testing.expectEqual(@as(usize, 0), map.tombstones);

    try std.testing.expectEqual(@as(u32, 20), try map.remove(2));
    try std.testing.expect(map.getConst(2) == null);
    try std.testing.expectEqual(@as(usize, 1), map.tombstones);

    try map.putNoClobber(4, 40);
    try std.testing.expectEqual(@as(usize, 3), map.len());
    try std.testing.expectEqual(@as(u32, 40), map.getConst(4).?.*);
    try std.testing.expect(map.getConst(2) == null);

    try map.put(3, 300);
    try std.testing.expectEqual(@as(usize, 3), map.len());
    try std.testing.expectEqual(@as(u32, 300), map.getConst(3).?.*);
    try std.testing.expectError(error.AlreadyExists, map.putNoClobber(3, 33));

    const capacity_before_growth = map.capacity();
    var next_key: u32 = 5;
    while (map.capacity() == capacity_before_growth) : (next_key += 1) {
        // Safety: growth must occur well before this bound.
        std.debug.assert(next_key < 1000);
        try map.putNoClobber(next_key, next_key * 10);
    }
    const inserted_max = next_key - 1;

    try std.testing.expect(map.capacity() > capacity_before_growth);
    try std.testing.expectEqual(@as(usize, 0), map.tombstones);
    try std.testing.expectEqual(@as(u32, 10), map.getConst(1).?.*);
    try std.testing.expect(map.getConst(2) == null);
    try std.testing.expectEqual(@as(u32, 300), map.getConst(3).?.*);
    try std.testing.expectEqual(@as(u32, 40), map.getConst(4).?.*);

    var key: u32 = 5;
    while (key <= inserted_max) : (key += 1) {
        try std.testing.expectEqual(key * 10, map.getConst(key).?.*);
    }

    try std.testing.expectError(error.NotFound, map.remove(2));
}
