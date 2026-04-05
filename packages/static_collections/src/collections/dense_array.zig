//! Dense array: a packed, gap-free array with O(1) swap-remove deletion.
//!
//! Key type: `DenseArray(T)`. Items are stored in contiguous memory. Removals
//! swap-remove (filling the gap with the last element), keeping storage dense.
//! Indices returned by `append` are positional and are invalidated when
//! `swapRemove` moves the last element into a vacated slot. Callers that need
//! stable external references or generation-based stale-reference detection
//! should use `SlotMap` or compose `IndexPool` with their own storage.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const vec = @import("vec.zig");
const memory = @import("static_memory");
const assert = std.debug.assert;

pub fn DenseArray(comptime T: type) type {
    return struct {
        const Self = @This();

        comptime {
            assert(@sizeOf(T) > 0);
        }

        pub const Element = T;
        pub const Error = vec.Error || error{NotFound};
        pub const Config = struct {
            initial_capacity: u32 = 0,
            budget: ?*memory.budget.Budget = null,
        };

        data: vec.Vec(T),

        pub fn init(allocator: std.mem.Allocator, config: Config) Error!Self {
            var self: Self = .{
                .data = try vec.Vec(T).init(allocator, .{
                    .initial_capacity = config.initial_capacity,
                    .budget = config.budget,
                }),
            };
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            self.data.deinit();
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            self.assertInvariants();
            return self.data.len();
        }

        pub fn items(self: *Self) []T {
            self.assertInvariants();
            return self.data.items();
        }

        pub fn itemsConst(self: *const Self) []const T {
            self.assertInvariants();
            return self.data.itemsConst();
        }

        pub fn capacity(self: *const Self) usize {
            self.assertInvariants();
            return self.data.capacity();
        }

        /// Resets the logical length to zero without releasing backing memory.
        /// All previously returned indices become invalid after clear.
        pub fn clear(self: *Self) void {
            self.assertInvariants();
            self.data.clear();
            assert(self.data.len() == 0);
            self.assertInvariants();
        }

        /// Shrinks backing capacity to match the current logical length.
        pub fn shrinkToFit(self: *Self) void {
            self.assertInvariants();
            self.data.shrinkToFit();
            self.assertInvariants();
        }

        /// Creates an independent copy with its own backing memory.
        pub fn clone(self: *const Self) Error!Self {
            self.assertInvariants();
            var result: Self = .{ .data = try self.data.clone() };
            result.assertInvariants();
            return result;
        }

        pub fn append(self: *Self, value: T) Error!usize {
            self.assertInvariants();
            const index = self.data.len();
            try self.data.append(value);
            assert(self.data.len() == index + 1);
            assert(index < self.data.len());
            return index;
        }

        pub fn get(self: *Self, index: usize) ?*T {
            self.assertInvariants();
            if (index >= self.data.len()) return null;
            const result = &self.data.items()[index];
            assert(@intFromPtr(result) != 0);
            return result;
        }

        pub fn getConst(self: *const Self, index: usize) ?*const T {
            self.assertInvariants();
            if (index >= self.data.len()) return null;
            const result = &self.data.itemsConst()[index];
            assert(@intFromPtr(result) != 0);
            return result;
        }

        /// Removes the element at `index` by swapping it with the last element.
        /// O(1). Does not preserve ordering. Returns the removed value.
        ///
        /// After this call, the index that previously referred to the last
        /// element now points to different data (the moved element occupies
        /// the vacated slot). Callers that maintain external index-to-entity
        /// mappings must update them after every swap-remove.
        pub fn swapRemove(self: *Self, index: usize) Error!T {
            self.assertInvariants();
            const current_len = self.data.len();
            if (index >= current_len) return error.NotFound;
            assert(current_len > 0);
            assert(index < current_len);

            const all = self.data.items();
            assert(all.len == current_len);
            const removed = all[index];
            const last = all[current_len - 1];

            all[index] = last;
            _ = self.data.pop();

            assert(self.data.len() == current_len - 1);
            self.assertInvariants();
            return removed;
        }

        fn assertInvariants(self: *const Self) void {
            assert(self.data.len() == self.data.itemsConst().len);
            assert(self.data.capacity() >= self.data.len());
        }
    };
}

test "dense array append and get" {
    // Goal: verify stable indexing and retrieval after ordered appends.
    // Method: append three values and validate returned indices plus reads.
    var da = try DenseArray(u32).init(std.testing.allocator, .{});
    defer da.deinit();

    const idx0 = try da.append(10);
    const idx1 = try da.append(20);
    const idx2 = try da.append(30);

    try std.testing.expectEqual(@as(usize, 0), idx0);
    try std.testing.expectEqual(@as(usize, 1), idx1);
    try std.testing.expectEqual(@as(usize, 2), idx2);
    try std.testing.expectEqual(@as(u32, 10), da.get(0).?.*);
    try std.testing.expectEqual(@as(u32, 20), da.get(1).?.*);
    try std.testing.expect(da.get(3) == null);
}

test "dense array swapRemove maintains density" {
    // Goal: ensure swapRemove keeps storage dense without preserving order.
    // Method: remove a middle item and confirm last element back-fills the gap.
    var da = try DenseArray(u32).init(std.testing.allocator, .{});
    defer da.deinit();

    _ = try da.append(10);
    _ = try da.append(20);
    _ = try da.append(30);

    const removed = try da.swapRemove(1);
    try std.testing.expectEqual(@as(u32, 20), removed);
    try std.testing.expectEqual(@as(u32, 10), da.get(0).?.*);
    try std.testing.expectEqual(@as(u32, 30), da.get(1).?.*);
}

test "dense array swapRemove last element" {
    // Goal: ensure removing the tail element decrements length correctly.
    // Method: insert one value, remove index 0, and validate empty state.
    var da = try DenseArray(u32).init(std.testing.allocator, .{});
    defer da.deinit();

    _ = try da.append(42);
    const removed = try da.swapRemove(0);
    try std.testing.expectEqual(@as(u32, 42), removed);
    try std.testing.expectEqual(@as(usize, 0), da.len());
}

test "dense array swapRemove out-of-bounds returns NotFound" {
    // Goal: reject invalid removals outside current dense range.
    // Method: attempt remove at len and assert NotFound.
    var da = try DenseArray(u32).init(std.testing.allocator, .{});
    defer da.deinit();

    _ = try da.append(1);
    try std.testing.expectError(error.NotFound, da.swapRemove(1));
}

test "dense array swapRemove from empty returns NotFound" {
    // Goal: enforce invalid-data handling on empty container removal.
    // Method: remove index 0 from an empty array and assert NotFound.
    var da = try DenseArray(u32).init(std.testing.allocator, .{});
    defer da.deinit();
    try std.testing.expectError(error.NotFound, da.swapRemove(0));
}

test "dense array clear resets length and allows reuse" {
    // Goal: confirm clear resets logical length without releasing capacity.
    // Method: append values, clear, assert empty, then append again and verify.
    var da = try DenseArray(u32).init(std.testing.allocator, .{});
    defer da.deinit();

    _ = try da.append(10);
    _ = try da.append(20);
    try std.testing.expectEqual(@as(usize, 2), da.len());

    da.clear();
    try std.testing.expectEqual(@as(usize, 0), da.len());

    const idx = try da.append(30);
    try std.testing.expectEqual(@as(usize, 0), idx);
    try std.testing.expectEqual(@as(u32, 30), da.get(0).?.*);
}

test "dense array itemsConst provides read-only dense slice" {
    // Goal: confirm itemsConst returns a const view matching append order.
    // Method: append values, read via itemsConst, then verify length and content.
    var da = try DenseArray(u32).init(std.testing.allocator, .{});
    defer da.deinit();

    _ = try da.append(10);
    _ = try da.append(20);
    _ = try da.append(30);

    const slice = da.itemsConst();
    try std.testing.expectEqual(@as(usize, 3), slice.len);
    try std.testing.expectEqual(@as(u32, 10), slice[0]);
    try std.testing.expectEqual(@as(u32, 20), slice[1]);
    try std.testing.expectEqual(@as(u32, 30), slice[2]);
}

test "dense array capacity reports backing storage size" {
    // Goal: confirm capacity is at least as large as len and grows with appends.
    // Method: check capacity after init and after appends.
    var da = try DenseArray(u32).init(std.testing.allocator, .{ .initial_capacity = 8 });
    defer da.deinit();

    try std.testing.expect(da.capacity() >= 8);
    try std.testing.expectEqual(@as(usize, 0), da.len());

    _ = try da.append(1);
    _ = try da.append(2);
    try std.testing.expect(da.capacity() >= 2);
    try std.testing.expect(da.capacity() >= da.len());
}
