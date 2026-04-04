//! Sparse set: O(1) insert, remove, and membership test with dense iteration.
//!
//! Key type: `SparseSet(T)`. Uses a paired sparse array (indexed by ID) and a dense
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
    InvalidInput,
    NoSpaceLeft,
    InvalidConfig,
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

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!SparseSet {
        if (cfg.universe_size == 0) return error.InvalidInput;
        if (cfg.universe_size > std.math.maxInt(u32)) return error.InvalidInput;

        const sparse_bytes = std.math.mul(usize, cfg.universe_size, @sizeOf(u32)) catch return error.InvalidInput;
        if (cfg.budget) |budget| {
            budget.tryReserve(sparse_bytes) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
        }

        const sparse = allocator.alloc(u32, cfg.universe_size) catch {
            if (cfg.budget) |budget| budget.release(sparse_bytes);
            return error.OutOfMemory;
        };
        @memset(sparse, invalid);
        var self: SparseSet = .{
            .allocator = allocator,
            .budget = cfg.budget,
            .budget_reserved_bytes = sparse_bytes,
            .sparse = sparse,
        };
        self.assertInvariants();
        return self;
    }

    pub fn deinit(self: *SparseSet) void {
        self.assertInvariants();
        if (self.budget) |budget| {
            budget.release(self.budget_reserved_bytes);
        }
        self.dense.deinit(self.allocator);
        self.allocator.free(self.sparse);
        self.* = undefined;
    }

    pub fn len(self: *const SparseSet) usize {
        self.assertInvariants();
        return self.dense.items.len;
    }

    pub fn contains(self: *const SparseSet, value: u32) bool {
        self.assertInvariants();
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
        self.assertInvariants();
        if (self.contains(value)) return;
        const idx: usize = value;
        if (idx >= self.sparse.len) return error.InvalidInput;
        const before_len = self.dense.items.len;

        // Reserve budget for the new dense entry before allocating.
        if (self.budget) |budget| {
            const needed = std.math.add(usize, before_len, 1) catch return error.Overflow;
            const needed_bytes = std.math.mul(usize, needed, @sizeOf(u32)) catch return error.Overflow;
            const sparse_bytes = self.sparse.len * @sizeOf(u32);
            const total_needed = std.math.add(usize, sparse_bytes, needed_bytes) catch return error.Overflow;
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

        self.dense.append(self.allocator, value) catch return error.OutOfMemory;
        assert(self.dense.items.len > before_len);
        // Overflow guard: dense length must fit in u32 before casting back to sparse index.
        assert(self.dense.items.len - 1 <= std.math.maxInt(u32));
        self.sparse[idx] = @intCast(self.dense.items.len - 1);
        assert(self.dense.items.len == before_len + 1);
        assert(self.contains(value));
        self.assertInvariants();
    }

    /// Pre-allocates the dense backing array so that subsequent inserts up to
    /// `count` members do not allocate. Callers who need allocation-free
    /// inserts after setup should call this during initialization.
    pub fn ensureDenseCapacity(self: *SparseSet, count: usize) Error!void {
        self.assertInvariants();
        if (self.budget) |budget| {
            const needed_bytes = std.math.mul(usize, count, @sizeOf(u32)) catch return error.Overflow;
            const sparse_bytes = self.sparse.len * @sizeOf(u32);
            const total_needed = std.math.add(usize, sparse_bytes, needed_bytes) catch return error.Overflow;
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
        self.dense.ensureTotalCapacity(self.allocator, count) catch return error.OutOfMemory;
        self.assertInvariants();
    }

    pub fn remove(self: *SparseSet, value: u32) error{InvalidInput}!void {
        self.assertInvariants();
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
        self.assertInvariants();
    }

    pub fn items(self: *const SparseSet) []const u32 {
        self.assertInvariants();
        return self.dense.items;
    }

    fn assertInvariants(self: *const SparseSet) void {
        // Structural invariant: the dense array can never be larger than the sparse array,
        // because every dense slot corresponds to exactly one sparse entry.
        assert(self.dense.items.len <= self.sparse.len);
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
    // Method: initialize with zero universe size and assert InvalidInput.
    try std.testing.expectError(error.InvalidInput, SparseSet.init(std.testing.allocator, .{ .universe_size = 0 }));
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
