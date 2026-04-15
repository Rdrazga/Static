//! Sorted vector map: key-value store backed by a sorted array with binary search.
//!
//! Key type: `SortedVecMap(K, V)`. Suitable for small maps (< ~64 entries) where
//! cache locality of a flat array outweighs the O(N) insertion cost. Iteration is
//! in key order.
//!
//! `Cmp.less` may use either `fn(a: K, b: K) bool` or
//! `fn(a: *const K, b: *const K) bool`. Borrowed lookup helpers are provided so
//! larger keys do not need to be copied for routine lookup and removal.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const testing = std.testing;
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
    comptime validateLessSignature(K, Cmp);
    return struct {
        const Self = @This();
        const Entry = struct { key: K, value: V };

        pub const Key = K;
        pub const Value = V;
        pub const Compare = Cmp;
        pub const GetOrPutResult = struct {
            value_ptr: *V,
            found_existing: bool,
        };
        pub const Config = struct {
            initial_capacity: u32 = 0,
            budget: ?*memory.budget.Budget,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        budget_reserved_capacity: usize = 0,
        entries: std.ArrayListUnmanaged(Entry) = .empty,

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

        /// Grows the entry backing array to at least `required` capacity using
        /// geometric growth. Budget tracks actual allocated capacity so that
        /// budget accounting matches real memory usage.
        fn ensureEntryGrowth(self: *Self, required: usize) Error!void {
            if (required <= self.entries.capacity) return;

            const old_capacity = self.entries.capacity;
            const candidate = if (old_capacity == 0)
                required
            else blk: {
                const doubled = std.math.mul(usize, old_capacity, 2) catch return error.Overflow;
                break :blk @max(required, doubled);
            };

            const old_budget = self.budget_reserved_capacity;
            try self.ensureBudgetCapacity(candidate);

            self.entries.ensureTotalCapacityPrecise(self.allocator, candidate) catch {
                if (self.budget) |budget| {
                    if (self.budget_reserved_capacity > old_budget) {
                        // Safety: both capacities were validated on the forward path.
                        const rollback = (entryBytesForCapacity(self.budget_reserved_capacity) catch unreachable) -
                            (entryBytesForCapacity(old_budget) catch unreachable);
                        budget.release(rollback);
                        self.budget_reserved_capacity = old_budget;
                    }
                }
                return error.OutOfMemory;
            };
            assert(self.entries.capacity >= candidate);
        }

        pub fn init(allocator: std.mem.Allocator, config: Config) Error!Self {
            var self: Self = .{
                .allocator = allocator,
                .budget = config.budget,
            };
            if (config.initial_capacity > 0) {
                try self.ensureBudgetCapacity(config.initial_capacity);
                self.entries.ensureTotalCapacityPrecise(allocator, config.initial_capacity) catch {
                    if (self.budget) |budget| {
                        // Safety: initial_capacity is u32; product fits usize.
                        const bytes = entryBytesForCapacity(config.initial_capacity) catch unreachable;
                        budget.release(bytes);
                        self.budget_reserved_capacity = 0;
                    }
                    return error.OutOfMemory;
                };
            }
            self.assertFullInvariants();
            return self;
        }

        /// Shrinks backing capacity to match the current logical length.
        pub fn shrinkToFit(self: *Self) void {
            self.assertStructuralInvariants();
            const old_capacity = self.entries.capacity;
            self.entries.shrinkAndFree(self.allocator, self.entries.items.len);
            const new_capacity = self.entries.capacity;
            if (self.budget != null and new_capacity < old_capacity) {
                // Safety: both capacities were live allocations; product fits usize.
                const released = (entryBytesForCapacity(old_capacity) catch unreachable) -
                    (entryBytesForCapacity(new_capacity) catch unreachable);
                self.budget.?.release(released);
                self.budget_reserved_capacity = new_capacity;
            }
            self.assertFullInvariants();
        }

        /// Creates an independent copy with its own backing memory.
        pub fn clone(self: *const Self) Error!Self {
            self.assertFullInvariants();
            const cap = self.entries.capacity;
            const len_val = self.entries.items.len;

            if (cap == 0) {
                return Self{
                    .allocator = self.allocator,
                    .budget = self.budget,
                };
            }

            if (self.budget) |budget| {
                const bytes = entryBytesForCapacity(cap) catch return error.Overflow;
                budget.tryReserve(bytes) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.InvalidConfig => return error.InvalidConfig,
                    error.Overflow => return error.Overflow,
                };
            }

            const new_buf = self.allocator.alloc(Entry, cap) catch {
                if (self.budget) |budget| {
                    // Safety: cap was the source capacity; product fits usize.
                    const bytes = entryBytesForCapacity(cap) catch unreachable;
                    budget.release(bytes);
                }
                return error.OutOfMemory;
            };
            @memcpy(new_buf[0..len_val], self.entries.items);

            // Manual ArrayListUnmanaged construction: std.ArrayListUnmanaged
            // does not expose a clone or init-from-buffer API, so we must set
            // .items and .capacity directly. This couples to the stdlib type's
            // internal layout. Revisit if the layout changes.
            assert(len_val <= cap);
            var result: Self = .{
                .allocator = self.allocator,
                .budget = self.budget,
                .budget_reserved_capacity = self.budget_reserved_capacity,
                .entries = .{
                    .items = new_buf[0..len_val],
                    .capacity = cap,
                },
            };
            result.assertFullInvariants();
            return result;
        }

        pub fn deinit(self: *Self) void {
            self.assertFullInvariants();
            if (self.budget) |budget| {
                // Safety: budget_reserved_capacity was validated at reservation time.
                const bytes = entryBytesForCapacity(self.budget_reserved_capacity) catch unreachable;
                budget.release(bytes);
            }
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            self.assertStructuralInvariants();
            return self.entries.items.len;
        }

        pub const IterEntry = struct {
            key_ptr: *const K,
            value_ptr: *V,
        };

        pub const ConstIterEntry = struct {
            key_ptr: *const K,
            value_ptr: *const V,
        };

        pub const Iterator = struct {
            entries: []Entry,
            index: usize = 0,

            pub fn next(self: *Iterator) ?IterEntry {
                if (self.index >= self.entries.len) return null;
                const index = self.index;
                self.index += 1;
                return .{
                    .key_ptr = &self.entries[index].key,
                    .value_ptr = &self.entries[index].value,
                };
            }
        };

        pub const ConstIterator = struct {
            entries: []const Entry,
            index: usize = 0,

            pub fn next(self: *ConstIterator) ?ConstIterEntry {
                if (self.index >= self.entries.len) return null;
                const index = self.index;
                self.index += 1;
                return .{
                    .key_ptr = &self.entries[index].key,
                    .value_ptr = &self.entries[index].value,
                };
            }
        };

        /// Returns an iterator over entries in sorted key order.
        /// Keys stay immutable through the iterator so callers cannot break
        /// the ordering invariant by mutating them in place.
        pub fn iterator(self: *Self) Iterator {
            self.assertStructuralInvariants();
            return .{ .entries = self.entries.items };
        }

        /// Returns a read-only iterator over entries in sorted key order.
        pub fn iteratorConst(self: *const Self) ConstIterator {
            self.assertStructuralInvariants();
            return .{ .entries = self.entries.items };
        }

        pub fn get(self: *Self, key: K) ?*V {
            const lookup_key = key;
            return self.getBorrowed(&lookup_key);
        }

        pub fn getBorrowed(self: *Self, key: *const K) ?*V {
            self.assertStructuralInvariants();
            const search = self.findIndexBorrowed(key);
            if (!search.found) return null;
            assert(search.index < self.entries.items.len);
            return &self.entries.items[search.index].value;
        }

        pub fn getConst(self: *const Self, key: K) ?*const V {
            const lookup_key = key;
            return self.getConstBorrowed(&lookup_key);
        }

        pub fn getConstBorrowed(self: *const Self, key: *const K) ?*const V {
            self.assertStructuralInvariants();
            const search = self.findIndexBorrowed(key);
            if (!search.found) return null;
            assert(search.index < self.entries.items.len);
            return &self.entries.items[search.index].value;
        }

        pub fn contains(self: *const Self, key: K) bool {
            const lookup_key = key;
            return self.containsBorrowed(&lookup_key);
        }

        pub fn containsBorrowed(self: *const Self, key: *const K) bool {
            self.assertStructuralInvariants();
            return self.findIndexBorrowed(key).found;
        }

        /// Resets the map to empty without releasing backing memory or budget.
        /// Capacity and budget remain unchanged.
        pub fn clear(self: *Self) void {
            self.assertStructuralInvariants();
            self.entries.clearRetainingCapacity();
            assert(self.entries.items.len == 0);
            self.assertFullInvariants();
        }

        pub fn put(self: *Self, key: K, value: V) Error!void {
            self.assertStructuralInvariants();
            const search = self.findIndexBorrowed(&key);
            if (search.found) {
                self.entries.items[search.index].value = value;
                self.assertFullInvariants();
                return;
            }
            _ = try self.insertAtSearch(search, key, value);
            self.assertFullInvariants();
        }

        /// Returns the existing value pointer when `key` is already present, or
        /// inserts `default_value` and returns a pointer to the new slot.
        /// Any later structural mutation invalidates the returned pointer.
        pub fn getOrPut(self: *Self, key: K, default_value: V) Error!GetOrPutResult {
            self.assertStructuralInvariants();
            const search = self.findIndexBorrowed(&key);
            if (search.found) {
                assert(search.index < self.entries.items.len);
                return .{
                    .value_ptr = &self.entries.items[search.index].value,
                    .found_existing = true,
                };
            }

            const value_ptr = try self.insertAtSearch(search, key, default_value);
            self.assertFullInvariants();
            return .{
                .value_ptr = value_ptr,
                .found_existing = false,
            };
        }

        pub fn remove(self: *Self, key: K) Error!V {
            const lookup_key = key;
            return self.removeBorrowed(&lookup_key);
        }

        pub fn removeBorrowed(self: *Self, key: *const K) Error!V {
            self.assertStructuralInvariants();
            const search = self.findIndexBorrowed(key);
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
            self.assertFullInvariants();
            return old;
        }

        pub fn removeOrNull(self: *Self, key: K) ?V {
            const lookup_key = key;
            return self.removeOrNullBorrowed(&lookup_key);
        }

        pub fn removeOrNullBorrowed(self: *Self, key: *const K) ?V {
            self.assertStructuralInvariants();
            const search = self.findIndexBorrowed(key);
            if (!search.found) return null;
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
            self.assertFullInvariants();
            return old;
        }

        const FindResult = struct {
            index: usize,
            found: bool,
        };

        fn insertAtSearch(self: *Self, search: FindResult, key: K, value: V) Error!*V {
            assert(!search.found);

            // Reserve budget and backing capacity before mutating.
            const needed_capacity = std.math.add(usize, self.entries.items.len, 1) catch return error.Overflow;
            try self.ensureEntryGrowth(needed_capacity);

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
            return &self.entries.items[search.index].value;
        }

        fn findIndex(self: *const Self, key: K) FindResult {
            const lookup_key = key;
            return self.findIndexBorrowed(&lookup_key);
        }

        fn findIndexBorrowed(self: *const Self, key: *const K) FindResult {
            var lo: usize = 0;
            var hi: usize = self.entries.items.len;
            // Capacity invariant: binary search range is always within allocated bounds.
            assert(hi <= self.entries.capacity);
            const max_steps: usize = if (self.entries.items.len == 0) 1 else @as(usize, std.math.log2(self.entries.items.len)) + 2;
            var steps: usize = 0;
            while (lo < hi and steps < max_steps) : (steps += 1) {
                const mid = lo + (hi - lo) / 2;
                switch (compareKeysBorrowed(&self.entries.items[mid].key, key)) {
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
            return compareKeysBorrowed(&a, &b);
        }

        fn compareKeysBorrowed(a: *const K, b: *const K) std.math.Order {
            if (@hasDecl(Cmp, "less")) {
                if (lessKeys(a, b)) return .lt;
                if (lessKeys(b, a)) return .gt;
                return .eq;
            }
            return std.math.order(a.*, b.*);
        }

        fn lessKeys(a: *const K, b: *const K) bool {
            if (comptime cmpLessTakesBorrowed(K, Cmp)) return Cmp.less(a, b);
            return Cmp.less(a.*, b.*);
        }

        /// O(1) structural check: entry count within capacity.
        fn assertStructuralInvariants(self: *const Self) void {
            assert(self.entries.items.len <= self.entries.capacity);
            assert(self.entries.capacity <= std.math.maxInt(u32));
        }

        /// O(n) full validation: verifies strict sorted order of all entries.
        /// Called only after mutations (put, remove) and at init/deinit.
        fn assertFullInvariants(self: *const Self) void {
            if (!std.debug.runtime_safety) return;
            self.assertStructuralInvariants();
            const list = self.entries.items;
            if (list.len <= 1) return;

            var i: usize = 1;
            while (i < list.len) : (i += 1) {
                assert(compareKeysBorrowed(&list[i - 1].key, &list[i].key) == .lt);
            }
        }
    };
}

fn validateLessSignature(comptime K: type, comptime Cmp: type) void {
    if (!@hasDecl(Cmp, "less")) return;

    const less_info = @typeInfo(@TypeOf(Cmp.less));
    if (less_info != .@"fn") @compileError("Cmp.less must be a function");
    const less_fn = less_info.@"fn";
    if (less_fn.params.len != 2) {
        @compileError("Cmp.less must have signature `fn(a: K, b: K) bool` or `fn(a: *const K, b: *const K) bool`");
    }
    const p0 = less_fn.params[0].type orelse @compileError("Cmp.less parameter 0 must have a concrete type");
    const p1 = less_fn.params[1].type orelse @compileError("Cmp.less parameter 1 must have a concrete type");
    const ret = less_fn.return_type orelse @compileError("Cmp.less must have a concrete return type");
    if (ret != bool) @compileError("Cmp.less must return bool");

    const uses_value_keys = p0 == K and p1 == K;
    const uses_borrowed_keys = p0 == *const K and p1 == *const K;
    if (!uses_value_keys and !uses_borrowed_keys) {
        @compileError("Cmp.less must have signature `fn(a: K, b: K) bool` or `fn(a: *const K, b: *const K) bool`");
    }
}

fn cmpLessTakesBorrowed(comptime K: type, comptime Cmp: type) bool {
    const less_info = @typeInfo(@TypeOf(Cmp.less));
    const less_fn = less_info.@"fn";
    return less_fn.params[0].type.? == *const K;
}

test "sorted vec map keeps deterministic key order" {
    // Goal: verify insertion order is normalized to sorted key order.
    // Method: insert unsorted keys and assert iterator order by key/value mapping.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();
    try m.put(10, 1);
    try m.put(5, 2);
    try m.put(7, 3);
    assert(m.len() == 3);

    const expected_keys = [_]u32{ 5, 7, 10 };
    const expected_values = [_]u32{ 2, 3, 1 };
    var index: usize = 0;
    var it = m.iteratorConst();
    while (it.next()) |entry| : (index += 1) {
        try testing.expectEqual(expected_keys[index], entry.key_ptr.*);
        try testing.expectEqual(expected_values[index], entry.value_ptr.*);
    }
    try testing.expectEqual(expected_keys.len, index);
}

test "sorted vec map put updates existing key" {
    // Goal: ensure put overwrites existing keys without duplication.
    // Method: write same key twice and confirm len stays one.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();
    try m.put(3, 100);
    try m.put(3, 200);
    assert(m.len() == 1);
    try testing.expectEqual(@as(u32, 200), m.get(3).?.*);
}

test "sorted vec map remove maintains order" {
    // Goal: remove must preserve sorted order of remaining keys.
    // Method: remove middle key and validate neighbors and missing lookup.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();
    try m.put(1, 10);
    try m.put(2, 20);
    try m.put(3, 30);

    const removed = try m.remove(2);
    try testing.expectEqual(@as(u32, 20), removed);
    assert(m.len() == 2);
    try testing.expect(m.get(2) == null);
    try testing.expectEqual(@as(u32, 10), m.get(1).?.*);
    try testing.expectEqual(@as(u32, 30), m.get(3).?.*);
}

test "sorted vec map remove missing key returns NotFound" {
    // Goal: invalid-data removal must return a precise error.
    // Method: remove a key never inserted and assert NotFound.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();
    try m.put(1, 10);
    try testing.expectError(error.NotFound, m.remove(99));
}

test "sorted vec map honors custom comparator" {
    // Goal: verify comparator override path is active.
    // Method: use descending comparator and assert reversed key order.
    const Desc = struct {
        pub fn less(a: u32, b: u32) bool {
            return a > b;
        }
    };
    var m = try SortedVecMap(u32, u32, Desc).init(testing.allocator, .{ .budget = null });
    defer m.deinit();
    try m.put(1, 10);
    try m.put(3, 30);
    try m.put(2, 20);

    const expected_keys = [_]u32{ 3, 2, 1 };
    var index: usize = 0;
    var it = m.iteratorConst();
    while (it.next()) |entry| : (index += 1) {
        try testing.expectEqual(expected_keys[index], entry.key_ptr.*);
    }
    try testing.expectEqual(expected_keys.len, index);
}

test "sorted vec map supports borrowed lookup and pointer comparator signatures" {
    const Key = struct {
        hi: u64,
        lo: u64,
        tag: u32,
        pad: u32 = 0,
    };
    const PtrCmp = struct {
        pub fn less(a: *const Key, b: *const Key) bool {
            if (a.hi != b.hi) return a.hi < b.hi;
            if (a.lo != b.lo) return a.lo < b.lo;
            return a.tag < b.tag;
        }
    };

    var m = try SortedVecMap(Key, u32, PtrCmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();

    try m.put(.{ .hi = 2, .lo = 0, .tag = 9 }, 20);
    try m.put(.{ .hi = 1, .lo = 5, .tag = 7 }, 10);

    const lookup = Key{ .hi = 1, .lo = 5, .tag = 7 };
    try testing.expect(m.containsBorrowed(&lookup));
    try testing.expectEqual(@as(u32, 10), m.getConstBorrowed(&lookup).?.*);
    try testing.expectEqual(@as(u32, 10), try m.removeBorrowed(&lookup));
    try testing.expect(!m.containsBorrowed(&lookup));
}

test "sorted vec map iterator allows value mutation while keeping keys const" {
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();

    try m.put(1, 10);
    try m.put(2, 20);

    var it = m.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.* += 1;
    }

    try testing.expectEqual(@as(u32, 11), m.getConst(1).?.*);
    try testing.expectEqual(@as(u32, 21), m.getConst(2).?.*);
}

test "sorted vec map getOrPut reports whether insertion happened" {
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();

    const inserted = try m.getOrPut(4, 40);
    try testing.expect(!inserted.found_existing);
    inserted.value_ptr.* += 1;

    const existing = try m.getOrPut(4, 99);
    try testing.expect(existing.found_existing);
    try testing.expectEqual(@as(u32, 41), existing.value_ptr.*);
    try testing.expectEqual(@as(usize, 1), m.len());
}

test "sorted vec map removeOrNull keeps strict remove available" {
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();

    try m.put(1, 10);
    try testing.expectEqual(@as(?u32, 10), m.removeOrNull(1));
    try testing.expectEqual(@as(?u32, null), m.removeOrNull(1));
    try testing.expectError(error.NotFound, m.remove(1));
}

test "sorted vec map clear resets length and allows reuse" {
    // Goal: confirm clear empties the map while preserving capacity.
    // Method: insert values, clear, verify empty, then reinsert.
    const Cmp = struct {};
    var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = null });
    defer m.deinit();
    try m.put(1, 10);
    try m.put(2, 20);
    assert(m.len() == 2);

    m.clear();
    try testing.expectEqual(@as(usize, 0), m.len());
    try testing.expect(m.get(1) == null);

    try m.put(3, 30);
    try testing.expectEqual(@as(usize, 1), m.len());
    try testing.expectEqual(@as(u32, 30), m.get(3).?.*);
}

test "sorted vec map budget tracks capacity" {
    // Goal: verify budget is reserved on insert and fully released on deinit.
    // Method: create with budget, insert values, verify used > 0, deinit, verify zero.
    const Cmp = struct {};
    const entry_size = @sizeOf(SortedVecMap(u32, u32, Cmp).Entry);
    var budget = try memory.budget.Budget.init(entry_size * 16);

    {
        var m = try SortedVecMap(u32, u32, Cmp).init(testing.allocator, .{ .budget = &budget });
        defer m.deinit();

        try m.put(1, 10);
        try m.put(2, 20);
        try testing.expect(budget.used() > 0);
    }
    try testing.expectEqual(@as(u64, 0), budget.used());
}
