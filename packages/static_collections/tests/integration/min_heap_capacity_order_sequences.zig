//! Verifies MinHeap ordering and index tracking through push/pop/update sequences.
//! Exercises heap growth, priority updates, and extraction order to confirm
//! the min-heap invariant holds after every mutation.
const std = @import("std");
const static_collections = @import("static_collections");

const Error = static_collections.min_heap.Error;

const Item = struct {
    id: u32,
    priority: u32,
    index: usize = 0,
};

const Ctx = struct {
    pub fn lessThan(_: @This(), a: Item, b: Item) bool {
        return a.priority < b.priority;
    }

    pub fn setIndex(_: @This(), item: *Item, index: usize) void {
        item.index = index;
    }
};

const Heap = static_collections.min_heap.MinHeap(Item, Ctx);

fn findIndexById(heap: *const Heap, id: u32) ?usize {
    for (heap.items[0..heap.len_value], 0..) |item, index| {
        if (item.id == id) return index;
    }
    return null;
}

fn assertTrackedIndices(heap: *const Heap) !void {
    std.debug.assert(heap.len_value <= heap.items.len);
    for (heap.items[0..heap.len_value], 0..) |item, index| {
        std.debug.assert(item.index == index);
        try std.testing.expectEqual(index, item.index);
    }
}

test "min_heap capacity, NoSpaceLeft, and updateAt keep min order stable" {
    var heap = try Heap.init(std.testing.allocator, .{ .capacity = 4, .budget = null }, .{});
    defer heap.deinit();

    std.debug.assert(heap.capacity() == 4);
    try std.testing.expectEqual(@as(usize, 4), heap.capacity());
    std.debug.assert(heap.isEmpty());
    try std.testing.expect(heap.isEmpty());

    try heap.push(.{ .id = 1, .priority = 30 });
    try heap.push(.{ .id = 2, .priority = 10 });
    try heap.push(.{ .id = 3, .priority = 20 });
    try assertTrackedIndices(&heap);

    std.debug.assert(heap.len() == 3);
    try std.testing.expectEqual(@as(usize, 3), heap.len());
    try std.testing.expectEqual(@as(u32, 2), heap.peekMin().?.id);
    try std.testing.expectEqual(@as(u32, 10), heap.peekMin().?.priority);

    const update_index = findIndexById(&heap, 1) orelse unreachable;
    heap.updateAt(update_index, .{ .id = 1, .priority = 5, .index = update_index });
    try assertTrackedIndices(&heap);

    std.debug.assert(heap.peekMin().?.id == 1);
    try std.testing.expectEqual(@as(u32, 1), heap.peekMin().?.id);
    try std.testing.expectEqual(@as(u32, 5), heap.peekMin().?.priority);

    try heap.push(.{ .id = 4, .priority = 40 });
    try assertTrackedIndices(&heap);

    std.debug.assert(heap.isFull());
    try std.testing.expect(heap.isFull());
    std.debug.assert(heap.len() == 4);
    try std.testing.expectEqual(@as(usize, 4), heap.len());
    try std.testing.expectError(Error.NoSpaceLeft, heap.push(.{ .id = 5, .priority = 1 }));
    try std.testing.expectEqual(@as(usize, 4), heap.len());
    try assertTrackedIndices(&heap);

    try std.testing.expectEqual(@as(u32, 1), heap.popMin().?.id);
    try std.testing.expectEqual(@as(u32, 2), heap.popMin().?.id);
    try std.testing.expectEqual(@as(u32, 3), heap.popMin().?.id);
    try std.testing.expectEqual(@as(u32, 4), heap.popMin().?.id);
    try std.testing.expectEqual(@as(?Item, null), heap.popMin());

    std.debug.assert(heap.isEmpty());
    try std.testing.expect(heap.isEmpty());
}
