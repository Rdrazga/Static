//! Verifies SortedVecMap maintains strict key ordering through put/remove sequences.
//! Inserts keys in arbitrary order, removes selected entries, and confirms the
//! remaining keys are always in sorted order.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_collections = @import("static_collections");

const SortedVecMap = static_collections.sorted_vec_map.SortedVecMap(u32, u32, struct {});

fn expectEntry(map: *const SortedVecMap, index: usize, expected_key: u32, expected_value: u32) !void {
    try testing.expectEqual(expected_key, map.entries.items[index].key);
    try testing.expectEqual(expected_value, map.entries.items[index].value);
}

test "sorted vec map keeps sorted order and overwrites existing keys" {
    var map = try SortedVecMap.init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(10, 100);
    try map.put(3, 30);
    try map.put(7, 70);

    assert(map.len() == 3);
    try testing.expectEqual(@as(usize, 3), map.len());
    try expectEntry(&map, 0, 3, 30);
    try expectEntry(&map, 1, 7, 70);
    try expectEntry(&map, 2, 10, 100);

    const before_len = map.len();
    try map.put(7, 77);
    try testing.expectEqual(before_len, map.len());
    try testing.expectEqual(@as(u32, 77), map.get(7).?.*);
    try testing.expectEqual(@as(u32, 77), map.getConst(7).?.*);
    try expectEntry(&map, 0, 3, 30);
    try expectEntry(&map, 1, 7, 77);
    try expectEntry(&map, 2, 10, 100);
}

test "sorted vec map remove preserves order and reports missing keys" {
    var map = try SortedVecMap.init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(2, 20);
    try map.put(4, 40);
    try map.put(6, 60);
    try map.put(8, 80);

    const removed = try map.remove(4);
    try testing.expectEqual(@as(u32, 40), removed);
    try testing.expectEqual(@as(usize, 3), map.len());
    try testing.expect(map.get(4) == null);
    try testing.expect(map.getConst(4) == null);
    try expectEntry(&map, 0, 2, 20);
    try expectEntry(&map, 1, 6, 60);
    try expectEntry(&map, 2, 8, 80);

    try testing.expectError(error.NotFound, map.remove(99));
}
