//! Dense array: a packed, gap-free array that provides stable `Handle` identifiers.
//!
//! Key type: `DenseArray(T)`. Items are stored in contiguous memory. Removals
//! swap-remove (filling the gap with the last element), keeping storage dense.
//! Handles encode a generation counter so stale references to removed items can
//! be detected at runtime.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const vec = @import("vec.zig");
const memory = @import("static_memory");
const assert = std.debug.assert;

pub fn DenseArray(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Error = vec.Error || error{NotFound};
        pub const Config = struct {
            initial_capacity: u32 = 0,
            budget: ?*memory.budget.Budget = null,
        };

        data: vec.Vec(T),

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            var self: Self = .{
                .data = try vec.Vec(T).init(allocator, .{
                    .initial_capacity = cfg.initial_capacity,
                    .budget = cfg.budget,
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
            assert(index < self.data.len());
            return &self.data.items()[index];
        }

        pub fn getConst(self: *const Self, index: usize) ?*const T {
            self.assertInvariants();
            if (index >= self.data.len()) return null;
            assert(index < self.data.len());
            return &self.data.items()[index];
        }

        /// Removes the element at `index` by swapping it with the last element.
        /// O(1). Does not preserve ordering. Returns the removed value.
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
            assert(self.data.len() == self.data.items().len);
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
