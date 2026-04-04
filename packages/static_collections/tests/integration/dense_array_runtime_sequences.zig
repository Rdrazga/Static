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

test "dense array itemsConst reflects dense contents after churn" {
    // Goal: prove itemsConst tracks append and swapRemove faithfully.
    // Method: append, remove middle, then verify const slice matches survivors.
    var array = try DenseArray.init(std.testing.allocator, .{});
    defer array.deinit();

    _ = try array.append(1);
    _ = try array.append(2);
    _ = try array.append(3);

    const before = array.itemsConst();
    try std.testing.expectEqual(@as(usize, 3), before.len);
    try std.testing.expectEqual(@as(u32, 1), before[0]);
    try std.testing.expectEqual(@as(u32, 2), before[1]);
    try std.testing.expectEqual(@as(u32, 3), before[2]);

    _ = try array.swapRemove(0);
    const after = array.itemsConst();
    try std.testing.expectEqual(@as(usize, 2), after.len);
    // Element 3 moved into slot 0, element 2 stays at slot 1.
    try std.testing.expectEqual(@as(u32, 3), after[0]);
    try std.testing.expectEqual(@as(u32, 2), after[1]);
}

test "dense array capacity and clear lifecycle" {
    // Goal: prove capacity survives clear and supports reuse without reallocation.
    // Method: append to grow, record capacity, clear, assert capacity unchanged,
    // then re-append within the same capacity.
    var array = try DenseArray.init(std.testing.allocator, .{ .initial_capacity = 4 });
    defer array.deinit();

    try std.testing.expect(array.capacity() >= 4);
    try std.testing.expectEqual(@as(usize, 0), array.len());

    _ = try array.append(10);
    _ = try array.append(20);
    _ = try array.append(30);
    const cap_before = array.capacity();
    try std.testing.expect(cap_before >= 3);

    array.clear();
    try std.testing.expectEqual(@as(usize, 0), array.len());
    try std.testing.expectEqual(cap_before, array.capacity());
    try std.testing.expectEqual(@as(usize, 0), array.itemsConst().len);

    // Re-append within existing capacity.
    _ = try array.append(40);
    _ = try array.append(50);
    try std.testing.expectEqual(@as(usize, 2), array.len());
    try std.testing.expectEqual(@as(u32, 40), array.itemsConst()[0]);
    try std.testing.expectEqual(@as(u32, 50), array.itemsConst()[1]);
}

test "dense array budget propagation tracks growth and releases on deinit" {
    // Goal: prove budget accounting is correct through the DenseArray lifecycle.
    // Method: create with budget, append to trigger growth, then deinit and
    // assert budget returns to zero.
    const memory = static_collections.memory;
    var budget = try memory.budget.Budget.init(256);

    {
        var array = try DenseArray.init(std.testing.allocator, .{
            .budget = &budget,
        });
        defer array.deinit();

        _ = try array.append(1);
        try std.testing.expect(budget.used() > 0);

        _ = try array.append(2);
        _ = try array.append(3);
        const used_after_appends = budget.used();
        try std.testing.expect(used_after_appends > 0);

        // Clear does not release budget (capacity retained).
        array.clear();
        try std.testing.expectEqual(used_after_appends, budget.used());
    }

    // After deinit, budget is fully released.
    try std.testing.expectEqual(@as(usize, 0), budget.used());
}
