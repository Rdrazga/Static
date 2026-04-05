//! Bounded reusable buffer pool built on `static_memory.pool.Pool`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const static_memory = @import("static_memory");
const types = @import("types.zig");

/// Immutable configuration for `BufferPool`.
pub const Config = struct {
    /// Size in bytes for each fixed-size pool block.
    buffer_size: u32,
    /// Alignment for each block; must be power-of-two.
    buffer_align: u32 = @alignOf(u8),
    /// Total number of blocks in the pool.
    capacity: u32,
    /// Optional shared memory budget reservation.
    budget: ?*static_memory.budget.Budget = null,
};

/// Initialization failures for `BufferPool`.
pub const InitError = error{
    InvalidConfig,
    OutOfMemory,
    NoSpaceLeft,
    Overflow,
};

/// Acquire failures for `BufferPool`.
pub const AcquireError = error{
    NoSpaceLeft,
};

/// Release failures for `BufferPool`.
pub const ReleaseError = error{
    InvalidInput,
};

comptime {
    core.errors.assertVocabularySubset(InitError);
    core.errors.assertVocabularySubset(AcquireError);
    core.errors.assertVocabularySubset(ReleaseError);
}

/// Fixed-capacity reusable byte buffer pool.
pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    pool: static_memory.pool.Pool,
    budget: ?*static_memory.budget.Budget = null,
    reserved_bytes: usize = 0,

    /// Initializes a bounded pool and reserves budget up front.
    pub fn init(allocator: std.mem.Allocator, cfg: Config) InitError!BufferPool {
        try validateConfig(cfg);
        assert(cfg.buffer_size != 0);
        assert(cfg.capacity != 0);
        assert(cfg.buffer_align != 0);
        assert(std.math.isPowerOfTwo(cfg.buffer_align));
        assert(cfg.buffer_size % cfg.buffer_align == 0);

        const reserved_bytes = std.math.mul(usize, cfg.buffer_size, cfg.capacity) catch return error.Overflow;
        assert(reserved_bytes > 0);
        if (cfg.budget) |budget| {
            budget.tryReserve(reserved_bytes) catch |reserve_err| switch (reserve_err) {
                error.InvalidConfig => return error.InvalidConfig,
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.Overflow => return error.Overflow,
            };
        }
        errdefer if (cfg.budget) |budget| budget.release(reserved_bytes);

        var pool: static_memory.pool.Pool = undefined;
        static_memory.pool.Pool.init(
            &pool,
            allocator,
            cfg.buffer_size,
            cfg.buffer_align,
            cfg.capacity,
        ) catch |pool_err| switch (pool_err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.OutOfMemory => return error.OutOfMemory,
            error.Overflow => return error.Overflow,
            error.NoSpaceLeft => return error.NoSpaceLeft,
            error.InvalidBlock => return error.InvalidConfig,
        };

        return .{
            .allocator = allocator,
            .pool = pool,
            .budget = cfg.budget,
            .reserved_bytes = reserved_bytes,
        };
    }

    /// Releases the pool and returns any reserved budget.
    pub fn deinit(self: *BufferPool) void {
        assert(self.reserved_bytes > 0);
        self.pool.deinit();
        if (self.budget) |budget| budget.release(self.reserved_bytes);
        self.* = undefined;
    }

    /// Acquires one buffer from the pool.
    pub fn acquire(self: *BufferPool) AcquireError!types.Buffer {
        const bytes = self.pool.allocBlock() catch |pool_err| switch (pool_err) {
            error.NoSpaceLeft => return error.NoSpaceLeft,
            error.InvalidConfig => return error.NoSpaceLeft,
            error.InvalidBlock => return error.NoSpaceLeft,
            error.OutOfMemory => return error.NoSpaceLeft,
            error.Overflow => return error.NoSpaceLeft,
        };
        assert(bytes.len == self.pool.blockSize());
        return .{
            .bytes = bytes,
            .used_len = 0,
        };
    }

    /// Returns a previously acquired buffer to the pool.
    pub fn release(self: *BufferPool, buffer: types.Buffer) ReleaseError!void {
        if (buffer.used_len > buffer.bytes.len) return error.InvalidInput;
        self.pool.freeBlock(buffer.bytes) catch return error.InvalidInput;
    }

    /// Returns currently available block count.
    pub fn available(self: *const BufferPool) u32 {
        const available_count = self.pool.available();
        assert(available_count <= self.pool.total());
        return available_count;
    }

    /// Returns total block capacity.
    pub fn capacity(self: *const BufferPool) u32 {
        return self.pool.total();
    }

    /// Returns the fixed block size in bytes.
    pub fn bufferSize(self: *const BufferPool) u32 {
        return self.pool.blockSize();
    }

    /// Returns usage metrics in block units.
    pub fn reportBlocks(self: *const BufferPool) static_memory.capacity_report.CapacityReport {
        return self.pool.report();
    }

    /// Returns usage metrics in byte units.
    pub fn reportBytes(self: *const BufferPool) static_memory.capacity_report.CapacityReport {
        const report_blocks = self.reportBlocks();
        const bytes_per_block: u64 = self.bufferSize();
        assert(report_blocks.used <= report_blocks.capacity);
        assert(report_blocks.high_water <= report_blocks.capacity);
        return .{
            .unit = .bytes,
            .used = std.math.mul(u64, report_blocks.used, bytes_per_block) catch unreachable,
            .high_water = std.math.mul(u64, report_blocks.high_water, bytes_per_block) catch unreachable,
            .capacity = std.math.mul(u64, report_blocks.capacity, bytes_per_block) catch unreachable,
            .overflow_count = report_blocks.overflow_count,
        };
    }
};

/// Validates pool invariants before allocating pool storage.
fn validateConfig(cfg: Config) InitError!void {
    if (cfg.buffer_size == 0) return error.InvalidConfig;
    if (cfg.capacity == 0) return error.InvalidConfig;
    if (cfg.buffer_align == 0) return error.InvalidConfig;
    if (!std.math.isPowerOfTwo(cfg.buffer_align)) return error.InvalidConfig;
    if (cfg.buffer_size % cfg.buffer_align != 0) return error.InvalidConfig;
}

test "buffer pool rejects invalid configuration" {
    try testing.expectError(error.InvalidConfig, BufferPool.init(testing.allocator, .{
        .buffer_size = 0,
        .capacity = 1,
    }));
    try testing.expectError(error.InvalidConfig, BufferPool.init(testing.allocator, .{
        .buffer_size = 8,
        .buffer_align = 3,
        .capacity = 1,
    }));
}

test "buffer pool exhaustion, reuse, and high-water reporting" {
    var pool = try BufferPool.init(testing.allocator, .{
        .buffer_size = 8,
        .capacity = 2,
    });
    defer pool.deinit();

    const a = try pool.acquire();
    const b = try pool.acquire();
    try testing.expectError(error.NoSpaceLeft, pool.acquire());
    try testing.expectEqual(@as(u32, 0), pool.available());

    try pool.release(a);
    try testing.expectEqual(@as(u32, 1), pool.available());

    const c = try pool.acquire();
    defer pool.release(b) catch unreachable;
    defer pool.release(c) catch unreachable;

    const blocks = pool.reportBlocks();
    try testing.expectEqual(@as(u64, 2), blocks.high_water);
    try testing.expectEqual(@as(u64, 2), blocks.capacity);

    const bytes = pool.reportBytes();
    try testing.expectEqual(@as(u64, 16), bytes.high_water);
    try testing.expectEqual(@as(u64, 16), bytes.capacity);
}

test "buffer pool release rejects foreign slices" {
    var pool = try BufferPool.init(testing.allocator, .{
        .buffer_size = 8,
        .capacity = 1,
    });
    defer pool.deinit();

    var storage: [8]u8 = [_]u8{0} ** 8;
    const foreign = types.Buffer{ .bytes = &storage };
    try testing.expectError(error.InvalidInput, pool.release(foreign));
}
