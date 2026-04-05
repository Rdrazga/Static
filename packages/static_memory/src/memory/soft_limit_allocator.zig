//! Allocator wrapper that attempts a primary allocation first, with an optional Debug-only fallback.
//!
//! Key types: `SoftLimitAllocator`, `DevModePolicy`.
//! Usage pattern: call `SoftLimitAllocator.init` with a primary allocator, an optional fallback, and
//! a policy. Obtain a `std.mem.Allocator` via `allocator()`. Call `report()` to inspect usage.
//! Thread safety: not thread-safe. Callers must serialise access externally.
//! Memory budget: the wrapper itself adds a per-allocation header (magic, which, base pointer, sizes)
//! to every block so that `free` can route back to the correct underlying allocator. Overflow
//! tracking is cumulative and includes all Debug-mode fallback allocations. SoftLimitAllocator is
//! 64 bytes on 64-bit targets.

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const builtin = @import("builtin");
const CapacityReport = @import("capacity_report.zig").CapacityReport;

pub const DevModePolicy = enum {
    strict,
    soft_fallback,
};

pub const SoftLimitAllocator = struct {
    const Self = @This();

    primary: std.mem.Allocator,
    fallback: ?std.mem.Allocator,
    policy: DevModePolicy,

    used_bytes: u64 = 0,
    high_water_bytes: u64 = 0,
    overflow_count: u32 = 0,

    const Which = enum(u8) { primary = 0, fallback = 1 };
    const magic: u32 = 0x534C494D; // "SLIM"

    const Header = struct {
        magic: u32,
        which: u8,
        _pad: [3]u8 = .{ 0, 0, 0 },
        base_ptr: usize,
        alloc_len: usize,
        payload_len: usize,
        payload_align: usize,
    };

    const header_align: usize = @alignOf(Header);
    const header_size: usize = std.mem.alignForward(usize, @sizeOf(Header), header_align);

    // header_size is alignForward(sizeOf(Header), header_align). It must be >= the raw
    // struct size so the full header always fits in the prefix reserved before each payload,
    // and must be a multiple of the header alignment so back-to-back placements stay aligned.
    comptime {
        assert(header_size >= @sizeOf(Header));
        assert(header_size % header_align == 0);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    // SoftLimitAllocator is 64 bytes on 64-bit targets, exactly at the threshold from
    // agents.md §5.5. Return-by-value init is acceptable; no in-place conversion needed.
    pub fn init(primary: std.mem.Allocator, fallback: ?std.mem.Allocator, policy: DevModePolicy) Self {
        const out: Self = .{ .primary = primary, .fallback = fallback, .policy = policy };
        // Postcondition: usage tracking must start at zero; no allocation has occurred yet.
        assert(out.used_bytes == 0);
        // Postcondition: overflow count must start at zero.
        assert(out.overflow_count == 0);
        return out;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        assert(@intFromPtr(self) != 0);
        const alloc_if: std.mem.Allocator = .{ .ptr = self, .vtable = &vtable };
        // Postcondition: the vtable must be the one associated with this type.
        assert(alloc_if.vtable == &vtable);
        return alloc_if;
    }

    pub fn report(self: *const Self) CapacityReport {
        assert(self.high_water_bytes >= self.used_bytes);
        const r: CapacityReport = .{
            .unit = .bytes,
            .used = self.used_bytes,
            .high_water = self.high_water_bytes,
            .capacity = 0,
            .overflow_count = self.overflow_count,
        };
        // Postcondition: reported high_water must be >= reported used.
        assert(r.high_water >= r.used);
        return r;
    }

    fn allowFallback(self: *const Self) bool {
        const result = switch (self.policy) {
            .strict => false,
            .soft_fallback => builtin.mode == .Debug and self.fallback != null,
        };
        // Pair assertion: strict policy must always deny fallback.
        if (self.policy == .strict) assert(!result);
        return result;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const req_align = alignment.toByteUnits();
        if (req_align == 0) return null;

        const payload_align: usize = @max(req_align, header_align);
        const alloc_alignment = std.mem.Alignment.fromByteUnits(payload_align);

        const alloc_len = std.math.add(usize, header_size, len) catch return null;
        const padded_len = std.math.add(usize, alloc_len, payload_align - 1) catch return null;

        const base = self.primary.vtable.alloc(self.primary.ptr, padded_len, alloc_alignment, ret_addr);
        if (base) |p| {
            return finishAlloc(self, .primary, p, padded_len, len, payload_align);
        }

        if (!self.allowFallback()) return null;

        self.overflow_count +|= 1;
        const fb = self.fallback.?;
        const fb_base = fb.vtable.alloc(fb.ptr, padded_len, alloc_alignment, ret_addr) orelse return null;
        return finishAlloc(self, .fallback, fb_base, padded_len, len, payload_align);
    }

    fn finishAlloc(
        self: *Self,
        which: Which,
        base_ptr: [*]u8,
        alloc_len: usize,
        payload_len: usize,
        payload_align: usize,
    ) [*]u8 {
        // Precondition: base_ptr must be non-null; the caller must have confirmed the
        // allocation succeeded before calling finishAlloc.
        assert(@intFromPtr(base_ptr) != 0);
        // Precondition: payload_align must be a non-zero power of two.
        assert(payload_align != 0);
        const base_addr = @intFromPtr(base_ptr);
        const after_header = std.math.add(usize, base_addr, header_size) catch @panic("SoftLimitAllocator: address overflow");
        const payload_addr = std.mem.alignForward(usize, after_header, payload_align);
        const header_addr = payload_addr - header_size;

        const header_ptr: *Header = @ptrFromInt(header_addr);
        header_ptr.* = .{
            .magic = magic,
            .which = @intFromEnum(which),
            .base_ptr = base_addr,
            .alloc_len = alloc_len,
            .payload_len = payload_len,
            .payload_align = payload_align,
        };

        // usize fits in u64 on all supported platforms; the widening is always safe.
        self.used_bytes +|= @as(u64, payload_len);
        if (self.used_bytes > self.high_water_bytes) self.high_water_bytes = self.used_bytes;

        return @ptrFromInt(payload_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    /// Recovers the allocation header from a live payload pointer.
    /// Asserts that the magic byte is valid and the allocation is in-bounds.
    /// Returns a pointer to the header for the caller to inspect and update.
    fn validateHeader(payload_ptr: [*]u8, memory_len: usize) ?*Header {
        const payload_addr = @intFromPtr(payload_ptr);
        // Precondition: payload address must be large enough to hold a header before it.
        if (payload_addr < header_size) {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: invalid payload address", .{});
            return null;
        }

        const header_addr = payload_addr - header_size;
        // Precondition: header must be naturally aligned to Header's alignment.
        if (header_addr % header_align != 0) {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: misaligned header", .{});
            return null;
        }

        const header: *Header = @ptrFromInt(header_addr);
        if (header.magic != magic) {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: header magic mismatch", .{});
            return null;
        }
        if (header.payload_len != memory_len) {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: length mismatch", .{});
            return null;
        }
        if (header.payload_align == 0 or !std.math.isPowerOfTwo(header.payload_align)) {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: invalid payload alignment", .{});
            return null;
        }

        const base_end = std.math.add(usize, header.base_ptr, header.alloc_len) catch {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: alloc_len overflow", .{});
            return null;
        };
        if (header.base_ptr > header_addr or header_addr >= base_end) {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: header out of range", .{});
            return null;
        }
        const payload_end = std.math.add(usize, payload_addr, memory_len) catch {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: payload overflow", .{});
            return null;
        };
        if (payload_end > base_end) {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: payload out of range", .{});
            return null;
        }
        // Pair assertion: base pointer must be aligned to at least header.payload_align so the
        // original allocation was served from the correct position within the padded region.
        if (header.base_ptr % header.payload_align != 0) {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: base misaligned", .{});
            return null;
        }

        return header;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (memory.len == 0) return;

        const header = validateHeader(memory.ptr, memory.len) orelse return;

        const payload_len = header.payload_len;
        const payload_align = header.payload_align;
        // Postcondition: validateHeader guarantees these fields are valid before we use them.
        assert(payload_align != 0);
        assert(std.math.isPowerOfTwo(payload_align));

        const base_ptr: [*]u8 = @ptrFromInt(header.base_ptr);
        const base = base_ptr[0..header.alloc_len];

        const which = std.enums.fromInt(Which, header.which) orelse {
            if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: invalid allocator tag", .{});
            return;
        };
        const underlying = switch (which) {
            .primary => self.primary,
            .fallback => self.fallback orelse {
                if (std.debug.runtime_safety) panic("SoftLimitAllocator.free: fallback missing", .{});
                return;
            },
        };

        const alloc_alignment = std.mem.Alignment.fromByteUnits(payload_align);
        underlying.vtable.free(underlying.ptr, base, alloc_alignment, ret_addr);

        // usize fits in u64 on all supported platforms; the widening is always safe.
        if (std.debug.runtime_safety) assert(self.used_bytes >= @as(u64, payload_len));
        self.used_bytes -|= @as(u64, payload_len);
    }
};

test "SoftLimitAllocator strict rejects overflow and does not count overflow" {
    // Verifies strict mode rejects primary allocator overflow without incrementing `overflow_count` or using fallback.
    const testing = std.testing;

    var arena = try @import("arena.zig").Arena.init(testing.allocator, 128);
    defer arena.deinit();

    var soft = SoftLimitAllocator.init(arena.allocator(), testing.allocator, .strict);
    const a = soft.allocator();

    try testing.expectError(error.OutOfMemory, a.alloc(u8, 200));
    try testing.expectEqual(@as(u32, 0), soft.report().overflow_count);
    try testing.expectEqual(@as(u64, 0), soft.report().used);
    try testing.expectEqual(@as(u64, 0), soft.report().high_water);
}

test "SoftLimitAllocator soft_fallback without fallback remains strict" {
    // Verifies `.soft_fallback` behaves like strict mode when no fallback allocator is configured.
    const testing = std.testing;

    var arena = try @import("arena.zig").Arena.init(testing.allocator, 128);
    defer arena.deinit();

    var soft = SoftLimitAllocator.init(arena.allocator(), null, .soft_fallback);
    const a = soft.allocator();

    try testing.expectError(error.OutOfMemory, a.alloc(u8, 200));
    try testing.expectEqual(@as(u32, 0), soft.report().overflow_count);
}

test "SoftLimitAllocator report tracks in-flight allocations" {
    // Verifies `report()` tracks in-flight bytes and preserves the high-water mark across frees.
    const testing = std.testing;

    var soft = SoftLimitAllocator.init(testing.allocator, null, .strict);
    const a = soft.allocator();

    const first = try a.alloc(u8, 8);
    const second = try a.alloc(u8, 16);

    try testing.expectEqual(@as(u64, 24), soft.report().used);
    try testing.expectEqual(@as(u64, 24), soft.report().high_water);

    a.free(second);
    try testing.expectEqual(@as(u64, 8), soft.report().used);
    try testing.expectEqual(@as(u64, 24), soft.report().high_water);

    a.free(first);
    try testing.expectEqual(@as(u64, 0), soft.report().used);
    try testing.expectEqual(@as(u64, 24), soft.report().high_water);
}

test "SoftLimitAllocator dev-only fallback" {
    // Verifies fallback is only enabled in Debug builds and increments overflow counters when primary fails.
    const testing = std.testing;
    if (builtin.mode != .Debug) return error.SkipZigTest;

    var arena = try @import("arena.zig").Arena.init(testing.allocator, 16);
    defer arena.deinit();

    var soft = SoftLimitAllocator.init(arena.allocator(), testing.allocator, .soft_fallback);
    const a = soft.allocator();

    const buf = try a.alloc(u8, 32);
    defer a.free(buf);
    try testing.expect(soft.report().overflow_count >= 1);
}

test "SoftLimitAllocator dev-only fallback updates report and frees correctly" {
    // Verifies fallback allocations contribute to usage accounting and are freed via the correct underlying allocator.
    const testing = std.testing;
    if (builtin.mode != .Debug) return error.SkipZigTest;

    var arena = try @import("arena.zig").Arena.init(testing.allocator, 128);
    defer arena.deinit();

    var soft = SoftLimitAllocator.init(arena.allocator(), testing.allocator, .soft_fallback);
    const a = soft.allocator();

    const buf = try a.alloc(u8, 200);
    try testing.expect(soft.report().overflow_count >= 1);
    try testing.expectEqual(@as(u64, 200), soft.report().used);
    try testing.expect(soft.report().high_water >= 200);

    a.free(buf);
    try testing.expectEqual(@as(u64, 0), soft.report().used);
}
