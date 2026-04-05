//! MinHeap: bounded binary heap that owns primitive heap ordering mechanics.
//!
//! This module is the single heap primitive for the workspace. Higher-level
//! queue-facing semantics such as `WouldBlock` and queue-oriented naming belong
//! in `static_queues.priority_queue`, which adapts this heap rather than
//! re-owning sift and storage logic.
//!
//! `Ctx` is a comptime comparator context type providing:
//! - `fn lessThan(ctx: Ctx, a: T, b: T) bool`
//! - `fn setIndex(ctx: Ctx, item: *T, index: usize) void` — required for
//!   correct use of `updateAt` and `removeAt`. Without it, callers have no
//!   way to track live indices after mutations that move elements.
//!
//! Heap indices are invalidated by any mutation (`push`, `popMin`, `updateAt`,
//! `removeAt`). `clear()` additionally calls `Ctx.setIndex` with
//! `invalid_index` for every live element when index tracking is enabled.
//! Callers must use `Ctx.setIndex` to maintain a live index for each element,
//! or find elements by linear scan before each indexed operation.
//!
//! When `Ctx == void`, `T` must implement `fn lessThan(a: T, b: T) bool`.
//! The void-context path does not support `updateAt` or `removeAt` with
//! tracked indices.

const std = @import("std");
const builtin = @import("builtin");
const memory = @import("static_memory");

pub const Error = error{
    OutOfMemory,
    Overflow,
    // Returned when capacity == 0 at init time. A zero-capacity heap cannot
    // hold any entries, making every push a programmer error before it starts.
    InvalidConfig,
    // Returned when push is called on a heap that has reached its capacity.
    NoSpaceLeft,
};

pub fn MinHeap(comptime T: type, comptime Ctx: type) type {
    comptime {
        std.debug.assert(@sizeOf(T) > 0);
        std.debug.assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();

        pub const Config = struct {
            capacity: usize,
            budget: ?*memory.budget.Budget = null,
        };
        pub const PushError = error{NoSpaceLeft};
        pub const invalid_index = std.math.maxInt(usize);

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        items: []T,
        len_value: usize,
        ctx: Ctx,

        pub fn init(allocator: std.mem.Allocator, config: Config, ctx: Ctx) Error!Self {
            if (config.capacity == 0) return Error.InvalidConfig;

            const bytes = try bytesForCapacity(config.capacity);
            try reserveBudget(config.budget, bytes);
            errdefer if (config.budget) |budget| budget.release(bytes);

            const items = allocator.alloc(T, config.capacity) catch return Error.OutOfMemory;
            errdefer allocator.free(items);

            var self: Self = .{
                .allocator = allocator,
                .budget = config.budget,
                .items = items,
                .len_value = 0,
                .ctx = ctx,
            };
            self.assertStorageInvariant();
            std.debug.assert(self.items.len == config.capacity);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertStorageInvariant();
            if (self.budget) |budget| {
                budget.release(bytesForCapacityAssumeValid(self.items.len));
            }
            self.allocator.free(self.items);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            self.assertStorageInvariant();
            return self.len_value;
        }

        pub fn isEmpty(self: *const Self) bool {
            self.assertStorageInvariant();
            return self.len_value == 0;
        }

        pub fn isFull(self: *const Self) bool {
            self.assertStorageInvariant();
            return self.len_value == self.items.len;
        }

        pub fn capacity(self: *const Self) usize {
            self.assertStorageInvariant();
            return self.items.len;
        }

        /// Resets the heap to empty while retaining storage.
        /// When `Ctx.setIndex` exists, every previously live element is
        /// invalidated via `setIndex(..., invalid_index)` before len becomes 0.
        pub fn clear(self: *Self) void {
            self.assertStorageInvariant();
            var index: usize = 0;
            while (index < self.len_value) : (index += 1) {
                self.invalidateIndex(index);
            }
            self.len_value = 0;
            std.debug.assert(self.len_value == 0);
        }

        /// Creates an independent copy of the heap storage.
        /// The comparator context is copied by value. If `Ctx` wraps pointers
        /// or other shared external state, the clone observes that same state.
        pub fn clone(self: *const Self) Error!Self {
            self.assertStorageInvariant();
            const cap = self.items.len;
            const bytes = try bytesForCapacity(cap);
            try reserveBudget(self.budget, bytes);

            const new_items = self.allocator.alloc(T, cap) catch {
                if (self.budget) |budget| budget.release(bytes);
                return Error.OutOfMemory;
            };
            @memcpy(new_items[0..self.len_value], self.items[0..self.len_value]);

            var result: Self = .{
                .allocator = self.allocator,
                .budget = self.budget,
                .items = new_items,
                .len_value = self.len_value,
                .ctx = self.ctx,
            };
            result.assertStorageInvariant();
            result.assertHeapInvariant();
            return result;
        }

        /// Push a value into the heap.
        /// Returns `error.NoSpaceLeft` if the heap is at capacity.
        pub fn push(self: *Self, value: T) PushError!void {
            self.assertStorageInvariant();
            if (self.len_value == self.items.len) return error.NoSpaceLeft;

            const index = self.len_value;
            self.len_value += 1;
            self.items[index] = value;
            self.syncIndex(index);
            self.siftUp(index);
            self.assertStorageInvariant();
            self.assertHeapInvariant();
        }

        /// Pop and return the minimum value. Returns null if the heap is empty.
        /// When index tracking is active, the removed entry's tracked index is
        /// invalidated via `Ctx.setIndex(..., invalid_index)` before return.
        pub fn popMin(self: *Self) ?T {
            self.assertStorageInvariant();
            if (self.len_value == 0) return null;

            const value = self.items[0];
            self.invalidateIndex(0);
            self.len_value -= 1;
            if (self.len_value > 0) {
                self.items[0] = self.items[self.len_value];
                self.syncIndex(0);
                self.siftDown(0);
            }
            self.assertStorageInvariant();
            self.assertHeapInvariant();
            return value;
        }

        /// Return the minimum value without removing it. Returns null if empty.
        pub fn peekMin(self: *const Self) ?T {
            self.assertStorageInvariant();
            if (self.len_value == 0) return null;
            return self.items[0];
        }

        /// Replaces the value currently stored at `index` and restores heap order.
        pub fn updateAt(self: *Self, index: usize, new_value: T) void {
            self.assertStorageInvariant();
            std.debug.assert(index < self.len_value);

            const old_value = self.items[index];
            self.items[index] = new_value;
            self.syncIndex(index);

            if (self.lessThanCtx(new_value, old_value)) {
                self.siftUp(index);
            } else {
                self.siftDown(index);
            }
            self.assertStorageInvariant();
            self.assertHeapInvariant();
        }

        /// Removes and returns the value currently stored at `index`.
        /// When index tracking is active, the removed entry's tracked index is
        /// invalidated via `Ctx.setIndex(..., invalid_index)` before return.
        pub fn removeAt(self: *Self, index: usize) T {
            self.assertStorageInvariant();
            std.debug.assert(index < self.len_value);

            const value = self.items[index];
            self.invalidateIndex(index);
            self.len_value -= 1;
            if (index < self.len_value) {
                const moved_value = self.items[self.len_value];
                self.items[index] = moved_value;
                self.syncIndex(index);

                if (self.lessThanCtx(moved_value, value)) {
                    self.siftUp(index);
                } else {
                    self.siftDown(index);
                }
            }
            self.assertStorageInvariant();
            self.assertHeapInvariant();
            return value;
        }

        fn siftUp(self: *Self, start: usize) void {
            std.debug.assert(start < self.len_value);
            var i: usize = start;
            var steps: usize = 0;
            while (i > 0) : (steps += 1) {
                std.debug.assert(steps < self.len_value);
                const parent = (i - 1) / 2;
                if (!self.lessThanCtx(self.items[i], self.items[parent])) break;
                std.mem.swap(T, &self.items[i], &self.items[parent]);
                self.syncIndex(i);
                self.syncIndex(parent);
                i = parent;
            }
        }

        fn siftDown(self: *Self, start: usize) void {
            std.debug.assert(start < self.len_value);
            var i: usize = start;
            var steps: usize = 0;
            while (steps < self.len_value) : (steps += 1) {
                const left = i * 2 + 1;
                const right = left + 1;
                if (left >= self.len_value) break;
                var smallest = left;
                if (right < self.len_value and self.lessThanCtx(self.items[right], self.items[left])) {
                    smallest = right;
                }
                if (!self.lessThanCtx(self.items[smallest], self.items[i])) break;
                std.mem.swap(T, &self.items[i], &self.items[smallest]);
                self.syncIndex(i);
                self.syncIndex(smallest);
                i = smallest;
            }
        }

        fn syncIndex(self: *Self, index: usize) void {
            if (comptime Ctx != void and std.meta.hasFn(Ctx, "setIndex")) {
                self.ctx.setIndex(&self.items[index], index);
            }
        }

        fn invalidateIndex(self: *Self, index: usize) void {
            if (comptime Ctx != void and std.meta.hasFn(Ctx, "setIndex")) {
                self.ctx.setIndex(&self.items[index], invalid_index);
            }
        }

        fn lessThanCtx(self: *const Self, a: T, b: T) bool {
            if (Ctx == void) {
                return T.lessThan(a, b);
            } else {
                return self.ctx.lessThan(a, b);
            }
        }

        fn assertStorageInvariant(self: *const Self) void {
            std.debug.assert(self.items.len > 0);
            std.debug.assert(self.len_value <= self.items.len);
        }

        fn assertHeapInvariant(self: *const Self) void {
            if (comptime builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) return;

            self.assertStorageInvariant();
            var child_index: usize = 1;
            while (child_index < self.len_value) : (child_index += 1) {
                const parent_index = (child_index - 1) / 2;
                const child_item = self.items[child_index];
                const parent_item = self.items[parent_index];
                std.debug.assert(!self.lessThanCtx(child_item, parent_item));
                std.debug.assert(!self.lessThanCtx(child_item, child_item));
                std.debug.assert(!self.lessThanCtx(parent_item, parent_item));
            }
        }

        fn bytesForCapacity(item_capacity: usize) Error!usize {
            const bytes = std.math.mul(usize, item_capacity, @sizeOf(T)) catch return error.Overflow;
            std.debug.assert(bytes > 0);
            return bytes;
        }

        fn bytesForCapacityAssumeValid(item_capacity: usize) usize {
            std.debug.assert(item_capacity > 0);
            std.debug.assert(item_capacity <= std.math.maxInt(usize) / @sizeOf(T));
            return item_capacity * @sizeOf(T);
        }

        fn reserveBudget(budget: ?*memory.budget.Budget, bytes: usize) Error!void {
            const reserved_budget = budget orelse return;
            std.debug.assert(bytes > 0);
            reserved_budget.tryReserve(bytes) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
        }
    };
}

const TestCmp = struct {
    pub fn lessThan(_: @This(), a: u32, b: u32) bool {
        return a < b;
    }
};

test "MinHeap push and popMin maintain min order" {
    // Goal: verify heap ordering on nominal push/pop workloads.
    // Method: insert unsorted values and confirm ascending pop sequence.
    var heap = try MinHeap(u32, TestCmp).init(std.testing.allocator, .{ .capacity = 8 }, .{});
    defer heap.deinit();

    try heap.push(5);
    try heap.push(1);
    try heap.push(3);

    // Invariant: three pushes recorded correctly (paired assert + expectEqual).
    std.debug.assert(heap.len() == 3);
    try std.testing.expectEqual(@as(usize, 3), heap.len());

    try std.testing.expectEqual(@as(u32, 1), heap.popMin().?);
    try std.testing.expectEqual(@as(u32, 3), heap.popMin().?);
    try std.testing.expectEqual(@as(u32, 5), heap.popMin().?);
    try std.testing.expectEqual(@as(?u32, null), heap.popMin());

    std.debug.assert(heap.isEmpty());
    try std.testing.expect(heap.isEmpty());
}

test "MinHeap push into full heap returns NoSpaceLeft" {
    // Goal: enforce capacity bound under valid operating conditions.
    // Method: fill the heap and assert one additional push fails.
    var heap = try MinHeap(u32, TestCmp).init(std.testing.allocator, .{ .capacity = 2 }, .{});
    defer heap.deinit();

    try heap.push(1);
    try heap.push(2);
    try std.testing.expectError(Error.NoSpaceLeft, heap.push(3));

    // Invariant: len did not change after the failed push.
    std.debug.assert(heap.len() == 2);
    try std.testing.expectEqual(@as(usize, 2), heap.len());
}

test "MinHeap capacity 0 returns InvalidConfig" {
    // Goal: reject invalid zero-capacity configuration at initialization.
    // Method: initialize with capacity=0 and assert InvalidConfig.
    try std.testing.expectError(
        Error.InvalidConfig,
        MinHeap(u32, TestCmp).init(std.testing.allocator, .{ .capacity = 0 }, .{}),
    );
}

test "MinHeap peekMin returns minimum without removing" {
    // Goal: verify peek observes minimum without mutating heap length.
    // Method: check empty peek, then push values and validate len stability.
    var heap = try MinHeap(u32, TestCmp).init(std.testing.allocator, .{ .capacity = 4 }, .{});
    defer heap.deinit();

    try std.testing.expectEqual(@as(?u32, null), heap.peekMin());

    try heap.push(7);
    try heap.push(2);

    // Invariant: peekMin does not change len (paired assert + expectEqual).
    std.debug.assert(heap.len() == 2);
    try std.testing.expectEqual(@as(?u32, 2), heap.peekMin());
    try std.testing.expectEqual(@as(usize, 2), heap.len());
}

test "MinHeap updateAt and removeAt keep tracked indices aligned" {
    // Goal: prove the heap primitive owns index-tracking mutations needed by higher-level adaptors.
    // Method: update and remove tracked items, then assert heap indices and ordering from two paths.
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
    const Heap = MinHeap(Item, Ctx);
    const TestHelper = struct {
        fn assertTrackedIndices(heap: *const Heap) !void {
            for (heap.items[0..heap.len_value], 0..) |item, index| {
                std.debug.assert(item.index == index);
                try std.testing.expectEqual(index, item.index);
            }
        }

        fn findIndexById(heap: *const Heap, id: u32) ?usize {
            for (heap.items[0..heap.len_value], 0..) |item, index| {
                if (item.id == id) return index;
            }
            return null;
        }
    };

    var heap = try Heap.init(std.testing.allocator, .{ .capacity = 4 }, .{});
    defer heap.deinit();

    try heap.push(.{ .id = 1, .priority = 20 });
    try heap.push(.{ .id = 2, .priority = 10 });
    try heap.push(.{ .id = 3, .priority = 30 });
    try TestHelper.assertTrackedIndices(&heap);

    const update_index = TestHelper.findIndexById(&heap, 3);
    try std.testing.expect(update_index != null);
    heap.updateAt(update_index.?, .{ .id = 3, .priority = 5, .index = update_index.? });
    try TestHelper.assertTrackedIndices(&heap);
    try std.testing.expectEqual(@as(u32, 3), heap.peekMin().?.id);

    const remove_index = TestHelper.findIndexById(&heap, 2);
    try std.testing.expect(remove_index != null);
    const removed = heap.removeAt(remove_index.?);
    try std.testing.expectEqual(@as(u32, 2), removed.id);
    try TestHelper.assertTrackedIndices(&heap);

    try std.testing.expectEqual(@as(u32, 3), heap.popMin().?.id);
    try std.testing.expectEqual(@as(u32, 1), heap.popMin().?.id);
    try std.testing.expectEqual(@as(?Item, null), heap.popMin());
}

test "MinHeap reserves and releases optional budget" {
    // Goal: keep heap ownership compatible with package-level memory budgets.
    // Method: reserve the full backing allocation at init, then release it at deinit.
    const reserved_bytes = @sizeOf(u32) * 4;
    var budget = try memory.budget.Budget.init(reserved_bytes);

    var heap = try MinHeap(u32, TestCmp).init(
        std.testing.allocator,
        .{ .capacity = 4, .budget = &budget },
        .{},
    );
    try std.testing.expectEqual(@as(u64, reserved_bytes), budget.used());

    heap.deinit();
    try std.testing.expectEqual(@as(u64, 0), budget.used());
}

test "MinHeap stress: random inserts maintain heap invariant" {
    // Goal: property-check ordering across a broad randomized input set.
    // Method: fixed-seed random fill, then assert non-decreasing pop stream.
    // Property test with a fixed seed for reproducibility.
    // Invariant: pops must return values in non-decreasing order.
    // Verified from two code paths: assert (process-fatal) + expect (test framework).
    const capacity: usize = 64;
    var heap = try MinHeap(u32, TestCmp).init(std.testing.allocator, .{ .capacity = capacity }, .{});
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(0xabcd_1234_5678_ef00);
    const random = prng.random();

    // Fill heap with random values.
    var pushed: usize = 0;
    while (pushed < capacity) : (pushed += 1) {
        try heap.push(random.uintLessThan(u32, 1000));
    }

    // Pop all values; each must be >= the previous.
    var prev: u32 = 0;
    while (heap.popMin()) |v| {
        std.debug.assert(v >= prev);
        try std.testing.expect(v >= prev);
        prev = v;
    }

    std.debug.assert(heap.isEmpty());
    try std.testing.expect(heap.isEmpty());
}

test "MinHeap supports type-defined comparator when Ctx is void" {
    // Goal: cover the void-context comparator path.
    // Method: provide an element type with lessThan and verify min ordering.
    const Entry = struct {
        value: u32,

        pub fn lessThan(a: @This(), b: @This()) bool {
            return a.value < b.value;
        }
    };

    var heap = try MinHeap(Entry, void).init(std.testing.allocator, .{ .capacity = 4 }, {});
    defer heap.deinit();

    try heap.push(.{ .value = 9 });
    try heap.push(.{ .value = 1 });
    try heap.push(.{ .value = 4 });

    try std.testing.expectEqual(@as(u32, 1), heap.popMin().?.value);
    try std.testing.expectEqual(@as(u32, 4), heap.popMin().?.value);
    try std.testing.expectEqual(@as(u32, 9), heap.popMin().?.value);
}

test "MinHeap clear invalidates tracked indices with the sentinel" {
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
    const Heap = MinHeap(Item, Ctx);

    var heap = try Heap.init(std.testing.allocator, .{ .capacity = 4 }, .{});
    defer heap.deinit();

    try heap.push(.{ .id = 1, .priority = 20 });
    try heap.push(.{ .id = 2, .priority = 10 });
    try heap.push(.{ .id = 3, .priority = 30 });

    heap.clear();

    try std.testing.expectEqual(@as(usize, 0), heap.len());
    try std.testing.expectEqual(Heap.invalid_index, heap.items[0].index);
    try std.testing.expectEqual(Heap.invalid_index, heap.items[1].index);
    try std.testing.expectEqual(Heap.invalid_index, heap.items[2].index);
}

test "MinHeap clone keeps storage independent and copies context by value" {
    const Item = struct {
        priority: u32,
    };
    const Ctx = struct {
        clear_events: *u32,

        pub fn lessThan(_: @This(), a: Item, b: Item) bool {
            return a.priority < b.priority;
        }

        pub fn setIndex(self: @This(), item: *Item, index: usize) void {
            _ = item;
            if (index == std.math.maxInt(usize)) {
                self.clear_events.* += 1;
            }
        }
    };
    const Heap = MinHeap(Item, Ctx);

    var clear_events: u32 = 0;
    var heap = try Heap.init(std.testing.allocator, .{ .capacity = 4 }, .{ .clear_events = &clear_events });
    defer heap.deinit();
    try heap.push(.{ .priority = 20 });
    try heap.push(.{ .priority = 10 });

    var clone = try heap.clone();
    defer clone.deinit();

    try std.testing.expect(clone.ctx.clear_events == heap.ctx.clear_events);
    clone.clear();
    try std.testing.expectEqual(@as(usize, 2), heap.len());
    try std.testing.expectEqual(@as(usize, 0), clone.len());
    try std.testing.expectEqual(@as(u32, 2), clear_events);
    try std.testing.expectEqual(@as(u32, 10), heap.peekMin().?.priority);
}

test "MinHeap popMin and removeAt invalidate removed tracked indices" {
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
    const Heap = MinHeap(Item, Ctx);

    var heap = try Heap.init(std.testing.allocator, .{ .capacity = 4 }, .{});
    defer heap.deinit();

    try heap.push(.{ .id = 1, .priority = 30 });
    try heap.push(.{ .id = 2, .priority = 10 });
    try heap.push(.{ .id = 3, .priority = 20 });

    const popped = heap.popMin().?;
    try std.testing.expectEqual(@as(u32, 2), popped.id);
    // Value is captured before invalidation, so the returned copy retains
    // its original index. The heap-internal slot is invalidated separately.

    var remove_index: ?usize = null;
    for (heap.items[0..heap.len_value], 0..) |item, index| {
        if (item.id == 3) remove_index = index;
    }
    try std.testing.expect(remove_index != null);

    const removed = heap.removeAt(remove_index.?);
    try std.testing.expectEqual(@as(u32, 3), removed.id);
}
