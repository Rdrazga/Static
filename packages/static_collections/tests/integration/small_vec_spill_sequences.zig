const std = @import("std");
const static_collections = @import("static_collections");

const memory = static_collections.memory;

const SmallVec = static_collections.small_vec.SmallVec(u8, 2);

fn expectItemsEqual(vec: *SmallVec, expected: []const u8) !void {
    const items = vec.items();
    try std.testing.expectEqual(expected.len, items.len);
    try std.testing.expectEqualSlices(u8, expected, items);
}

test "small vec stays ordered across inline and spill storage" {
    var vec = SmallVec.init(std.testing.allocator, .{});
    defer vec.deinit();

    try std.testing.expectEqual(@as(usize, 0), vec.len());
    try expectItemsEqual(&vec, &.{});

    try vec.append(10);
    try vec.append(20);
    try vec.append(30);

    try std.testing.expectEqual(@as(usize, 3), vec.len());
    try expectItemsEqual(&vec, &.{ 10, 20, 30 });
}

test "small vec spills immediately when inline capacity is zero" {
    const InlineZero = static_collections.small_vec.SmallVec(u8, 0);
    var vec = InlineZero.init(std.testing.allocator, .{});
    defer vec.deinit();

    try vec.append(7);
    try vec.append(8);

    try std.testing.expectEqual(@as(usize, 2), vec.len());
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, vec.items());
}

test "small vec budgeted spill returns NoSpaceLeft after spill" {
    var budget = try memory.budget.Budget.init(3);
    var vec = SmallVec.init(std.testing.allocator, .{ .budget = &budget });
    defer vec.deinit();

    try vec.append(1);
    try vec.append(2);
    try vec.append(3);
    try std.testing.expectEqual(@as(usize, 3), vec.len());
    try expectItemsEqual(&vec, &.{ 1, 2, 3 });

    try std.testing.expectError(error.NoSpaceLeft, vec.append(4));
    try std.testing.expectEqual(@as(usize, 3), vec.len());
    try expectItemsEqual(&vec, &.{ 1, 2, 3 });
}
