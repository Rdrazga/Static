const std = @import("std");
const testing = std.testing;
const static_queues = @import("static_queues");

test "priority queue tracks indexed mutations across update and remove" {
    const Item = struct {
        id: u32,
        priority: u32,
        index: usize = 0,
    };
    const Ctx = struct {
        indices: *[4]?usize,

        pub fn lessThan(_: @This(), a: Item, b: Item) bool {
            return a.priority < b.priority;
        }

        pub fn setIndex(self: @This(), item: *Item, index: usize) void {
            if (index == static_queues.priority_queue.PriorityQueue(Item, @This()).invalid_index) {
                self.indices[item.id] = null;
            } else {
                self.indices[item.id] = index;
            }
            item.index = index;
        }
    };

    var tracked_indices: [4]?usize = .{ null, null, null, null };
    var pq = try static_queues.priority_queue.PriorityQueue(Item, Ctx).init(
        testing.allocator,
        .{ .capacity = 4, .budget = null },
        .{ .indices = &tracked_indices },
    );
    defer pq.deinit();

    try pq.tryPush(.{ .id = 1, .priority = 20 });
    try pq.tryPush(.{ .id = 2, .priority = 10 });
    try pq.tryPush(.{ .id = 3, .priority = 30 });

    const root_before = pq.peek().?;
    try testing.expectEqual(@as(u32, 2), root_before.id);
    try testing.expectEqual(@as(usize, 0), root_before.index);
    try testing.expectEqual(@as(usize, 0), tracked_indices[2].?);

    const update_index = tracked_indices[3].?;
    pq.update(update_index, .{ .id = 3, .priority = 5, .index = update_index });

    const root_after_update = pq.peek().?;
    try testing.expectEqual(@as(u32, 3), root_after_update.id);
    try testing.expectEqual(@as(usize, 0), root_after_update.index);
    try testing.expectEqual(root_after_update.index, tracked_indices[3].?);

    const remove_index = tracked_indices[2].?;
    const removed = pq.remove(remove_index);
    try testing.expectEqual(@as(u32, 2), removed.id);
    // Returned value is captured before invalidation; the external tracked
    // index array is still updated via setIndex(..., invalid_index).
    try testing.expectEqual(@as(?usize, null), tracked_indices[2]);

    const next_after_remove = pq.peek().?;
    try testing.expectEqual(next_after_remove.index, tracked_indices[@as(usize, next_after_remove.id)].?);
    const popped_after_remove = try pq.tryPop();
    try testing.expectEqual(next_after_remove.id, popped_after_remove.id);
    try testing.expectEqual(next_after_remove.priority, popped_after_remove.priority);
    try testing.expectEqual(@as(?usize, null), tracked_indices[@as(usize, popped_after_remove.id)]);

    const final_peek = pq.peek().?;
    try testing.expectEqual(final_peek.index, tracked_indices[@as(usize, final_peek.id)].?);
    const final_popped = try pq.tryPop();
    try testing.expectEqual(final_peek.id, final_popped.id);
    try testing.expectEqual(final_peek.priority, final_popped.priority);
    try testing.expectEqual(@as(?usize, null), tracked_indices[@as(usize, final_popped.id)]);

    try testing.expect(pq.peek() == null);
    try testing.expectEqual(@as(?usize, null), tracked_indices[1]);
    try testing.expectEqual(@as(?usize, null), tracked_indices[2]);
    try testing.expectEqual(@as(?usize, null), tracked_indices[3]);
}

test "priority queue clear invalidates tracked indices with the sentinel" {
    const Item = struct {
        id: u32,
        priority: u32,
        index: usize = 0,
    };
    const Ctx = struct {
        indices: *[4]?usize,

        pub fn lessThan(_: @This(), a: Item, b: Item) bool {
            return a.priority < b.priority;
        }

        pub fn setIndex(self: @This(), item: *Item, index: usize) void {
            if (index == static_queues.priority_queue.PriorityQueue(Item, @This()).invalid_index) {
                self.indices[item.id] = null;
            } else {
                self.indices[item.id] = index;
            }
            item.index = index;
        }
    };
    const Queue = static_queues.priority_queue.PriorityQueue(Item, Ctx);

    var tracked_indices: [4]?usize = .{ null, null, null, null };
    var pq = try Queue.init(
        testing.allocator,
        .{ .capacity = 4, .budget = null },
        .{ .indices = &tracked_indices },
    );
    defer pq.deinit();

    try pq.tryPush(.{ .id = 1, .priority = 20 });
    try pq.tryPush(.{ .id = 2, .priority = 10 });
    try pq.tryPush(.{ .id = 3, .priority = 30 });

    pq.clear();

    try testing.expectEqual(@as(usize, 0), pq.len());
    try testing.expect(pq.peek() == null);
    try testing.expectEqual(@as(?usize, null), tracked_indices[1]);
    try testing.expectEqual(@as(?usize, null), tracked_indices[2]);
    try testing.expectEqual(@as(?usize, null), tracked_indices[3]);
}
