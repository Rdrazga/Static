//! Verifies SmallVec inline-to-heap spill transitions and item integrity.
//! Drives a SmallVec past its inline capacity to trigger heap spill, then
//! confirms all elements survive the transition with correct values.
const std = @import("std");
const testing = std.testing;
const static_collections = @import("static_collections");

const memory = static_collections.memory;

const SmallVec = static_collections.small_vec.SmallVec(u8, 2);

fn expectItemsEqual(vec: *SmallVec, expected: []const u8) !void {
    const items = vec.items();
    try testing.expectEqual(expected.len, items.len);
    try testing.expectEqualSlices(u8, expected, items);
}

test "small vec stays ordered across inline and spill storage" {
    var vec = SmallVec.init(testing.allocator, .{ .budget = null });
    defer vec.deinit();

    try testing.expectEqual(@as(usize, 0), vec.len());
    try expectItemsEqual(&vec, &.{});

    try vec.append(10);
    try vec.append(20);
    try vec.append(30);

    try testing.expectEqual(@as(usize, 3), vec.len());
    try expectItemsEqual(&vec, &.{ 10, 20, 30 });
}

test "small vec spills immediately when inline capacity is zero" {
    const InlineZero = static_collections.small_vec.SmallVec(u8, 0);
    var vec = InlineZero.init(testing.allocator, .{ .budget = null });
    defer vec.deinit();

    try vec.append(7);
    try vec.append(8);

    try testing.expectEqual(@as(usize, 2), vec.len());
    try testing.expectEqualSlices(u8, &.{ 7, 8 }, vec.items());
}

test "small vec budgeted spill returns NoSpaceLeft after spill" {
    var budget = try memory.budget.Budget.init(3);
    var vec = SmallVec.init(testing.allocator, .{ .budget = &budget });
    defer vec.deinit();

    try vec.append(1);
    try vec.append(2);
    try vec.append(3);
    try testing.expectEqual(@as(usize, 3), vec.len());
    try expectItemsEqual(&vec, &.{ 1, 2, 3 });

    try testing.expectError(error.NoSpaceLeft, vec.append(4));
    try testing.expectEqual(@as(usize, 3), vec.len());
    try expectItemsEqual(&vec, &.{ 1, 2, 3 });
}

test "small vec spilled storage can drain back to empty and clone independently" {
    var vec = SmallVec.init(testing.allocator, .{ .budget = null });
    defer vec.deinit();

    try vec.append(10);
    try vec.append(20);
    try vec.append(30);

    var clone = try vec.clone();
    defer clone.deinit();

    try testing.expectEqual(@as(u8, 30), vec.pop().?);
    try testing.expectEqual(@as(u8, 20), vec.pop().?);
    try testing.expectEqual(@as(u8, 10), vec.pop().?);
    try testing.expect(vec.pop() == null);
    try testing.expectEqual(@as(usize, 0), vec.len());

    try testing.expectEqual(@as(usize, 3), clone.len());
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, clone.items());
}
