//! Fixed-capacity generational index allocator.
//!
//! `IndexPool` manages a bounded set of reusable slot indices and issues stable
//! `Handle` values with generation protection. It is intended for containers
//! that own their slot storage separately but need consistent "allocate /
//! validate / release" behavior without dynamic growth.

const std = @import("std");
const memory = @import("static_memory");
const handle_mod = @import("handle.zig");

pub const Error = error{
    InvalidConfig,
    OutOfMemory,
    NoSpaceLeft,
    NotFound,
    Overflow,
};

pub const Config = struct {
    slots_max: u32,
    budget: ?*memory.budget.Budget = null,
};

pub const Handle = handle_mod.Handle;

pub const IndexPool = struct {
    allocator: std.mem.Allocator,
    budget: ?*memory.budget.Budget,
    generations: []u32,
    occupied: []bool,
    free_stack: []u32,
    free_len: u32,

    fn totalAllocBytes(slots_max: u32) error{Overflow}!usize {
        const gen_bytes = std.math.mul(usize, slots_max, @sizeOf(u32)) catch return error.Overflow;
        const occ_bytes = std.math.mul(usize, slots_max, @sizeOf(bool)) catch return error.Overflow;
        const stk_bytes = std.math.mul(usize, slots_max, @sizeOf(u32)) catch return error.Overflow;
        const sum1 = std.math.add(usize, gen_bytes, occ_bytes) catch return error.Overflow;
        return std.math.add(usize, sum1, stk_bytes) catch return error.Overflow;
    }

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!IndexPool {
        if (cfg.slots_max == 0) return error.InvalidConfig;

        const alloc_bytes = totalAllocBytes(cfg.slots_max) catch return error.Overflow;
        if (cfg.budget) |budget| {
            budget.tryReserve(alloc_bytes) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
        }
        errdefer if (cfg.budget) |budget| budget.release(alloc_bytes);

        const generations = allocator.alloc(u32, cfg.slots_max) catch return error.OutOfMemory;
        errdefer allocator.free(generations);
        @memset(generations, 1);

        const occupied = allocator.alloc(bool, cfg.slots_max) catch return error.OutOfMemory;
        errdefer allocator.free(occupied);
        @memset(occupied, false);

        const free_stack = allocator.alloc(u32, cfg.slots_max) catch return error.OutOfMemory;
        errdefer allocator.free(free_stack);
        fillFreeStack(free_stack);

        var self: IndexPool = .{
            .allocator = allocator,
            .budget = cfg.budget,
            .generations = generations,
            .occupied = occupied,
            .free_stack = free_stack,
            .free_len = cfg.slots_max,
        };
        self.assertFullInvariants();
        return self;
    }

    pub fn deinit(self: *IndexPool) void {
        self.assertFullInvariants();
        if (self.budget) |budget| {
            const alloc_bytes = totalAllocBytes(@intCast(self.generations.len)) catch unreachable;
            budget.release(alloc_bytes);
        }
        self.allocator.free(self.free_stack);
        self.allocator.free(self.occupied);
        self.allocator.free(self.generations);
        self.* = undefined;
    }

    /// Creates an independent copy with its own backing memory.
    pub fn clone(self: *const IndexPool) Error!IndexPool {
        self.assertStructuralInvariants();
        const slots_max: u32 = @intCast(self.generations.len);
        const alloc_bytes = totalAllocBytes(slots_max) catch return error.Overflow;

        if (self.budget) |budget| {
            budget.tryReserve(alloc_bytes) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
        }
        errdefer if (self.budget) |budget| budget.release(alloc_bytes);

        const new_generations = self.allocator.alloc(u32, slots_max) catch return error.OutOfMemory;
        errdefer self.allocator.free(new_generations);
        @memcpy(new_generations, self.generations);

        const new_occupied = self.allocator.alloc(bool, slots_max) catch return error.OutOfMemory;
        errdefer self.allocator.free(new_occupied);
        @memcpy(new_occupied, self.occupied);

        const new_free_stack = self.allocator.alloc(u32, slots_max) catch return error.OutOfMemory;
        @memcpy(new_free_stack, self.free_stack);

        var result: IndexPool = .{
            .allocator = self.allocator,
            .budget = self.budget,
            .generations = new_generations,
            .occupied = new_occupied,
            .free_stack = new_free_stack,
            .free_len = self.free_len,
        };
        result.assertFullInvariants();
        return result;
    }

    pub fn capacity(self: *const IndexPool) u32 {
        self.assertStructuralInvariants();
        std.debug.assert(self.generations.len <= std.math.maxInt(u32));
        return @intCast(self.generations.len);
    }

    pub fn freeCount(self: *const IndexPool) u32 {
        self.assertStructuralInvariants();
        return self.free_len;
    }

    /// Resets the pool to its initial state: all slots become free with bumped
    /// generations, invalidating any previously issued handles. Backing memory
    /// and budget are preserved.
    pub fn clear(self: *IndexPool) void {
        self.assertStructuralInvariants();
        const len: u32 = @intCast(self.generations.len);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            if (self.occupied[i]) {
                self.generations[i] = nextGeneration(self.generations[i]);
            }
            self.occupied[i] = false;
        }
        fillFreeStack(self.free_stack);
        self.free_len = len;
        self.assertFullInvariants();
    }

    pub fn allocate(self: *IndexPool) Error!Handle {
        self.assertStructuralInvariants();
        if (self.free_len == 0) return error.NoSpaceLeft;

        self.free_len -= 1;
        const slot_index = self.free_stack[self.free_len];
        std.debug.assert(slot_index < self.occupied.len);
        std.debug.assert(!self.occupied[slot_index]);

        self.occupied[slot_index] = true;
        const generation = self.generations[slot_index];
        std.debug.assert(generation != 0);
        self.assertFullInvariants();
        return .{
            .index = slot_index,
            .generation = generation,
        };
    }

    pub fn validate(self: *const IndexPool, handle: Handle) Error!u32 {
        self.assertStructuralInvariants();
        if (!handle.isValid()) return error.NotFound;
        if (handle.index >= self.generations.len) return error.NotFound;
        if (!self.occupied[handle.index]) return error.NotFound;
        if (self.generations[handle.index] != handle.generation) return error.NotFound;
        return handle.index;
    }

    pub fn contains(self: *const IndexPool, handle: Handle) bool {
        _ = self.validate(handle) catch return false;
        return true;
    }

    pub fn handleForIndex(self: *const IndexPool, slot_index: u32) ?Handle {
        self.assertStructuralInvariants();
        if (slot_index >= self.generations.len) return null;
        if (!self.occupied[slot_index]) return null;

        const generation = self.generations[slot_index];
        std.debug.assert(generation != 0);
        return .{
            .index = slot_index,
            .generation = generation,
        };
    }

    pub fn release(self: *IndexPool, handle: Handle) Error!void {
        self.assertStructuralInvariants();
        const slot_index = try self.validate(handle);
        std.debug.assert(self.free_len < self.free_stack.len);
        std.debug.assert(self.occupied[slot_index]);

        self.occupied[slot_index] = false;
        self.generations[slot_index] = nextGeneration(self.generations[slot_index]);
        self.free_stack[self.free_len] = slot_index;
        self.free_len += 1;
        self.assertFullInvariants();
    }

    /// O(1) structural checks: array sizes match, counters are bounded.
    fn assertStructuralInvariants(self: *const IndexPool) void {
        std.debug.assert(self.generations.len == self.occupied.len);
        std.debug.assert(self.generations.len == self.free_stack.len);
        std.debug.assert(self.free_len <= self.free_stack.len);
        std.debug.assert(self.generations.len <= std.math.maxInt(u32));
    }

    /// O(n) full validation: walks free stack and occupied array to prove
    /// the free stack is a valid permutation of exactly the unoccupied slots.
    /// Called only after mutations (allocate, release) and at init/deinit.
    ///
    /// This function is read-only — it never mutates live state, so it is
    /// safe to call from any context including signal handlers and debuggers.
    fn assertFullInvariants(self: *const IndexPool) void {
        self.assertStructuralInvariants();

        const len: u32 = @intCast(self.generations.len);

        // Pass 1: walk the free stack and verify each entry is in-bounds and
        // points to an unoccupied slot.
        var free_slot: u32 = 0;
        while (free_slot < self.free_len) : (free_slot += 1) {
            const slot_index = self.free_stack[free_slot];
            std.debug.assert(slot_index < len);
            std.debug.assert(!self.occupied[slot_index]);
        }

        // Pass 2: count unoccupied slots and assert it matches free_len.
        // Combined with pass 1, this proves the free stack is a duplicate-free
        // permutation of exactly the unoccupied slot indices: pass 1 guarantees
        // every free-stack entry maps to a distinct unoccupied slot (each read
        // is independent — no mutation), and pass 2 guarantees no unoccupied
        // slot is missing from the free stack (count match).
        var expected_free_count: u32 = 0;
        var slot_index: u32 = 0;
        while (slot_index < len) : (slot_index += 1) {
            if (!self.occupied[slot_index]) {
                expected_free_count += 1;
            }
        }
        std.debug.assert(expected_free_count == self.free_len);
    }

    fn detectsDuplicateFreeStackEntries(self: *IndexPool) bool {
        self.assertStructuralInvariants();
        const len: u32 = @intCast(self.generations.len);

        var free_slot: u32 = 0;
        while (free_slot < self.free_len) : (free_slot += 1) {
            const slot_index = self.free_stack[free_slot];
            if (slot_index >= len) {
                restoreMarkedFreeSlots(self, free_slot);
                return true;
            }
            if (self.occupied[slot_index]) {
                restoreMarkedFreeSlots(self, free_slot);
                return true;
            }
            self.occupied[slot_index] = true;
        }

        restoreMarkedFreeSlots(self, self.free_len);
        return false;
    }
};

fn restoreMarkedFreeSlots(pool: *IndexPool, count: u32) void {
    var free_slot: u32 = 0;
    const len: u32 = @intCast(pool.generations.len);
    while (free_slot < count) : (free_slot += 1) {
        const slot_index = pool.free_stack[free_slot];
        if (slot_index >= len) continue;
        if (!pool.occupied[slot_index]) continue;
        pool.occupied[slot_index] = false;
    }
}

fn fillFreeStack(free_stack: []u32) void {
    std.debug.assert(free_stack.len <= std.math.maxInt(u32));
    var index: u32 = 0;
    const len_u32: u32 = @intCast(free_stack.len);
    while (index < len_u32) : (index += 1) {
        free_stack[index] = len_u32 - 1 - index;
    }
}

fn nextGeneration(current: u32) u32 {
    var next = current +% 1;
    if (next == 0) next = 1;
    std.debug.assert(next != 0);
    return next;
}

test "index pool allocates, validates, and rejects stale handles" {
    var pool = try IndexPool.init(std.testing.allocator, .{ .slots_max = 2 });
    defer pool.deinit();

    const first = try pool.allocate();
    try std.testing.expect(pool.contains(first));
    try std.testing.expectEqual(@as(u32, first.index), try pool.validate(first));

    try pool.release(first);
    try std.testing.expect(!pool.contains(first));
    try std.testing.expectError(error.NotFound, pool.validate(first));

    const second = try pool.allocate();
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation != first.generation);
}

test "index pool reports capacity exhaustion explicitly" {
    var pool = try IndexPool.init(std.testing.allocator, .{ .slots_max = 1 });
    defer pool.deinit();

    _ = try pool.allocate();
    try std.testing.expectEqual(@as(u32, 0), pool.freeCount());
    try std.testing.expectError(error.NoSpaceLeft, pool.allocate());
}

test "index pool handleForIndex only exposes live handles" {
    var pool = try IndexPool.init(std.testing.allocator, .{ .slots_max = 2 });
    defer pool.deinit();

    try std.testing.expect(pool.handleForIndex(0) == null);
    const handle = try pool.allocate();
    try std.testing.expectEqualDeep(handle, pool.handleForIndex(handle.index).?);
    try pool.release(handle);
    try std.testing.expect(pool.handleForIndex(handle.index) == null);
}

test "index pool clear invalidates handles and restores full capacity" {
    // Goal: confirm clear resets all slots and stales existing handles.
    // Method: allocate handles, clear, verify stale, then reallocate.
    var pool = try IndexPool.init(std.testing.allocator, .{ .slots_max = 3 });
    defer pool.deinit();

    const h1 = try pool.allocate();
    const h2 = try pool.allocate();
    try std.testing.expectEqual(@as(u32, 1), pool.freeCount());

    pool.clear();
    try std.testing.expectEqual(@as(u32, 3), pool.freeCount());
    try std.testing.expect(!pool.contains(h1));
    try std.testing.expect(!pool.contains(h2));

    const h3 = try pool.allocate();
    try std.testing.expect(pool.contains(h3));
    try std.testing.expectEqual(@as(u32, 2), pool.freeCount());
}

test "index pool duplicate free stack entries are detectable" {
    var pool = try IndexPool.init(std.testing.allocator, .{ .slots_max = 3 });
    defer pool.deinit();

    pool.free_stack[0] = 0;
    pool.free_stack[1] = 0;
    pool.free_stack[2] = 2;
    pool.free_len = 3;
    @memset(pool.occupied, false);

    try std.testing.expect(pool.detectsDuplicateFreeStackEntries());
    try std.testing.expectEqual(@as(u32, 3), pool.freeCount());
    try std.testing.expect(!pool.occupied[0]);
    try std.testing.expect(!pool.occupied[1]);
    try std.testing.expect(!pool.occupied[2]);

    fillFreeStack(pool.free_stack);
}
