//! Fixed-size block allocator with stable pointers.
//!
//! Key types: `Pool`, `TypedPool(T)`, `PoolError`.
//! Usage pattern: call `Pool.init` with an out-pointer target, then `allocBlock()`/`freeBlock()` to
//! manage raw byte blocks, or use `TypedPool(T)` for typed pointer management. Call `deinit()` when
//! done. `reset()` returns all blocks to the free list without freeing the backing buffer.
//! Thread safety: not thread-safe. Callers must serialise access externally.
//! Memory budget: the backing buffer, free-list, and in-use arrays are allocated once at init.
//! No allocation occurs on the hot alloc/free path. Pool is 112 bytes on 64-bit targets; use
//! in-place init via out-pointer to avoid intermediate stack copies (see `Pool.init`).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const CapacityReport = @import("capacity_report.zig").CapacityReport;

pub const PoolError = error{
    OutOfMemory,
    NoSpaceLeft,
    InvalidConfig,
    InvalidBlock,
    Overflow,
};

// Pool contains multiple slice fields and an allocator reference; it must have positive
// size. A zero-size Pool would make @intFromPtr(self) checks meaningless and break the
// vtable dispatch assumption that the pool can be identified by address.
comptime {
    assert(@sizeOf(Pool) > 0);
}

pub const Pool = struct {
    backing_allocator: std.mem.Allocator,
    raw_buffer: []u8,
    buffer: []u8,
    free_next: []u32,
    in_use: []bool,
    block_size: u32,
    block_align: u32,
    capacity: u32,
    free_head: u32,
    free_count: u32,
    high_water_used: u32,
    overflow_count: u32,

    const free_sentinel: u32 = std.math.maxInt(u32);

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    // Pool is 112 bytes on 64-bit targets, exceeding the 64-byte threshold from agents.md §5.5.
    // In-place initialization via out-pointer is used to eliminate the intermediate copy-move
    // allocation that would otherwise occur when returning by value from init.
    pub fn init(target: *Pool, backing_allocator: std.mem.Allocator, block_size: u32, block_align: u32, capacity: u32) PoolError!void {
        if (block_size == 0) return error.InvalidConfig;
        if (capacity == 0) return error.InvalidConfig;
        if (block_align == 0 or !std.math.isPowerOfTwo(block_align)) return error.InvalidConfig;
        if (block_size % block_align != 0) return error.InvalidConfig;

        const total_bytes = std.math.mul(usize, @intCast(block_size), @intCast(capacity)) catch return error.Overflow;
        const pad: usize = @intCast(block_align);
        const raw_len = std.math.add(usize, total_bytes, pad) catch return error.Overflow;

        const raw_buffer = backing_allocator.alloc(u8, raw_len) catch return error.OutOfMemory;
        errdefer backing_allocator.free(raw_buffer);

        const base = @intFromPtr(raw_buffer.ptr);
        const aligned = std.mem.alignForward(usize, base, pad);
        const offset = aligned - base;
        const buf_end = std.math.add(usize, offset, total_bytes) catch return error.Overflow;
        assert(buf_end <= raw_buffer.len);
        const buffer = raw_buffer[offset..buf_end];

        const free_next = backing_allocator.alloc(u32, capacity) catch return error.OutOfMemory;
        errdefer backing_allocator.free(free_next);
        const in_use = backing_allocator.alloc(bool, capacity) catch return error.OutOfMemory;
        errdefer backing_allocator.free(in_use);
        @memset(in_use, false);

        var i: u32 = 0;
        while (i < capacity) : (i += 1) {
            free_next[i] = if (i + 1 == capacity) free_sentinel else i + 1;
        }

        target.* = .{
            .backing_allocator = backing_allocator,
            .raw_buffer = raw_buffer,
            .buffer = buffer,
            .free_next = free_next,
            .in_use = in_use,
            .block_size = block_size,
            .block_align = block_align,
            .capacity = capacity,
            .free_head = 0,
            .free_count = capacity,
            .high_water_used = 0,
            .overflow_count = 0,
        };
        target.assertInvariants();
    }

    pub fn deinit(self: *Pool) void {
        self.assertInvariants();
        assert(self.raw_buffer.len != 0);
        self.backing_allocator.free(self.raw_buffer);
        self.backing_allocator.free(self.free_next);
        self.backing_allocator.free(self.in_use);

        self.raw_buffer = &[_]u8{};
        self.buffer = &[_]u8{};
        self.free_next = &[_]u32{};
        self.in_use = &[_]bool{};

        self.free_head = free_sentinel;
        self.free_count = 0;
        self.high_water_used = 0;
        self.overflow_count = 0;
    }

    pub fn reset(self: *Pool) void {
        self.assertInvariants();
        var i: u32 = 0;
        while (i < self.capacity) : (i += 1) {
            self.free_next[i] = if (i + 1 == self.capacity) free_sentinel else i + 1;
            self.in_use[i] = false;
        }
        self.free_head = 0;
        self.free_count = self.capacity;
        self.assertInvariants();
    }

    pub fn available(self: *const Pool) u32 {
        self.assertInvariants();
        // Postcondition: available (free) count must not exceed total capacity.
        assert(self.free_count <= self.capacity);
        return self.free_count;
    }

    pub fn total(self: *const Pool) u32 {
        self.assertInvariants();
        // Postcondition: capacity must be non-zero; assertInvariants also checks this,
        // but the explicit assertion here documents the contract at the public API boundary.
        assert(self.capacity != 0);
        return self.capacity;
    }

    pub fn used(self: *const Pool) u32 {
        self.assertInvariants();
        assert(self.free_count <= self.capacity);
        return self.capacity - self.free_count;
    }

    pub fn highWaterUsed(self: *const Pool) u32 {
        self.assertInvariants();
        // Postcondition: high_water must be >= current used count (monotonically tracked).
        assert(self.high_water_used >= self.capacity - self.free_count);
        return self.high_water_used;
    }

    pub fn overflowCount(self: *const Pool) u32 {
        self.assertInvariants();
        // Pair assertion: if any overflow occurred, high_water must equal capacity because
        // overflow happens when allocBlock is called on an exhausted pool.
        if (self.overflow_count > 0) assert(self.high_water_used == self.capacity);
        return self.overflow_count;
    }

    pub fn report(self: *const Pool) CapacityReport {
        self.assertInvariants();
        const r: CapacityReport = .{
            .unit = .blocks,
            .used = @as(u64, self.used()),
            .high_water = @as(u64, self.highWaterUsed()),
            .capacity = @as(u64, self.capacity),
            .overflow_count = self.overflow_count,
        };
        // Postcondition: reported capacity must match the configured block capacity.
        assert(r.capacity == @as(u64, self.capacity));
        return r;
    }

    pub fn blockSize(self: *const Pool) u32 {
        self.assertInvariants();
        // Postcondition: block_size must be non-zero; zero-sized blocks are rejected in init.
        assert(self.block_size != 0);
        return self.block_size;
    }

    pub fn blockAlign(self: *const Pool) u32 {
        self.assertInvariants();
        // Postcondition: block_align must be a non-zero power of two; assertInvariants also
        // checks this, but the assertion here documents the contract at the public API boundary.
        assert(std.math.isPowerOfTwo(self.block_align));
        return self.block_align;
    }

    pub fn blockFromPtr(self: *const Pool, ptr: [*]u8) PoolError![]u8 {
        self.assertInvariants();
        // Build a candidate slice from the raw pointer using block_size, then delegate all
        // validation (bounds, alignment, offset modulo) to indexFromBlock so the invariants
        // are enforced by a single code path. This eliminates the duplicated bounds logic
        // that previously existed in both functions.
        const size = @as(usize, self.block_size);
        const candidate = ptr[0..size];
        const index = try self.indexFromBlock(candidate);
        // Pair assertion: the index returned by indexFromBlock must be in [0, capacity).
        // indexFromBlock already enforces this, but asserting here makes the contract explicit
        // at the blockFromPtr boundary for both lookup paths.
        assert(index < self.capacity);
        return self.blockSlice(index);
    }

    pub fn ownsPtr(self: *const Pool, ptr: [*]u8) bool {
        // Precondition: invariants must hold before performing pointer arithmetic.
        self.assertInvariants();
        const result = if (self.blockFromPtr(ptr)) |_| true else |_| false;
        // Pair assertion: if owned, the pointer must fall within the buffer address range.
        if (result) {
            const base = @intFromPtr(self.buffer.ptr);
            const p = @intFromPtr(ptr);
            assert(p >= base);
            assert(p < base + self.buffer.len);
        }
        return result;
    }

    pub fn allocBlock(self: *Pool) PoolError![]u8 {
        self.assertInvariants();
        if (self.free_head == free_sentinel) {
            self.overflow_count +|= 1;
            return error.NoSpaceLeft;
        }

        const index = self.free_head;
        assert(index < self.capacity);
        assert(self.free_count != 0);
        self.free_head = self.free_next[index];
        self.free_count -= 1;

        const used_now = self.capacity - self.free_count;
        if (used_now > self.high_water_used) self.high_water_used = used_now;

        if (std.debug.runtime_safety) assert(!self.in_use[index]);
        self.in_use[index] = true;

        const block = self.blockSlice(index);
        self.assertInvariants();
        return block;
    }

    pub fn freeBlock(self: *Pool, block: []u8) PoolError!void {
        self.assertInvariants();
        const index = try self.indexFromBlock(block);
        if (!self.in_use[index]) return error.InvalidBlock;

        assert(self.free_count < self.capacity);
        self.in_use[index] = false;
        self.free_next[index] = self.free_head;
        self.free_head = index;
        self.free_count += 1;
        self.assertInvariants();
    }

    pub fn allocator(self: *Pool) std.mem.Allocator {
        self.assertInvariants();
        assert(@intFromPtr(self) != 0);
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Pool = @ptrCast(@alignCast(ctx));
        self.assertInvariants();

        if (len != @as(usize, self.block_size)) return null;
        if (alignment.toByteUnits() > @as(usize, self.block_align)) return null;

        const block = self.allocBlock() catch return null;
        return block.ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *Pool = @ptrCast(@alignCast(ctx));
        self.assertInvariants();

        if (new_len != memory.len) return false;
        if (memory.len != @as(usize, self.block_size)) return false;
        if (alignment.toByteUnits() > @as(usize, self.block_align)) return false;
        _ = self.indexFromBlock(memory) catch return false;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (resize(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *Pool = @ptrCast(@alignCast(ctx));
        self.assertInvariants();
        if (std.debug.runtime_safety) assert(alignment.toByteUnits() <= @as(usize, self.block_align));

        self.freeBlock(memory) catch {
            if (std.debug.runtime_safety) assert(false);
            return;
        };
    }

    fn blockSlice(self: *const Pool, index: u32) []u8 {
        self.assertInvariants();
        assert(index < self.capacity);

        // `index < capacity` and `buffer.len == block_size * capacity` guarantee this cannot overflow.
        const offset = std.math.mul(usize, @as(usize, self.block_size), @as(usize, index)) catch unreachable;
        const end = std.math.add(usize, offset, @as(usize, self.block_size)) catch unreachable;
        assert(end <= self.buffer.len);
        return self.buffer[offset..end];
    }

    fn indexFromBlock(self: *const Pool, block: []u8) PoolError!u32 {
        self.assertInvariants();
        if (block.len != @as(usize, self.block_size)) return error.InvalidBlock;

        const base = @intFromPtr(self.buffer.ptr);
        const ptr = @intFromPtr(block.ptr);
        if (ptr < base) return error.InvalidBlock;
        const ptr_end = std.math.add(usize, ptr, block.len) catch return error.InvalidBlock;
        const buf_end = std.math.add(usize, base, self.buffer.len) catch return error.InvalidBlock;
        if (ptr_end > buf_end) return error.InvalidBlock;

        const offset = ptr - base;
        if (offset % @as(usize, self.block_size) != 0) return error.InvalidBlock;
        if (ptr % @as(usize, self.block_align) != 0) return error.InvalidBlock;

        const index = offset / @as(usize, self.block_size);
        if (index < @as(usize, self.capacity)) {
            // Pair assertion: the block slice reconstructed from this index must start at
            // exactly the same address as the incoming block pointer, mirroring the same
            // ownership check that blockFromPtr performs via the buffer offset computation.
            assert(index * @as(usize, self.block_size) == offset);
            return @intCast(index);
        } else {
            return error.InvalidBlock;
        }
    }

    fn assertInvariants(self: *const Pool) void {
        assert(self.block_size != 0);
        assert(self.block_align != 0);
        assert(std.math.isPowerOfTwo(self.block_align));
        assert(self.block_size % self.block_align == 0);
        assert(self.capacity != 0);

        assert(self.raw_buffer.len != 0);
        assert(self.buffer.len != 0);
        assert(self.free_next.len == @as(usize, self.capacity));
        assert(self.in_use.len == @as(usize, self.capacity));

        // `Pool.init()` rejects configurations where `block_size * capacity` overflows `usize`.
        const expected_bytes = std.math.mul(usize, @as(usize, self.block_size), @as(usize, self.capacity)) catch unreachable;
        assert(self.buffer.len == expected_bytes);

        const buf_ptr = @intFromPtr(self.buffer.ptr);
        assert(buf_ptr % @as(usize, self.block_align) == 0);

        assert(self.free_count <= self.capacity);
        if (self.free_head != free_sentinel) assert(self.free_head < self.capacity);

        assert(self.high_water_used <= self.capacity);
        assert(self.high_water_used >= self.capacity - self.free_count);
    }
};

pub fn TypedPool(comptime T: type) type {
    comptime {
        if (@sizeOf(T) == 0) @compileError("TypedPool does not support zero-size types");
    }

    return struct {
        const Self = @This();

        pool: Pool,

        pub fn init(target: *Self, backing_allocator: std.mem.Allocator, capacity: u32) PoolError!void {
            // Precondition: capacity must be non-zero; zero would produce a degenerate pool.
            if (capacity == 0) return error.InvalidConfig;
            try Pool.init(&target.pool, backing_allocator, @sizeOf(T), @alignOf(T), capacity);
            // Postcondition: the pool block_size must match @sizeOf(T) so create()/destroy()
            // safely cast between *T and the raw block slice.
            assert(target.pool.block_size == @sizeOf(T));
        }

        pub fn deinit(self: *Self) void {
            // Precondition: pool must be initialized (capacity > 0).
            assert(self.pool.capacity != 0);
            self.pool.deinit();
        }

        pub fn create(self: *Self) PoolError!*T {
            const block = try self.pool.allocBlock();
            // Postcondition: the block must have the expected size for type T.
            assert(block.len == @sizeOf(T));
            const ptr: *T = @ptrCast(@alignCast(block.ptr));
            // Postcondition: the pointer must be aligned for T.
            assert(@intFromPtr(ptr) % @alignOf(T) == 0);
            return ptr;
        }

        pub fn destroy(self: *Self, ptr: *T) PoolError!void {
            // Precondition: pointer must be non-null.
            assert(@intFromPtr(ptr) != 0);
            // Precondition: pointer must be aligned for T.
            assert(@intFromPtr(ptr) % @alignOf(T) == 0);
            const bytes = @as([*]u8, @ptrCast(ptr))[0..@sizeOf(T)];
            try self.pool.freeBlock(bytes);
        }

        pub fn alloc(self: *Self) PoolError!*T {
            return self.create();
        }

        pub fn free(self: *Self, ptr: *T) PoolError!void {
            return self.destroy(ptr);
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            // Precondition: pool must be initialized.
            assert(self.pool.capacity != 0);
            const alloc_if = self.pool.allocator();
            // Postcondition: returned allocator must have a non-null vtable.
            assert(@intFromPtr(alloc_if.ptr) != 0);
            return alloc_if;
        }
    };
}

test "Pool alloc/free blocks" {
    // Verifies deterministic reuse via `freeBlock()` and overflow accounting when the pool is exhausted.
    var pool: Pool = undefined;
    try Pool.init(&pool, testing.allocator, 16, 8, 2);
    defer pool.deinit();

    const a = try pool.allocBlock();
    const b = try pool.allocBlock();
    try testing.expectError(error.NoSpaceLeft, pool.allocBlock());

    try pool.freeBlock(a);
    const c = try pool.allocBlock();
    try testing.expectEqual(@intFromPtr(a.ptr), @intFromPtr(c.ptr));
    _ = b;
}

test "TypedPool basic" {
    // Verifies typed block creation/destruction and pointer reuse for a `TypedPool(T)` wrapper.
    var pool: TypedPool(u32) = undefined;
    try TypedPool(u32).init(&pool, testing.allocator, 2);
    defer pool.deinit();

    const a = try pool.create();
    a.* = 10;
    const b = try pool.create();
    b.* = 20;
    try testing.expectError(error.NoSpaceLeft, pool.create());

    try pool.destroy(a);
    const c = try pool.create();
    try testing.expectEqual(@intFromPtr(a), @intFromPtr(c));
}

test "Pool rejects invalid config" {
    // Verifies that invalid configuration values are rejected up front.
    var p: Pool = undefined;
    try testing.expectError(error.InvalidConfig, Pool.init(&p, testing.allocator, 0, 8, 1));
    try testing.expectError(error.InvalidConfig, Pool.init(&p, testing.allocator, 8, 0, 1));
    try testing.expectError(error.InvalidConfig, Pool.init(&p, testing.allocator, 8, 8, 0));
}

test "Pool blockFromPtr rejects non-owned pointers and double free" {
    // Verifies ownership checks and invalid block detection via `blockFromPtr()`/`freeBlock()`.
    var pool: Pool = undefined;
    try Pool.init(&pool, testing.allocator, 16, 8, 1);
    defer pool.deinit();

    const a = try pool.allocBlock();
    defer pool.freeBlock(a) catch {};

    const roundtrip = try pool.blockFromPtr(a.ptr);
    try testing.expectEqual(@intFromPtr(a.ptr), @intFromPtr(roundtrip.ptr));
    try testing.expectEqual(a.len, roundtrip.len);

    const other = try testing.allocator.alloc(u8, 16);
    defer testing.allocator.free(other);
    try testing.expectError(error.InvalidBlock, pool.blockFromPtr(other.ptr));
    try testing.expect(!pool.ownsPtr(other.ptr));

    try pool.freeBlock(a);
    try testing.expectError(error.InvalidBlock, pool.freeBlock(a));
}

test "Pool reset invalidates stale block frees" {
    // Verifies that `reset()` returns ownership to the pool and invalidates stale block handles.
    var pool: Pool = undefined;
    try Pool.init(&pool, testing.allocator, 16, 8, 2);
    defer pool.deinit();

    const first = try pool.allocBlock();
    const second = try pool.allocBlock();
    try testing.expectError(error.NoSpaceLeft, pool.allocBlock());

    pool.reset();
    try testing.expectError(error.InvalidBlock, pool.freeBlock(first));
    try testing.expectError(error.InvalidBlock, pool.freeBlock(second));

    const after_reset = try pool.allocBlock();
    try testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(after_reset.ptr));
}
