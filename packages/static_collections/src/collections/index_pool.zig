//! Fixed-capacity generational index allocator.
//!
//! `IndexPool` manages a bounded set of reusable slot indices and issues stable
//! `Handle` values with generation protection. It is intended for containers
//! that own their slot storage separately but need consistent "allocate /
//! validate / release" behavior without dynamic growth.

const std = @import("std");
const handle_mod = @import("handle.zig");

pub const Error = error{
    InvalidConfig,
    OutOfMemory,
    NoSpaceLeft,
    NotFound,
};

pub const Config = struct {
    slots_max: u32,
};

pub const Handle = handle_mod.Handle;

pub const IndexPool = struct {
    allocator: std.mem.Allocator,
    generations: []u32,
    occupied: []bool,
    free_stack: []u32,
    free_len: u32,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!IndexPool {
        if (cfg.slots_max == 0) return error.InvalidConfig;

        const generations = allocator.alloc(u32, cfg.slots_max) catch return error.OutOfMemory;
        errdefer allocator.free(generations);
        @memset(generations, 1);

        const occupied = allocator.alloc(bool, cfg.slots_max) catch return error.OutOfMemory;
        errdefer allocator.free(occupied);
        @memset(occupied, false);

        const free_stack = allocator.alloc(u32, cfg.slots_max) catch return error.OutOfMemory;
        errdefer allocator.free(free_stack);
        fillFreeStack(free_stack);

        const self: IndexPool = .{
            .allocator = allocator,
            .generations = generations,
            .occupied = occupied,
            .free_stack = free_stack,
            .free_len = cfg.slots_max,
        };
        self.assertBasicInvariants();
        return self;
    }

    pub fn deinit(self: *IndexPool) void {
        self.assertBasicInvariants();
        self.allocator.free(self.free_stack);
        self.allocator.free(self.occupied);
        self.allocator.free(self.generations);
        self.* = undefined;
    }

    pub fn capacity(self: *const IndexPool) u32 {
        self.assertBasicInvariants();
        std.debug.assert(self.generations.len <= std.math.maxInt(u32));
        return @intCast(self.generations.len);
    }

    pub fn freeCount(self: *const IndexPool) u32 {
        self.assertBasicInvariants();
        return self.free_len;
    }

    pub fn allocate(self: *IndexPool) Error!Handle {
        self.assertBasicInvariants();
        if (self.free_len == 0) return error.NoSpaceLeft;

        self.free_len -= 1;
        const slot_index = self.free_stack[self.free_len];
        std.debug.assert(slot_index < self.occupied.len);
        std.debug.assert(!self.occupied[slot_index]);

        self.occupied[slot_index] = true;
        const generation = self.generations[slot_index];
        std.debug.assert(generation != 0);
        self.assertBasicInvariants();
        return .{
            .index = slot_index,
            .generation = generation,
        };
    }

    pub fn validate(self: *const IndexPool, handle: Handle) Error!u32 {
        self.assertBasicInvariants();
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
        self.assertBasicInvariants();
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
        self.assertBasicInvariants();
        const slot_index = try self.validate(handle);
        std.debug.assert(self.free_len < self.free_stack.len);
        std.debug.assert(self.occupied[slot_index]);

        self.occupied[slot_index] = false;
        self.generations[slot_index] = nextGeneration(self.generations[slot_index]);
        self.free_stack[self.free_len] = slot_index;
        self.free_len += 1;
        self.assertBasicInvariants();
    }

    fn assertBasicInvariants(self: *const IndexPool) void {
        std.debug.assert(self.generations.len == self.occupied.len);
        std.debug.assert(self.generations.len == self.free_stack.len);
        std.debug.assert(self.free_len <= self.free_stack.len);

        std.debug.assert(self.generations.len <= std.math.maxInt(u32));
        const len: u32 = @intCast(self.generations.len);

        var free_count: u32 = 0;
        var free_slot: u32 = 0;
        while (free_slot < self.free_len) : (free_slot += 1) {
            const slot_index = self.free_stack[free_slot];
            std.debug.assert(slot_index < len);
            std.debug.assert(!self.occupied[slot_index]);

            var seen: u32 = 0;
            while (seen < free_slot) : (seen += 1) {
                std.debug.assert(self.free_stack[seen] != slot_index);
            }

            free_count += 1;
        }
        std.debug.assert(free_count == self.free_len);

        var expected_free_count: u32 = 0;
        var slot_index: u32 = 0;
        while (slot_index < len) : (slot_index += 1) {
            if (!self.occupied[slot_index]) {
                expected_free_count += 1;

                var found = false;
                var free_slot_index: u32 = 0;
                while (free_slot_index < self.free_len) : (free_slot_index += 1) {
                    if (self.free_stack[free_slot_index] == slot_index) {
                        found = true;
                        break;
                    }
                }
                std.debug.assert(found);
            }
        }
        std.debug.assert(expected_free_count == self.free_len);
    }
};

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
