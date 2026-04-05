//! Size-class slab allocator built on `Pool` instances, with an optional large-allocation fallback.
//!
//! Key types: `Slab`, `SlabConfig`, `SlabError`.
//! Usage pattern: configure size classes and counts in `SlabConfig`, call `Slab.init`, then use
//! `alloc`/`free` directly or obtain a `std.mem.Allocator` via `allocator()`. Call `deinit()` when
//! done.
//! Thread safety: not thread-safe. Callers must serialise access externally.
//! Memory budget: each size class owns a `Pool` whose backing buffer is allocated at init. The
//! `classes` slice itself is also heap-allocated. When `allow_large_fallback` is enabled, large
//! allocations bypass the class pools and go directly to the backing allocator; those are not
//! counted in the capacity report. Slab is 56 bytes on 64-bit targets.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const CapacityReport = @import("capacity_report.zig").CapacityReport;
const Pool = @import("pool.zig").Pool;
const PoolError = @import("pool.zig").PoolError;

pub const SlabError = error{
    OutOfMemory,
    InvalidConfig,
    InvalidAlignment,
    InvalidBlock,
    NoSpaceLeft,
    UnsupportedSize,
    Overflow,
};

pub const SlabConfig = struct {
    /// Sorted ascending; one pool per size class.
    class_sizes: []const u32,
    /// Capacity (in blocks) per size class.
    class_counts: []const u32,
    /// Enables the large-allocation fallback path for `len > maxClassSize()`.
    allow_large_fallback: bool = false,
};

pub const Slab = struct {
    backing_allocator: std.mem.Allocator,
    classes: []Class,
    allow_large_fallback: bool,
    max_size: u32,
    used_bytes: u64 = 0,
    high_water_bytes: u64 = 0,

    const Class = struct {
        size: u32,
        alignment: u32,
        pool: Pool,
    };

    const FallbackHeader = struct {
        magic: u32,
        payload_len: usize,
        total_len: usize,
        payload_align: u32,
        base_ptr: usize,
    };

    const fallback_magic: u32 = 0x534C4142; // "SLAB"
    const fallback_header_align: usize = @alignOf(FallbackHeader);
    const fallback_header_size: usize = std.mem.alignForward(usize, @sizeOf(FallbackHeader), fallback_header_align);

    // fallback_header_size is alignForward(sizeOf(FallbackHeader), fallback_header_align).
    // It must be >= the raw struct size so the full header always fits within the reserved
    // prefix, and it must be a multiple of the header alignment.
    comptime {
        assert(fallback_header_size >= @sizeOf(FallbackHeader));
        assert(fallback_header_size % fallback_header_align == 0);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocRaw,
        .resize = resizeRaw,
        .remap = remapRaw,
        .free = freeRaw,
    };

    pub fn report(self: *const Slab) CapacityReport {
        self.assertInvariants();
        var capacity_bytes: u64 = 0;
        var used_bytes: u64 = 0;
        var overflow_count: u32 = 0;

        for (self.classes) |*class| {
            const class_capacity = mulU64Saturating(@as(u64, class.size), @as(u64, class.pool.total()));
            const class_used = mulU64Saturating(@as(u64, class.size), @as(u64, class.pool.used()));
            capacity_bytes +|= class_capacity;
            used_bytes +|= class_used;
            overflow_count +|= class.pool.overflowCount();
        }

        if (std.debug.runtime_safety) {
            assert(self.used_bytes == used_bytes);
            assert(self.high_water_bytes >= used_bytes);
        }

        return .{
            .unit = .bytes,
            .used = used_bytes,
            .high_water = self.high_water_bytes,
            .capacity = capacity_bytes,
            .overflow_count = overflow_count,
        };
    }

    // Slab is 56 bytes on 64-bit targets, which is within the 64-byte threshold from
    // agents.md §5.5. Return-by-value init is acceptable; no in-place conversion needed.
    pub fn init(backing_allocator: std.mem.Allocator, config: SlabConfig) SlabError!Slab {
        if (config.class_sizes.len == 0) return error.InvalidConfig;
        if (config.class_sizes.len != config.class_counts.len) return error.InvalidConfig;

        const class_count = config.class_sizes.len;
        const classes = backing_allocator.alloc(Class, class_count) catch return error.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < initialized) : (j += 1) {
                classes[j].pool.deinit();
            }
            backing_allocator.free(classes);
        }

        var prev_size: u32 = 0;
        var i: usize = 0;
        while (i < class_count) : (i += 1) {
            const size = config.class_sizes[i];
            const count = config.class_counts[i];
            if (size == 0 or count == 0) return error.InvalidConfig;
            if (i > 0 and size <= prev_size) return error.InvalidConfig;

            const alignment = classAlign(size);
            // Initialize the pool in-place within the classes slice entry. Pool is 112 bytes,
            // exceeding the 64-byte threshold from agents.md §5.5, so in-place init is used
            // to avoid an intermediate copy from Pool.init's return value into classes[i].pool.
            classes[i] = .{
                .size = size,
                .alignment = alignment,
                .pool = undefined,
            };
            Pool.init(&classes[i].pool, backing_allocator, size, alignment, count) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NoSpaceLeft => return error.InvalidConfig,
                error.InvalidConfig => return error.InvalidConfig,
                error.InvalidBlock => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
            prev_size = size;
            initialized += 1;
        }

        const out: Slab = .{
            .backing_allocator = backing_allocator,
            .classes = classes,
            .allow_large_fallback = config.allow_large_fallback,
            .max_size = classes[class_count - 1].size,
            .used_bytes = 0,
            .high_water_bytes = 0,
        };
        out.assertInvariants();
        return out;
    }

    pub fn deinit(self: *Slab) void {
        self.assertInvariants();
        for (self.classes) |*class| {
            class.pool.deinit();
        }
        self.backing_allocator.free(self.classes);
        self.classes = &[_]Class{};
        self.max_size = 0;
        self.used_bytes = 0;
        self.high_water_bytes = 0;
    }

    pub fn allocator(self: *Slab) std.mem.Allocator {
        self.assertInvariants();
        assert(@intFromPtr(self) != 0);
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn alloc(self: *Slab, len: u32, alignment: u32) SlabError![]u8 {
        self.assertInvariants();
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;

        if (self.findClass(len, alignment)) |class| {
            const block = class.pool.allocBlock() catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidConfig => return error.InvalidConfig,
                error.InvalidBlock => return error.InvalidBlock,
                error.Overflow => return error.Overflow,
            };

            // Precondition: pool.allocBlock succeeded, so a slot existed. Accounting must stay bounded.
            assert(@as(u64, class.size) <= std.math.maxInt(u64) - self.used_bytes);
            // Overflow is unreachable: allocation tracking must stay within total slab capacity.
            self.used_bytes = std.math.add(u64, self.used_bytes, @as(u64, class.size)) catch unreachable;
            if (self.used_bytes > self.high_water_bytes) self.high_water_bytes = self.used_bytes;
            return block[0..len];
        }

        if (!self.allow_large_fallback) return error.UnsupportedSize;
        return self.fallbackAlloc(@intCast(len), @intCast(alignment)) orelse return error.OutOfMemory;
    }

    pub fn free(self: *Slab, memory: []u8, alignment: u32) SlabError!void {
        self.assertInvariants();
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;

        if (self.classByPtr(memory.ptr)) |class| {
            if (memory.len > class.size) return error.InvalidBlock;
            if (alignment > class.alignment) return error.InvalidBlock;

            const block = class.pool.blockFromPtr(memory.ptr) catch return error.InvalidBlock;
            class.pool.freeBlock(block) catch return error.InvalidBlock;

            // Precondition: used_bytes cannot underflow if allocations are balanced.
            assert(@as(u64, class.size) <= self.used_bytes);
            // Overflow is unreachable: used_bytes tracks live allocations; free cannot exceed alloc count.
            self.used_bytes = std.math.sub(u64, self.used_bytes, @as(u64, class.size)) catch unreachable;
            return;
        }

        if (self.allow_large_fallback and self.fallbackFree(memory, alignment)) return;
        return error.InvalidBlock;
    }

    pub fn maxClassSize(self: *const Slab) u32 {
        self.assertInvariants();
        // Postcondition: max_size must equal the last class's size as tracked in assertInvariants.
        assert(self.max_size == self.classes[self.classes.len - 1].size);
        return self.max_size;
    }

    fn mulU64Saturating(a: u64, b: u64) u64 {
        const result = std.math.mul(u64, a, b) catch std.math.maxInt(u64);
        // Postcondition: result must be maxInt(u64) on overflow, never a wrapped value.
        assert(result <= std.math.maxInt(u64));
        // Pair assertion: if both inputs are non-zero, the result must also be non-zero.
        if (a != 0 and b != 0) assert(result != 0);
        return result;
    }

    fn classAlign(size: u32) u32 {
        assert(size != 0);
        const neg = (~size) +% 1;
        const out = size & neg;
        assert(out != 0);
        assert(std.math.isPowerOfTwo(out));
        assert(size % out == 0);
        return out;
    }

    fn lowerBoundClass(classes: []Class, len: u32) usize {
        // Precondition: classes must be non-empty to make binary search meaningful.
        assert(classes.len != 0);
        var lo: usize = 0;
        var hi: usize = classes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (classes[mid].size < len) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Postcondition: lo is in [0, classes.len].
        assert(lo <= classes.len);
        return lo;
    }

    fn findClass(self: *Slab, len: u32, alignment: u32) ?*Class {
        // Precondition: alignment must be a power of two.
        assert(alignment != 0);
        const start = lowerBoundClass(self.classes, len);
        if (start == self.classes.len) return null;
        var i: usize = start;
        while (i < self.classes.len) : (i += 1) {
            const class = &self.classes[i];
            // Invariant: the class at or beyond start must have size >= len (by binary search).
            assert(class.size >= len);
            if (alignment <= class.alignment) return class;
        }
        return null;
    }

    fn classByPtr(self: *Slab, ptr: [*]u8) ?*Class {
        // Precondition: pointer must be non-null.
        assert(@intFromPtr(ptr) != 0);
        // Precondition: slab must be initialized.
        assert(self.classes.len != 0);
        for (self.classes) |*class| {
            if (class.pool.ownsPtr(ptr)) return class;
        }
        return null;
    }

    fn fallbackAlloc(self: *Slab, len: usize, alignment: usize) ?[]u8 {
        if (alignment == 0) return null;

        const payload_align: usize = @max(alignment, fallback_header_align);
        assert(std.math.isPowerOfTwo(payload_align));
        assert(payload_align <= std.math.maxInt(u32));
        const alloc_alignment = std.mem.Alignment.fromByteUnits(payload_align);

        const alloc_len = std.math.add(usize, fallback_header_size, len) catch return null;
        const padded_len = std.math.add(usize, alloc_len, payload_align - 1) catch return null;

        const base_ptr = self.backing_allocator.rawAlloc(padded_len, alloc_alignment, @returnAddress()) orelse return null;
        const base_addr = @intFromPtr(base_ptr);

        const after_header = std.math.add(usize, base_addr, fallback_header_size) catch return null;
        const payload_addr = std.mem.alignForward(usize, after_header, payload_align);
        const header_addr = payload_addr - fallback_header_size;

        const header: *FallbackHeader = @ptrFromInt(header_addr);
        header.* = .{
            .magic = fallback_magic,
            .payload_len = len,
            .total_len = padded_len,
            .payload_align = @intCast(payload_align),
            .base_ptr = base_addr,
        };

        const payload_end = std.math.add(usize, payload_addr, len) catch return null;
        const base_end = std.math.add(usize, base_addr, padded_len) catch return null;
        assert(payload_end <= base_end);

        const payload_ptr: [*]u8 = @ptrFromInt(payload_addr);
        return payload_ptr[0..len];
    }

    fn fallbackFree(self: *Slab, memory: []u8, alignment: u32) bool {
        if (memory.len == 0) return false;

        const payload_addr = @intFromPtr(memory.ptr);
        if (payload_addr < fallback_header_size) return false;

        const header_addr = payload_addr - fallback_header_size;
        if (header_addr % fallback_header_align != 0) return false;

        const header: *FallbackHeader = @ptrFromInt(header_addr);
        if (header.magic != fallback_magic) return false;
        if (header.payload_len != memory.len) return false;
        if (alignment > header.payload_align) return false;
        if (header.payload_align == 0 or !std.math.isPowerOfTwo(header.payload_align)) return false;
        if (header.payload_align < fallback_header_align) return false;

        const base_end = std.math.add(usize, header.base_ptr, header.total_len) catch return false;
        if (header.base_ptr > header_addr) return false;
        if (header_addr >= base_end) return false;

        const payload_end = std.math.add(usize, payload_addr, memory.len) catch return false;
        if (payload_end > base_end) return false;

        if (header.base_ptr % @as(usize, header.payload_align) != 0) return false;

        const base_ptr: [*]u8 = @ptrFromInt(header.base_ptr);
        const base = base_ptr[0..header.total_len];
        const alloc_alignment = std.mem.Alignment.fromByteUnits(@as(usize, header.payload_align));
        self.backing_allocator.rawFree(base, alloc_alignment, @returnAddress());
        return true;
    }

    fn allocRaw(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Slab = @ptrCast(@alignCast(ctx));
        if (len > std.math.maxInt(u32)) return null;

        const align_bytes = alignment.toByteUnits();
        if (align_bytes == 0 or align_bytes > std.math.maxInt(u32)) return null;

        const slice = self.alloc(@intCast(len), @intCast(align_bytes)) catch return null;
        return slice.ptr;
    }

    fn resizeRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remapRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn freeRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *Slab = @ptrCast(@alignCast(ctx));

        const align_bytes = alignment.toByteUnits();
        if (align_bytes == 0 or align_bytes > std.math.maxInt(u32)) {
            if (std.debug.runtime_safety) assert(false);
            return;
        }

        self.free(memory, @intCast(align_bytes)) catch {
            if (std.debug.runtime_safety) assert(false);
            return;
        };
    }

    fn assertInvariants(self: *const Slab) void {
        assert(self.classes.len != 0);
        assert(self.max_size == self.classes[self.classes.len - 1].size);
        assert(self.high_water_bytes >= self.used_bytes);

        var prev: u32 = 0;
        for (self.classes, 0..) |class, i| {
            assert(class.size != 0);
            assert(class.pool.total() != 0);
            assert(class.alignment == classAlign(class.size));
            if (i > 0) assert(class.size > prev);
            prev = class.size;
        }
    }
};

test "slab alloc/free within classes" {
    // Verifies allocations route to the smallest matching class and pointers are reused after free.
    const sizes = [_]u32{ 32, 64 };
    const counts = [_]u32{ 1, 1 };

    var slab = try Slab.init(testing.allocator, .{
        .class_sizes = &sizes,
        .class_counts = &counts,
        .allow_large_fallback = false,
    });
    defer slab.deinit();

    const a = try slab.alloc(16, 8);
    try testing.expectEqual(@as(usize, 16), a.len);
    try testing.expectError(error.NoSpaceLeft, slab.alloc(16, 8));
    try slab.free(a, 8);

    const b = try slab.alloc(16, 8);
    try testing.expectEqual(@intFromPtr(a.ptr), @intFromPtr(b.ptr));
    try slab.free(b, 8);
}

test "slab rejects unsorted class sizes" {
    // Verifies that size classes must be strictly increasing.
    const sizes = [_]u32{ 64, 32 };
    const counts = [_]u32{ 1, 1 };
    try testing.expectError(error.InvalidConfig, Slab.init(testing.allocator, .{
        .class_sizes = &sizes,
        .class_counts = &counts,
        .allow_large_fallback = false,
    }));
}

test "slab unsupported size without fallback" {
    // Verifies that allocations larger than `maxClassSize()` fail when fallback is disabled.
    const sizes = [_]u32{32};
    const counts = [_]u32{1};

    var slab = try Slab.init(testing.allocator, .{
        .class_sizes = &sizes,
        .class_counts = &counts,
        .allow_large_fallback = false,
    });
    defer slab.deinit();

    try testing.expectError(error.UnsupportedSize, slab.alloc(64, 8));
}

test "slab large-allocation fallback alloc/free" {
    // Verifies the backing-allocator fallback path for sizes larger than the largest configured class.
    const sizes = [_]u32{32};
    const counts = [_]u32{1};

    var slab = try Slab.init(testing.allocator, .{
        .class_sizes = &sizes,
        .class_counts = &counts,
        .allow_large_fallback = true,
    });
    defer slab.deinit();

    const mem = try slab.alloc(64, 8);
    try testing.expectEqual(@as(usize, 64), mem.len);
    try testing.expect(@intFromPtr(mem.ptr) % 8 == 0);

    try testing.expectError(error.InvalidBlock, slab.free(mem, 16));
    try slab.free(mem, 8);
}
