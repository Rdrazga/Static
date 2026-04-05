//! Verifies SparseSet membership operations and universe-boundary enforcement.
//! Tests add/remove/contains cycles across the full universe range and confirms
//! that out-of-universe indices are rejected.
const std = @import("std");
const testing = std.testing;
const static_collections = @import("static_collections");

const SparseSet = static_collections.sparse_set.SparseSet;

fn expectItems(set: *const SparseSet, expected: []const u32) !void {
    const items = set.items();
    try testing.expectEqual(expected.len, items.len);
    for (expected, items) |expected_item, item| {
        try testing.expectEqual(expected_item, item);
    }
}

test "sparse set rejects invalid universe sizes" {
    try testing.expectError(
        error.InvalidConfig,
        SparseSet.init(testing.allocator, .{ .universe_size = 0, .budget = null }),
    );
}

test "sparse set insert, contains, items, and remove keep dense membership stable" {
    var set = try SparseSet.init(testing.allocator, .{ .universe_size = 16, .budget = null });
    defer set.deinit();

    try set.insert(3);
    try set.insert(7);
    try set.insert(11);
    try set.insert(7);

    try testing.expectEqual(@as(usize, 3), set.len());
    try testing.expect(set.contains(3));
    try testing.expect(set.contains(7));
    try testing.expect(set.contains(11));
    try expectItems(&set, &.{ 3, 7, 11 });

    try testing.expectError(error.InvalidInput, set.insert(16));
    try testing.expectError(error.InvalidInput, set.insert(99));

    try set.remove(7);
    try testing.expectEqual(@as(usize, 2), set.len());
    try testing.expect(!set.contains(7));
    try testing.expect(set.contains(3));
    try testing.expect(set.contains(11));
    try expectItems(&set, &.{ 3, 11 });

    try testing.expectError(error.InvalidInput, set.remove(7));
    try testing.expectError(error.InvalidInput, set.remove(15));
}
