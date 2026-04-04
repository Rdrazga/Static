//! Sorted vector map: key-value store backed by a sorted array with binary search.
//!
//! Key type: `SortedVecMap(K, V)`. Suitable for small maps (< ~64 entries) where
//! cache locality of a flat array outweighs the O(N) insertion cost. Iteration is
//! in key order.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const memory = @import("static_memory");
const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    NotFound,
    NoSpaceLeft,
    InvalidConfig,
    Overflow,
};

pub fn SortedVecMap(comptime K: type, comptime V: type, comptime Cmp: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { key: K, value: V };

        pub const Key = K;
        pub const Value = V;
        pub const Compare = Cmp;
        pub const Config = struct {
            initial_capacity: u32 = 0,
            budget: ?*memory.budget.Budget = null,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        budget_reserved_capacity: usize = 0,
        entries: std.ArrayListUnmanaged(Entry) = .{},

        fn entryBytesForCapacity(cap: usize) error{Overflow}!usize {
            return std.math.mul(usize, cap, @sizeOf(Entry));
        }

        fn ensureBudgetCapacity(self: *Self, needed: usize) Error!void {
            if (self.budget == null) return;
            if (needed <= self.budget_reserved_capacity) return;
            const budget = self.budget.?;
            const new_bytes = entryBytesForCapacity(needed) catch return error.Overflow;
            const old_bytes = entryBytesForCapacity(self.budget_reserved_capacity) catch return error.Overflow;
            assert(new_bytes >= old_bytes);
            const delta = new_bytes - old_bytes;
            budget.tryReserve(delta) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
            self.budget_reserved_capacity = needed;
        }

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            var self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
            };
            if (cfg.initial_capacity > 0) {
                try self.ensureBudgetCapacity(cfg.initial_capacity);
                self.entries.ensureTotalCapacityPrecise(allocator, cfg.initial_capacity) catch {
                    if (self.budget) |budget| {
                        const bytes = entryBytesForCapacity(cfg.initial_capacity) catch unreachable;
                        budget.release(bytes);
                        self.budget_reserved_capacity = 0;
                    }
                    return error.OutOfMemory;
                };
            }
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            if (self.budget) |budget| {
                const bytes = entryBytesForCapacity(self.budget_reserved_capacity) catch unreachable;
                budget.release(bytes);
            }
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            self.assertInvariants();
            return self.entries.items.len;
        }

        pub fn get(self: *Self, key: K) ?*V {
            self.assertInvariants();
            const search = self.findIndex(key);
            if (!search.found) return null;
            assert(search.index < self.entries.items.len);
            return &self.entries.items[search.index].value;
        }

        pub fn getConst(self: *const Self, key: K) ?*const V {
            self.assertInvariants();
            const search = self.findIndex(key);
            if (!search.found) return null;
            assert(search.index < self.entries.items.len);
            return &self.entries.items[search.index].value;
        }

        pub fn put(self: *Self, key: K, value: V) Error!void {
            self.assertInvariants();
            const search = self.findIndex(key);
            if (search.found) {
                self.entries.items[search.index].value = value;
                self.assertInvariants();
                return;
            }

            // Reserve budget and backing capacity before mutating.
            const needed_capacity = std.math.add(usize, self.entries.items.len, 1) catch return error.Overflow;
            try self.ensureBudgetCapacity(needed_capacity);
            self.entries.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;

            const old_len = self.entries.items.len;

            // Direct shift-then-write insertion:
            //
            // 1. Extend the slice length by one (capacity is already reserved).
            // 2. memmove elements in [search.index, old_len) one position right,
            //    opening a gap at search.index. Source and destination overlap,
            //    so memmove (not memcpy) is required.
            // 3. Write the new entry into the gap.
            //
            // When search.index == old_len the entry belongs at the tail and
            // the memmove is a no-op (zero-length source).
            self.entries.items.len = old_len + 1;
            assert(self.entries.items.len <= self.entries.capacity);

            if (search.index < old_len) {
                @memmove(
                    self.entries.items[search.index + 1 .. old_len + 1],
                    self.entries.items[search.index..old_len],
                );
            }
            self.entries.items[search.index] = .{ .key = key, .value = value };
            self.assertInvariants();
        }

        pub fn remove(self: *Self, key: K) (error{NotFound} || Error)!V {
            self.assertInvariants();
            const search = self.findIndex(key);
            if (!search.found) return error.NotFound;
            const old_len = self.entries.items.len;
            assert(old_len > 0);
            const old = self.entries.items[search.index].value;
            if (search.index + 1 < old_len) {
                @memmove(
                    self.entries.items[search.index .. old_len - 1],
                    self.entries.items[search.index + 1 .. old_len],
                );
            }
            _ = self.entries.pop();
            assert(self.entries.items.len == old_len - 1);
            self.assertInvariants();
            return old;
        }

        const FindResult = struct {
            index: usize,
            found: bool,
        };

        fn findIndex(self: *const Self, key: K) FindResult {
            var lo: usize = 0;
            var hi: usize = self.entries.items.len;
            // Capacity invariant: binary search range is always within allocated bounds.
            assert(hi <= self.entries.capacity);
            const max_steps: usize = self.entries.items.len + 1;
            var steps: usize = 0;
            while (lo < hi and steps < max_steps) : (steps += 1) {
                const mid = lo + (hi - lo) / 2;
                switch (compareKeys(self.entries.items[mid].key, key)) {
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                    .eq => return .{ .index = mid, .found = true },
                }
            }
            // Postcondition: binary search terminates within the expected step bound.
            assert(steps <= max_steps);
            return .{ .index = lo, .found = false };
        }

        fn compareKeys(a: K, b: K) std.math.Order {
            if (@hasDecl(Cmp, "less")) {
                const less_fn = Cmp.less;
                if (less_fn(a, b)) return .lt;
                if (less_fn(b, a)) return .gt;
                return .eq;
            }
            return std.math.order(a, b);
        }

        fn assertInvariants(self: *const Self) void {
            const list = self.entries.items;
            if (list.len <= 1) return;

            var i: usize = 1;
            while (i < list.len) : (i += 1) {
                assert(compareKeys(list[i - 1].key, list[i].key) == .lt);
            }
        }
    };
}

test "sorted vec map keeps deterministic key order" {
    // Goal: verify insertion order is normalized to sorted key order.
    // Method: insert unsorted keys and assert internal order by value mapping.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(std.testing.allocator, .{});
    defer m.deinit();
    try m.put(10, 1);
    try m.put(5, 2);
    try m.put(7, 3);
    assert(m.len() == 3);
    try std.testing.expectEqual(@as(u32, 2), m.entries.items[0].value);
    try std.testing.expectEqual(@as(u32, 3), m.entries.items[1].value);
    try std.testing.expectEqual(@as(u32, 1), m.entries.items[2].value);
}

test "sorted vec map put updates existing key" {
    // Goal: ensure put overwrites existing keys without duplication.
    // Method: write same key twice and confirm len stays one.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(std.testing.allocator, .{});
    defer m.deinit();
    try m.put(3, 100);
    try m.put(3, 200);
    assert(m.len() == 1);
    try std.testing.expectEqual(@as(u32, 200), m.get(3).?.*);
}

test "sorted vec map remove maintains order" {
    // Goal: remove must preserve sorted order of remaining keys.
    // Method: remove middle key and validate neighbors and missing lookup.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(std.testing.allocator, .{});
    defer m.deinit();
    try m.put(1, 10);
    try m.put(2, 20);
    try m.put(3, 30);

    const removed = try m.remove(2);
    try std.testing.expectEqual(@as(u32, 20), removed);
    assert(m.len() == 2);
    try std.testing.expect(m.get(2) == null);
    try std.testing.expectEqual(@as(u32, 10), m.get(1).?.*);
    try std.testing.expectEqual(@as(u32, 30), m.get(3).?.*);
}

test "sorted vec map remove missing key returns NotFound" {
    // Goal: invalid-data removal must return a precise error.
    // Method: remove a key never inserted and assert NotFound.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(std.testing.allocator, .{});
    defer m.deinit();
    try m.put(1, 10);
    try std.testing.expectError(error.NotFound, m.remove(99));
}

test "sorted vec map honors custom comparator" {
    // Goal: verify comparator override path is active.
    // Method: use descending comparator and assert reversed key order.
    const Desc = struct {
        pub fn less(a: u32, b: u32) bool {
            return a > b;
        }
    };
    var m = try SortedVecMap(u32, u32, Desc).init(std.testing.allocator, .{});
    defer m.deinit();
    try m.put(1, 10);
    try m.put(3, 30);
    try m.put(2, 20);

    try std.testing.expectEqual(@as(u32, 3), m.entries.items[0].key);
    try std.testing.expectEqual(@as(u32, 2), m.entries.items[1].key);
    try std.testing.expectEqual(@as(u32, 1), m.entries.items[2].key);
}
