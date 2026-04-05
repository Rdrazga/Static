//! Sparse set: O(1) insert, remove, and membership test with dense iteration.
//!
//! Key type: `SparseSet`. Uses a paired sparse array (indexed by ID) and a dense
//! array (packed values). Membership tests and mutations are O(1); iteration over
//! all members is cache-friendly via the dense array.
//!
//! IDs must be integers in the range [0, capacity). The capacity is fixed at init.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const memory = @import("static_memory");
const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    InvalidConfig,
    InvalidInput,
    Overflow,
};

pub const SparseSet = struct {
    const invalid = std.math.maxInt(u32);

    allocator: std.mem.Allocator,
    budget: ?*memory.budget.Budget,
    budget_reserved_bytes: usize = 0,
    sparse: []u32,
    dense: std.ArrayListUnmanaged(u32) = .{},

    pub const Config = struct {
        universe_size: usize,
        budget: ?*memory.budget.Budget = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!SparseSet {
        if (config.universe_size == 0) return error.InvalidConfig;
        if (config.universe_size > std.math.maxInt(u32)) return error.InvalidConfig;

        const sparse_bytes = std.math.mul(usize, config.universe_size, @sizeOf(u32)) catch return error.InvalidConfig;
        if (config.budget) |budget| {
            budget.tryReserve(sparse_bytes) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
        }

        const sparse = allocator.alloc(u32, config.universe_size) catch {
            if (config.budget) |budget| budget.release(sparse_bytes);
            return error.OutOfMemory;
        };
        @memset(sparse, invalid);
        var self: SparseSet = .{
            .allocator = allocator,
            .budget = config.budget,
            .budget_reserved_bytes = sparse_bytes,
            .sparse = sparse,
        };
        self.assertFullInvariants();
        return self;
    }

    pub fn deinit(self: *SparseSet) void {
        self.assertFullInvariants();
        if (self.budget) |budget| {
            budget.release(self.budget_reserved_bytes);
        }
        self.dense.deinit(self.allocator);
        self.allocator.free(self.sparse);
        self.* = undefined;
    }

    /// Creates an independent copy with its own backing memory.
    pub fn clone(self: *const SparseSet) Error!SparseSet {
        self.assertStructuralInvariants();
        const sparse_bytes = std.math.mul(usize, self.sparse.len, @sizeOf(u32)) catch return error.Overflow;
        const dense_bytes = std.math.mul(usize, self.dense.capacity, @sizeOf(u32)) catch return error.Overflow;
        const total_bytes = std.math.add(usize, sparse_bytes, dense_bytes) catch return error.Overflow;

        if (self.budget) |budget| {
            budget.tryReserve(total_bytes) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
        }

        const new_sparse = self.allocator.alloc(u32, self.sparse.len) catch {
            if (self.budget) |budget| budget.release(total_bytes);
            return error.OutOfMemory;
        };
        errdefer {
            self.allocator.free(new_sparse);
            if (self.budget) |budget| budget.release(total_bytes);
        }
        @memcpy(new_sparse, self.sparse);

        const dense_cap = self.dense.capacity;
        const dense_len = self.dense.items.len;
        var new_dense: std.ArrayListUnmanaged(u32) = .{};
        if (dense_cap > 0) {
            new_dense.ensureTotalCapacityPrecise(self.allocator, dense_cap) catch return error.OutOfMemory;
            @memcpy(new_dense.items.ptr[0..dense_len], self.dense.items);
            new_dense.items.len = dense_len;
        }

        var result: SparseSet = .{
            .allocator = self.allocator,
            .budget = self.budget,
            .budget_reserved_bytes = total_bytes,
            .sparse = new_sparse,
            .dense = new_dense,
        };
        result.assertFullInvariants();
        return result;
    }

    pub fn len(self: *const SparseSet) usize {
        self.assertStructuralInvariants();
        return self.dense.items.len;
    }

    pub fn contains(self: *const SparseSet, value: u32) bool {
        self.assertStructuralInvariants();
        const idx: usize = value;
        if (idx >= self.sparse.len) return false;
        const dense_idx = self.sparse[idx];
        if (dense_idx == invalid) return false;
        const di: usize = dense_idx;
        return di < self.dense.items.len and self.dense.items[di] == value;
    }

    /// Inserts `value` into the set. May allocate to grow the dense backing
    /// array, so this can fail with `OutOfMemory` even for in-universe values.
    /// Use `ensureDenseCapacity` during setup to pre-allocate if allocation-free
    /// inserts are required after initialization.
    pub fn insert(self: *SparseSet, value: u32) Error!void {
        self.assertStructuralInvariants();
        if (self.contains(value)) return;
        const idx: usize = value;
        if (idx >= self.sparse.len) return error.InvalidInput;
        const before_len = self.dense.items.len;

        const needed = std.math.add(usize, before_len, 1) catch return error.Overflow;
        try self.ensureDenseGrowth(needed);

        self.dense.appendAssumeCapacity(value);
        assert(self.dense.items.len > before_len);
        // Overflow guard: dense length must fit in u32 before casting back to sparse index.
        assert(self.dense.items.len - 1 <= std.math.maxInt(u32));
        self.sparse[idx] = @intCast(self.dense.items.len - 1);
        assert(self.dense.items.len == before_len + 1);
        assert(self.contains(value));
        self.assertFullInvariants();
    }

    /// Pre-allocates the dense backing array so that subsequent inserts up to
    /// `count` members do not allocate. Callers who need allocation-free
    /// inserts after setup should call this during initialization.
    pub fn ensureDenseCapacity(self: *SparseSet, count: usize) Error!void {
        self.assertStructuralInvariants();
        try self.ensureDenseGrowth(count);
        self.assertStructuralInvariants();
    }

    /// Grows the dense backing array to at least `required` capacity using
    /// geometric growth. Budget tracks the actual allocated capacity (not
    /// logical length) so that budget accounting matches real memory usage.
    fn ensureDenseGrowth(self: *SparseSet, required: usize) Error!void {
        if (required <= self.dense.capacity) return;

        const old_capacity = self.dense.capacity;
        const candidate = if (old_capacity == 0)
            required
        else blk: {
            const doubled = std.math.mul(usize, old_capacity, 2) catch return error.Overflow;
            break :blk @max(required, doubled);
        };

        const sparse_bytes = std.math.mul(usize, self.sparse.len, @sizeOf(u32)) catch return error.Overflow;

        if (self.budget) |budget| {
            const new_dense_bytes = std.math.mul(usize, candidate, @sizeOf(u32)) catch return error.Overflow;
            const total_needed = std.math.add(usize, sparse_bytes, new_dense_bytes) catch return error.Overflow;
            if (total_needed > self.budget_reserved_bytes) {
                const delta = total_needed - self.budget_reserved_bytes;
                budget.tryReserve(delta) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.InvalidConfig => return error.InvalidConfig,
                    error.Overflow => return error.Overflow,
                };
                self.budget_reserved_bytes = total_needed;
            }
        }

        self.dense.ensureTotalCapacityPrecise(self.allocator, candidate) catch {
            if (self.budget) |budget| {
                // Safety: old_capacity was a live allocation; products fit usize.
                const old_dense_bytes = std.math.mul(usize, old_capacity, @sizeOf(u32)) catch unreachable;
                const old_total = std.math.add(usize, sparse_bytes, old_dense_bytes) catch unreachable;
                if (self.budget_reserved_bytes > old_total) {
                    budget.release(self.budget_reserved_bytes - old_total);
                    self.budget_reserved_bytes = old_total;
                }
            }
            return error.OutOfMemory;
        };
        assert(self.dense.capacity >= candidate);
    }

    /// Resets the set to empty without releasing backing memory or budget.
    /// Capacity and budget remain unchanged.
    pub fn clear(self: *SparseSet) void {
        self.assertStructuralInvariants();
        @memset(self.sparse, invalid);
        self.dense.clearRetainingCapacity();
        assert(self.dense.items.len == 0);
        self.assertFullInvariants();
    }

    pub fn remove(self: *SparseSet, value: u32) error{InvalidInput}!void {
        self.assertStructuralInvariants();
        if (!self.contains(value)) return error.InvalidInput;
        const before_len = self.dense.items.len;
        assert(before_len > 0);
        const idx: usize = value;
        const dense_idx_u32 = self.sparse[idx];
        assert(dense_idx_u32 != invalid);
        const dense_idx: usize = dense_idx_u32;
        assert(dense_idx < before_len);
        const last_idx = before_len - 1;
        const last_value = self.dense.items[last_idx];
        self.dense.items[dense_idx] = last_value;
        // Overflow guard: dense_idx must fit in u32 before storing it into the sparse array.
        assert(dense_idx <= std.math.maxInt(u32));
        self.sparse[@as(usize, last_value)] = @intCast(dense_idx);
        _ = self.dense.pop();
        self.sparse[idx] = invalid;
        assert(self.dense.items.len == before_len - 1);
        assert(!self.contains(value));
        self.assertFullInvariants();
    }

    pub fn items(self: *const SparseSet) []const u32 {
        self.assertStructuralInvariants();
        return self.dense.items;
    }

    /// O(1) structural check: dense array cannot exceed sparse array size.
    fn assertStructuralInvariants(self: *const SparseSet) void {
        assert(self.dense.items.len <= self.sparse.len);
    }

    /// O(n) full validation: walks the dense array and verifies every
    /// dense-to-sparse back-reference is consistent. Called only after
    /// mutations (insert, remove) and at init/deinit.
    fn assertFullInvariants(self: *const SparseSet) void {
        self.assertStructuralInvariants();
        var i: usize = 0;
        while (i < self.dense.items.len) : (i += 1) {
            const value = self.dense.items[i];
            assert(value < self.sparse.len);
            assert(self.sparse[value] == i);
        }
    }
};

test "sparse set insert/remove maintains dense mapping" {
    // Goal: verify sparse/dense coherence through insert and remove.
    // Method: insert two values, remove one, then assert survivor remains.
    var s = try SparseSet.init(std.testing.allocator, .{ .universe_size = 16 });
    defer s.deinit();
    try s.insert(3);
    try s.insert(7);
    try std.testing.expect(s.contains(3));
    try std.testing.expect(s.contains(7));
    try s.remove(3);
    try std.testing.expect(!s.contains(3));
    try std.testing.expect(s.contains(7));
}

test "sparse set rejects zero and out-of-range universe" {
    // Goal: reject invalid universe configuration at initialization.
    // Method: initialize with zero universe size and assert InvalidConfig.
    try std.testing.expectError(error.InvalidConfig, SparseSet.init(std.testing.allocator, .{ .universe_size = 0 }));
}

test "sparse set insert idempotent" {
    // Goal: confirm duplicate insertions do not duplicate dense entries.
    // Method: insert same value twice and assert len remains one.
    var s = try SparseSet.init(std.testing.allocator, .{ .universe_size = 8 });
    defer s.deinit();
    try s.insert(4);
    try s.insert(4);
    try std.testing.expectEqual(@as(usize, 1), s.len());
}

test "sparse set remove returns InvalidInput when absent" {
    // Goal: ensure negative-space behavior for removals is explicit.
    // Method: remove value never inserted and assert InvalidInput.
    var s = try SparseSet.init(std.testing.allocator, .{ .universe_size = 8 });
    defer s.deinit();
    try std.testing.expectError(error.InvalidInput, s.remove(2));
}

test "sparse set out-of-universe insert returns InvalidInput" {
    // Goal: reject inserts outside the configured universe.
    // Method: attempt to insert value >= universe_size and assert InvalidInput.
    var s = try SparseSet.init(std.testing.allocator, .{ .universe_size = 4 });
    defer s.deinit();
    try std.testing.expectError(error.InvalidInput, s.insert(10));
}

test "sparse set contains returns false for out-of-universe values" {
    // Goal: out-of-range lookups must fail safely without mutation.
    // Method: query a value outside the universe and assert false.
    var s = try SparseSet.init(std.testing.allocator, .{ .universe_size = 4 });
    defer s.deinit();
    try std.testing.expect(!s.contains(9));
}

test "sparse set clear resets membership and allows reuse" {
    // Goal: confirm clear empties the set while preserving backing memory.
    // Method: insert values, clear, verify empty, then reinsert.
    var s = try SparseSet.init(std.testing.allocator, .{ .universe_size = 8 });
    defer s.deinit();
    try s.insert(3);
    try s.insert(5);
    try std.testing.expectEqual(@as(usize, 2), s.len());

    s.clear();
    try std.testing.expectEqual(@as(usize, 0), s.len());
    try std.testing.expect(!s.contains(3));
    try std.testing.expect(!s.contains(5));

    try s.insert(7);
    try std.testing.expectEqual(@as(usize, 1), s.len());
    try std.testing.expect(s.contains(7));
}

test "sparse set ensureDenseCapacity pre-allocates for inserts" {
    // Goal: verify ensureDenseCapacity prevents allocation during inserts.
    // Method: pre-allocate, then insert up to that count without error.
    var s = try SparseSet.init(std.testing.allocator, .{ .universe_size = 16 });
    defer s.deinit();

    try s.ensureDenseCapacity(4);
    try std.testing.expect(s.dense.capacity >= 4);

    try s.insert(0);
    try s.insert(1);
    try s.insert(2);
    try s.insert(3);
    try std.testing.expectEqual(@as(usize, 4), s.len());
}
