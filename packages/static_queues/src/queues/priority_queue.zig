//! PriorityQueue: queue-facing adaptor over `static_collections.min_heap`.
//!
//! `static_collections.min_heap` owns heap storage and sift mechanics. This
//! module keeps the queue package's vocabulary: `WouldBlock`, queue-oriented
//! method names, and index-aware update/remove semantics for scheduler-style
//! workloads.
//!
//! Capacity: fixed at init time; any positive count.
//! Thread safety: single-threaded. Wrap with a mutex for concurrent access.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when full or empty.
//! Note: `update`/`remove` require a Context that provides `setIndex`.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const collections = @import("static_collections");
const memory = @import("static_memory");
const ring = @import("ring_buffer.zig");
const contracts = @import("../contracts.zig");

pub fn supportsDefaultPriorityContext(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int, .@"enum" => true,
        else => false,
    };
}

pub fn DefaultPriorityContext(comptime T: type) type {
    comptime {
        if (!supportsDefaultPriorityContext(T)) {
            @compileError(
                "DefaultPriorityContext supports only integer and enum element types; " ++
                    "provide an explicit context with `lessThan` for `" ++
                    @typeName(T) ++ "`.",
            );
        }
    }

    return struct {
        pub fn lessThan(ctx: @This(), a: T, b: T) bool {
            _ = ctx;
            return switch (@typeInfo(T)) {
                .@"enum" => @intFromEnum(a) < @intFromEnum(b),
                else => a < b,
            };
        }
    };
}

pub fn PriorityQueueDefault(comptime T: type) type {
    return PriorityQueue(T, DefaultPriorityContext(T));
}

pub fn PriorityQueue(comptime T: type, comptime Context: type) type {
    comptime {
        assert(@sizeOf(T) > 0);
        assert(@alignOf(T) > 0);
    }

    return struct {
        const Self = @This();
        const Heap = collections.min_heap.MinHeap(T, Context);

        pub const Element = T;
        pub const Error = ring.Error;
        pub const concurrency: contracts.Concurrency = .single_threaded;
        pub const is_lock_free = true;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .exact;
        pub const PushError = error{WouldBlock};
        pub const PopError = error{WouldBlock};
        pub const invalid_index = Heap.invalid_index;
        pub const Config = struct {
            capacity: usize,
            budget: ?*memory.budget.Budget,
        };

        heap: Heap,

        pub fn init(allocator: std.mem.Allocator, cfg: Config, context: Context) Error!Self {
            const heap = Heap.init(allocator, .{
                .capacity = cfg.capacity,
                .budget = cfg.budget,
            }, context) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidConfig => return error.InvalidConfig,
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.Overflow => return error.Overflow,
            };
            const self: Self = .{ .heap = heap };
            assert(self.heap.len() == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.heap.deinit();
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.heap.capacity();
        }

        pub fn len(self: *const Self) usize {
            return self.heap.len();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.heap.isEmpty();
        }

        pub fn isFull(self: *const Self) bool {
            return self.heap.isFull();
        }

        /// Clears the queue while retaining storage.
        /// When the context tracks indices through `setIndex`, all live entries
        /// are invalidated with `invalid_index`.
        pub fn clear(self: *Self) void {
            self.heap.clear();
        }

        pub fn peek(self: *const Self) ?T {
            return self.heap.peekMin();
        }

        pub fn tryPush(self: *Self, value: T) PushError!void {
            self.heap.push(value) catch return error.WouldBlock;
            assert(!self.heap.isEmpty());
        }

        pub fn tryPop(self: *Self) PopError!T {
            return self.heap.popMin() orelse error.WouldBlock;
        }

        /// Replaces the element at `index`. Any mutation may move other
        /// elements, so tracked indices must come from `Context.setIndex`.
        pub fn update(self: *Self, index: usize, new_value: T) void {
            requireTrackedContext();
            self.heap.updateAt(index, new_value);
        }

        /// Removes and returns the element currently stored at `index`.
        /// When index tracking is active, the removed entry's tracked index is
        /// invalidated via `Context.setIndex(..., invalid_index)` before return.
        pub fn remove(self: *Self, index: usize) T {
            requireTrackedContext();
            return self.heap.removeAt(index);
        }

        fn requireTrackedContext() void {
            comptime {
                if (!std.meta.hasFn(Context, "setIndex")) {
                    @compileError("PriorityQueue.update/remove require Context.setIndex to keep indices in sync.");
                }
            }
        }
    };
}

test "priority queue basic semantics" {
    const Ctx = struct {
        pub fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            _ = ctx;
            return a < b;
        }
    };
    var pq = try PriorityQueue(u32, Ctx).init(testing.allocator, .{ .capacity = 5, .budget = null }, .{});
    defer pq.deinit();

    try pq.tryPush(5);
    try pq.tryPush(2);
    try pq.tryPush(8);
    try pq.tryPush(1);

    try testing.expectEqual(@as(u32, 1), try pq.tryPop());
    try testing.expectEqual(@as(u32, 2), try pq.tryPop());
    try testing.expectEqual(@as(u32, 5), try pq.tryPop());
    try testing.expectEqual(@as(u32, 8), try pq.tryPop());
    try testing.expectError(error.WouldBlock, pq.tryPop());
}

test "priority queue decrease-key via update" {
    // Goal: preserve queue-style decrease-key behavior while delegating heap mechanics downward.
    // Method: lower one item's priority, then assert it becomes the next item popped.
    const Item = struct {
        id: u32,
        val: u32,
        index: usize = 0,
    };
    const Ctx = struct {
        pub fn lessThan(ctx: @This(), a: Item, b: Item) bool {
            _ = ctx;
            return a.val < b.val;
        }
        pub fn setIndex(ctx: @This(), item: *Item, index: usize) void {
            _ = ctx;
            item.index = index;
        }
    };
    var pq = try PriorityQueue(Item, Ctx).init(testing.allocator, .{ .capacity = 5, .budget = null }, .{});
    defer pq.deinit();

    try pq.tryPush(.{ .id = 1, .val = 10 });
    try pq.tryPush(.{ .id = 2, .val = 20 });
    try pq.tryPush(.{ .id = 3, .val = 30 });

    var target_index: ?usize = null;
    for (pq.heap.items[0..pq.heap.len_value], 0..) |item, i| {
        assert(item.index == i);
        try testing.expectEqual(i, item.index);
        if (item.id == 3) target_index = i;
    }
    try testing.expect(target_index != null);

    pq.update(target_index.?, .{ .id = 3, .val = 5, .index = target_index.? });

    const popped = try pq.tryPop();
    try testing.expectEqual(@as(u32, 3), popped.id);
    try testing.expectEqual(@as(u32, 5), popped.val);
}

test "priority queue remove preserves queue order" {
    // Goal: keep queue-style indexed removal behavior after the heap consolidation.
    // Method: remove one tracked element by index, then assert the remaining pop order.
    const Item = struct {
        id: u32,
        val: u32,
        index: usize = 0,
    };
    const Ctx = struct {
        pub fn lessThan(ctx: @This(), a: Item, b: Item) bool {
            _ = ctx;
            return a.val < b.val;
        }
        pub fn setIndex(ctx: @This(), item: *Item, index: usize) void {
            _ = ctx;
            item.index = index;
        }
    };
    var pq = try PriorityQueue(Item, Ctx).init(testing.allocator, .{ .capacity = 5, .budget = null }, .{});
    defer pq.deinit();

    try pq.tryPush(.{ .id = 1, .val = 10 });
    try pq.tryPush(.{ .id = 2, .val = 20 });
    try pq.tryPush(.{ .id = 3, .val = 5 });

    var remove_index: ?usize = null;
    for (pq.heap.items[0..pq.heap.len_value], 0..) |item, i| {
        assert(item.index == i);
        try testing.expectEqual(i, item.index);
        if (item.id == 2) remove_index = i;
    }
    try testing.expect(remove_index != null);

    const removed = pq.remove(remove_index.?);
    try testing.expectEqual(@as(u32, 2), removed.id);
    try testing.expectEqual(@as(u32, 3), (try pq.tryPop()).id);
    try testing.expectEqual(@as(u32, 1), (try pq.tryPop()).id);
    try testing.expectError(error.WouldBlock, pq.tryPop());
}

test "priority queue peek and introspection methods reflect queue state" {
    const Ctx = struct {
        pub fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            _ = ctx;
            return a < b;
        }
    };
    var pq = try PriorityQueue(u32, Ctx).init(testing.allocator, .{ .capacity = 3, .budget = null }, .{});
    defer pq.deinit();

    try testing.expectEqual(@as(usize, 3), pq.capacity());
    try testing.expectEqual(@as(usize, 0), pq.len());
    try testing.expect(pq.isEmpty());
    try testing.expect(!pq.isFull());
    try testing.expectEqual(@as(?u32, null), pq.peek());

    try pq.tryPush(4);
    try pq.tryPush(2);
    try testing.expectEqual(@as(usize, 2), pq.len());
    try testing.expect(!pq.isEmpty());
    try testing.expect(!pq.isFull());
    try testing.expectEqual(@as(?u32, 2), pq.peek());
    try pq.tryPush(1);
    try testing.expect(pq.isFull());

    pq.clear();
    try testing.expectEqual(@as(usize, 0), pq.len());
    try testing.expect(pq.isEmpty());
    try testing.expectEqual(@as(?u32, null), pq.peek());
}

test "priority queue default context supports integer types" {
    var pq = try PriorityQueueDefault(u32).init(testing.allocator, .{ .capacity = 4, .budget = null }, .{});
    defer pq.deinit();

    try pq.tryPush(10);
    try pq.tryPush(3);
    try pq.tryPush(7);
    try testing.expectEqual(@as(u32, 3), try pq.tryPop());
}

test "priority queue default context support detection is explicit" {
    const Unsupported = struct { value: u32 };
    try testing.expect(supportsDefaultPriorityContext(u16));
    try testing.expect(!supportsDefaultPriorityContext(Unsupported));
}

test "priority queue randomized ordering is monotonic under stress" {
    var prng = std.Random.DefaultPrng.init(@as(u64, 0xC0FFEE));
    const random = prng.random();
    const sample_count: usize = 128;
    const Ctx = DefaultPriorityContext(u32);

    var pq = try PriorityQueue(u32, Ctx).init(testing.allocator, .{ .capacity = sample_count, .budget = null }, .{});
    defer pq.deinit();

    var samples: [sample_count]u32 = undefined;
    var sample_index: usize = 0;
    while (sample_index < sample_count) : (sample_index += 1) {
        const value = random.int(u32);
        samples[sample_index] = value;
        try pq.tryPush(value);
    }

    std.mem.sortUnstable(u32, &samples, {}, std.sort.asc(u32));

    sample_index = 0;
    while (sample_index < sample_count) : (sample_index += 1) {
        try testing.expectEqual(samples[sample_index], try pq.tryPop());
    }
    try testing.expectError(error.WouldBlock, pq.tryPop());
}
