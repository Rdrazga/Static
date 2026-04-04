//! A bounded bump allocator backed by a single contiguous buffer.
//!
//! Key types: `Arena`, `ArenaError`.
//! Usage pattern: call `Arena.init` with a backing allocator and capacity, use `allocator()` to obtain
//! a `std.mem.Allocator`, call `reset()` to rewind without freeing, and `deinit()` to release the
//! backing buffer.
//! Thread safety: not thread-safe. Callers must serialise access externally.
//! Memory budget: a single contiguous buffer is allocated at init. No allocation occurs during the
//! bump phase. `high_water` and `overflow_count` are cumulative, including failed attempts.

const std = @import("std");
const CapacityReport = @import("capacity_report.zig").CapacityReport;

pub const ArenaError = error{
    OutOfMemory,
    InvalidConfig,
};

pub const Arena = struct {
    backing_allocator: std.mem.Allocator,
    buffer: []u8,
    offset: u64 = 0,
    high_water: u64 = 0,
    overflow_count: u32 = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(backing_allocator: std.mem.Allocator, capacity_bytes: usize) ArenaError!Arena {
        if (capacity_bytes == 0) return error.InvalidConfig;
        const buffer = backing_allocator.alloc(u8, capacity_bytes) catch return error.OutOfMemory;
        const out: Arena = .{
            .backing_allocator = backing_allocator,
            .buffer = buffer,
            .offset = 0,
            .high_water = 0,
            .overflow_count = 0,
        };
        std.debug.assert(out.buffer.len == capacity_bytes);
        std.debug.assert(out.offset == 0);
        return out;
    }

    pub fn deinit(self: *Arena) void {
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(self.offset <= @as(u64, self.buffer.len));
        self.backing_allocator.free(self.buffer);
        self.buffer = &[_]u8{};
        self.offset = 0;
        self.high_water = 0;
        self.overflow_count = 0;
    }

    pub fn reset(self: *Arena) void {
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(self.offset <= @as(u64, self.buffer.len));
        self.offset = 0;
    }

    pub fn used(self: *const Arena) u64 {
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(self.offset <= @as(u64, self.buffer.len));
        return self.offset;
    }

    pub fn capacity(self: *const Arena) u64 {
        std.debug.assert(self.buffer.len != 0);
        // Postcondition: capacity must always be >= used bytes. An arena that reports less
        // capacity than it has already allocated is in a corrupt state.
        std.debug.assert(@as(u64, self.buffer.len) >= self.offset);
        return @as(u64, self.buffer.len);
    }

    pub fn highWater(self: *const Arena) u64 {
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(self.high_water >= self.offset);
        return self.high_water;
    }

    pub fn overflowCount(self: *const Arena) u32 {
        std.debug.assert(self.buffer.len != 0);
        // Pair assertion: if overflow_count is non-zero, high_water must exceed capacity,
        // because an overflow only occurs when a requested end exceeds the buffer.
        if (self.overflow_count > 0) std.debug.assert(self.high_water > @as(u64, self.buffer.len));
        return self.overflow_count;
    }

    pub fn report(self: *const Arena) CapacityReport {
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(self.high_water >= self.offset);
        return .{
            .unit = .bytes,
            .used = self.used(),
            .high_water = self.high_water,
            .capacity = self.capacity(),
            .overflow_count = self.overflow_count,
        };
    }

    pub fn remaining(self: *const Arena) u64 {
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(self.offset <= @as(u64, self.buffer.len));
        if (self.offset < @as(u64, self.buffer.len)) {
            return @as(u64, self.buffer.len) - self.offset;
        } else {
            return 0;
        }
    }

    pub fn allocator(self: *Arena) std.mem.Allocator {
        std.debug.assert(self.buffer.len != 0);
        const alloc_if: std.mem.Allocator = .{ .ptr = self, .vtable = &vtable };
        // Postcondition: the vtable pointer must be non-null; a null vtable would make every
        // allocation attempt crash without a clear diagnostic.
        std.debug.assert(alloc_if.vtable == &vtable);
        return alloc_if;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(self.offset <= @as(u64, self.buffer.len));

        const alignment_bytes = alignment.toByteUnits();
        // usize fits in u64 on all supported platforms; the widening is always safe.
        const offset_usize: usize = @intCast(self.offset);
        const start = std.mem.alignForward(usize, offset_usize, alignment_bytes);
        const end = std.math.add(usize, start, len) catch return null;

        if (end > self.buffer.len) {
            self.overflow_count +|= 1;
            if (@as(u64, end) > self.high_water) self.high_water = @as(u64, end);
            return null;
        }

        self.offset = @as(u64, end);
        if (self.offset > self.high_water) self.high_water = self.offset;
        std.debug.assert(self.offset <= @as(u64, self.buffer.len));
        return self.buffer.ptr + start;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(self.offset <= @as(u64, self.buffer.len));

        const base = @intFromPtr(self.buffer.ptr);
        const mem_ptr = @intFromPtr(memory.ptr);
        if (mem_ptr < base) return false;
        const mem_end = std.math.add(usize, mem_ptr, memory.len) catch return false;
        const buf_end = std.math.add(usize, base, self.buffer.len) catch return false;
        if (mem_end > buf_end) return false;

        const mem_offset = mem_ptr - base;
        // usize fits in u64 on all supported platforms; the widening is always safe.
        if (@as(u64, mem_offset + memory.len) != self.offset) return false;

        if (new_len <= memory.len) {
            self.offset = @as(u64, mem_offset + new_len);
            return true;
        }

        const end = mem_offset + new_len;
        if (end > self.buffer.len) {
            self.overflow_count +|= 1;
            if (@as(u64, end) > self.high_water) self.high_water = @as(u64, end);
            return false;
        }

        self.offset = @as(u64, end);
        if (self.offset > self.high_water) self.high_water = self.offset;
        std.debug.assert(self.offset <= @as(u64, self.buffer.len));
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (resize(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
    }
};

test "arena alloc/reset reuses memory" {
    // Verifies that `reset()` rewinds the allocation cursor and reuses buffer addresses deterministically.
    var arena = try Arena.init(std.testing.allocator, 64);
    defer arena.deinit();

    const alloc_if = arena.allocator();
    const a = try alloc_if.alloc(u8, 8);
    const b = try alloc_if.alloc(u8, 8);
    try std.testing.expect(@intFromPtr(b.ptr) > @intFromPtr(a.ptr));

    arena.reset();
    const c = try alloc_if.alloc(u8, 8);
    try std.testing.expectEqual(@intFromPtr(a.ptr), @intFromPtr(c.ptr));
}

test "arena respects capacity and reports overflow" {
    // Verifies that overflowing the arena fails allocations while updating overflow tracking (without asserting on OOM).
    var arena = try Arena.init(std.testing.allocator, 16);
    defer arena.deinit();

    const alloc_if = arena.allocator();
    _ = try alloc_if.alloc(u8, 16);
    try std.testing.expectError(error.OutOfMemory, alloc_if.alloc(u8, 1));
    try std.testing.expect(arena.report().overflow_count >= 1);
    try std.testing.expect(arena.report().high_water >= 17);
}

test "arena rejects invalid capacity" {
    // Verifies that a zero-capacity arena is rejected up front as an invalid configuration.
    try std.testing.expectError(error.InvalidConfig, Arena.init(std.testing.allocator, 0));
}

test "arena resize respects capacity and tracks overflow" {
    // Verifies that `resize()` can grow/shrink the most-recent allocation and rejects growth past capacity.
    var arena = try Arena.init(std.testing.allocator, 16);
    defer arena.deinit();

    const alloc_if = arena.allocator();
    var mem = try alloc_if.alloc(u8, 8);
    const mem_ptr = mem.ptr;

    try std.testing.expect(alloc_if.resize(mem, 12));
    mem = mem_ptr[0..12];
    try std.testing.expectEqual(@as(u64, 12), arena.used());

    try std.testing.expect(alloc_if.resize(mem, 4));
    mem = mem_ptr[0..4];
    try std.testing.expectEqual(@as(u64, 4), arena.used());

    const old_used = arena.used();
    const old_overflows = arena.overflowCount();
    try std.testing.expect(!alloc_if.resize(mem, 32));
    try std.testing.expectEqual(old_used, arena.used());
    try std.testing.expect(arena.overflowCount() >= old_overflows);
    try std.testing.expect(arena.highWater() >= 32);
}
