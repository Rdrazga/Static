const std = @import("std");
const static_collections = @import("static_collections");

const SparseSet = static_collections.sparse_set.SparseSet;

fn expectItems(set: *const SparseSet, expected: []const u32) !void {
    const items = set.items();
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, items) |expected_item, item| {
        try std.testing.expectEqual(expected_item, item);
    }
}

test "sparse set rejects invalid universe sizes" {
    try std.testing.expectError(
        error.InvalidInput,
        SparseSet.init(std.testing.allocator, .{ .universe_size = 0 }),
    );
}

test "sparse set insert, contains, items, and remove keep dense membership stable" {
    var set = try SparseSet.init(std.testing.allocator, .{ .universe_size = 16 });
    defer set.deinit();

    try set.insert(3);
    try set.insert(7);
    try set.insert(11);
    try set.insert(7);

    try std.testing.expectEqual(@as(usize, 3), set.len());
    try std.testing.expect(set.contains(3));
    try std.testing.expect(set.contains(7));
    try std.testing.expect(set.contains(11));
    try expectItems(&set, &.{ 3, 7, 11 });

    try std.testing.expectError(error.InvalidInput, set.insert(16));
    try std.testing.expectError(error.InvalidInput, set.insert(99));

    try set.remove(7);
    try std.testing.expectEqual(@as(usize, 2), set.len());
    try std.testing.expect(!set.contains(7));
    try std.testing.expect(set.contains(3));
    try std.testing.expect(set.contains(11));
    try expectItems(&set, &.{ 3, 11 });

    try std.testing.expectError(error.InvalidInput, set.remove(7));
    try std.testing.expectError(error.InvalidInput, set.remove(15));
}
