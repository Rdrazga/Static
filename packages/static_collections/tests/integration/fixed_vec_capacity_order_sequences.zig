//! Verifies FixedVec capacity enforcement and element ordering through append/pop sequences.
//! Fills the fixed-capacity vector to its limit, confirms overflow rejection,
//! and validates correct element ordering on extraction.
const std = @import("std");
const testing = std.testing;
const static_collections = @import("static_collections");

const FixedVec = static_collections.fixed_vec.FixedVec(u8, 3);

fn expectItemsEqual(vec: *FixedVec, expected: []const u8) !void {
    const items_const = vec.itemsConst();
    try testing.expectEqual(expected.len, items_const.len);
    try testing.expectEqualSlices(u8, expected, items_const);

    const items = vec.items();
    try testing.expectEqual(expected.len, items.len);
    try testing.expectEqualSlices(u8, expected, items);
}

test "fixed vec capacity, append order, and clear reuse stay bounded" {
    var vec = FixedVec{};

    try testing.expectEqual(@as(usize, 3), vec.capacity());
    try testing.expectEqual(@as(usize, 0), vec.len());
    try expectItemsEqual(&vec, &.{});

    try vec.append(10);
    try vec.append(20);
    try vec.append(30);

    try testing.expectEqual(@as(usize, 3), vec.len());
    try expectItemsEqual(&vec, &.{ 10, 20, 30 });
    try testing.expectError(error.NoSpaceLeft, vec.append(40));
    try testing.expectEqual(@as(usize, 3), vec.len());
    try expectItemsEqual(&vec, &.{ 10, 20, 30 });

    vec.clear();
    try testing.expectEqual(@as(usize, 0), vec.len());
    try expectItemsEqual(&vec, &.{});

    try vec.append(7);
    try vec.append(8);
    try testing.expectEqual(@as(usize, 2), vec.len());
    try expectItemsEqual(&vec, &.{ 7, 8 });
}
