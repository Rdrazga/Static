const std = @import("std");
const static_collections = @import("static_collections");

const DenseArray = static_collections.dense_array.DenseArray(u32);

fn expectItemAt(array: *DenseArray, index: usize, expected: u32) !void {
    try std.testing.expectEqual(expected, array.get(index).?.*);
    try std.testing.expectEqual(expected, array.getConst(index).?.*);
}

test "dense array append returns stable indices and exposes values through get APIs" {
    var array = try DenseArray.init(std.testing.allocator, .{});
    defer array.deinit();

    const first = try array.append(10);
    const second = try array.append(20);
    const third = try array.append(30);

    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 1), second);
    try std.testing.expectEqual(@as(usize, 2), third);
    try std.testing.expectEqual(@as(usize, 3), array.len());
    try expectItemAt(&array, 0, 10);
    try expectItemAt(&array, 1, 20);
    try expectItemAt(&array, 2, 30);
    try std.testing.expect(array.get(3) == null);
    try std.testing.expect(array.getConst(3) == null);
}

test "dense array swapRemove preserves density and rejects invalid indices" {
    var array = try DenseArray.init(std.testing.allocator, .{});
    defer array.deinit();

    _ = try array.append(10);
    _ = try array.append(20);
    _ = try array.append(30);
    _ = try array.append(40);

    const removed = try array.swapRemove(1);
    try std.testing.expectEqual(@as(u32, 20), removed);
    try std.testing.expectEqual(@as(usize, 3), array.len());
    try expectItemAt(&array, 0, 10);
    try expectItemAt(&array, 1, 40);
    try expectItemAt(&array, 2, 30);
    try std.testing.expect(array.get(3) == null);
    try std.testing.expect(array.getConst(3) == null);

    const last_removed = try array.swapRemove(2);
    try std.testing.expectEqual(@as(u32, 30), last_removed);
    try std.testing.expectEqual(@as(usize, 2), array.len());
    try expectItemAt(&array, 0, 10);
    try expectItemAt(&array, 1, 40);

    try std.testing.expectError(error.NotFound, array.swapRemove(2));
    try std.testing.expectError(error.NotFound, array.swapRemove(99));
}
