//! A bounded, LIFO stack allocator with explicit markers and `freeLast()` support.
//!
//! Key types: `Stack`, `StackError`, `Marker`.
//! Usage pattern: call `Stack.init` with a backing allocator and capacity. Use `alloc()` for typed
//! allocations, `mark()`/`freeTo()` for scope-based rollback, `freeLast()` to pop the top
//! allocation, and `allocator()` to obtain a `std.mem.Allocator`.
//! Thread safety: not thread-safe. Callers must serialise access externally.
//! Memory budget: a single contiguous buffer is allocated at init; no allocation occurs during use.
//! `high_water` and `overflow_count` are cumulative diagnostics, including failed attempts.
//! Stack is 48 bytes on 64-bit targets; return-by-value init is acceptable.

const std = @import("std");
const CapacityReport = @import("capacity_report.zig").CapacityReport;

pub const StackError = error{
    OutOfMemory,
    InvalidConfig,
    InvalidAlignment,
};

pub const Stack = struct {
    backing_allocator: std.mem.Allocator,
    buffer: []u8,
    top: u32 = 0,
    high_water: u32 = 0,
    overflow_count: u32 = 0,

    pub const Marker = u32;

    const Header = struct {
        prev_offset: u32,
        payload_offset: u32,
        payload_len: u32,
    };

    const header_align: usize = @alignOf(Header);
    const header_size: usize = std.mem.alignForward(usize, @sizeOf(Header), header_align);

    // header_size is computed as alignForward(sizeOf(Header), header_align). The result must
    // be a multiple of header_align so that stacking headers back-to-back preserves alignment.
    comptime {
        std.debug.assert(header_size % header_align == 0);
    }

    const Layout = struct {
        payload_start: usize,
        header_start: usize,
        next_top: usize,
    };

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocRaw,
        .resize = resizeRaw,
        .remap = remapRaw,
        .free = freeRaw,
    };

    // Stack is 48 bytes on 64-bit targets, within the 64-byte threshold from agents.md §5.5.
    // Return-by-value init is acceptable; no in-place conversion needed.
    pub fn init(backing_allocator: std.mem.Allocator, capacity_bytes: u32) StackError!Stack {
        if (capacity_bytes == 0) return error.InvalidConfig;
        const buffer = backing_allocator.alloc(u8, capacity_bytes) catch return error.OutOfMemory;

        const out = Stack{
            .backing_allocator = backing_allocator,
            .buffer = buffer,
            .top = 0,
            .high_water = 0,
            .overflow_count = 0,
        };
        std.debug.assert(out.buffer.len == capacity_bytes);
        std.debug.assert(out.top == 0);
        return out;
    }

    pub fn deinit(self: *Stack) void {
        self.assertInvariants();
        self.backing_allocator.free(self.buffer);
        self.buffer = &[_]u8{};
        self.top = 0;
        self.high_water = 0;
        self.overflow_count = 0;
    }

    pub fn reset(self: *Stack) void {
        self.assertInvariants();
        self.top = 0;
        self.assertInvariants();
    }

    pub fn used(self: *const Stack) u32 {
        self.assertInvariants();
        // Postcondition: used (top) must not exceed the capacity (buffer.len).
        std.debug.assert(@as(usize, self.top) <= self.buffer.len);
        return self.top;
    }

    pub fn capacity(self: *const Stack) u32 {
        self.assertInvariants();
        // Postcondition: capacity must be >= current used bytes.
        std.debug.assert(self.buffer.len >= @as(usize, self.top));
        return @intCast(self.buffer.len);
    }

    pub fn highWater(self: *const Stack) u32 {
        self.assertInvariants();
        std.debug.assert(self.high_water >= self.top);
        return self.high_water;
    }

    pub fn overflowCount(self: *const Stack) u32 {
        self.assertInvariants();
        // Pair assertion: if any overflow occurred, high_water must be >= the cursor, since
        // overflow tracking records the watermark at the time of the failed allocation.
        if (self.overflow_count > 0) std.debug.assert(self.high_water >= self.top);
        return self.overflow_count;
    }

    pub fn report(self: *const Stack) CapacityReport {
        self.assertInvariants();
        const r: CapacityReport = .{
            .unit = .bytes,
            .used = @as(u64, self.used()),
            .high_water = @as(u64, self.highWater()),
            .capacity = @as(u64, self.capacity()),
            .overflow_count = self.overflowCount(),
        };
        // Postcondition: reported capacity must equal the buffer length.
        std.debug.assert(r.capacity == @as(u64, self.buffer.len));
        return r;
    }

    pub fn remaining(self: *const Stack) u32 {
        self.assertInvariants();
        const cap: u32 = @intCast(self.buffer.len);
        const rem = cap - self.top;
        // Postcondition: remaining + used must equal capacity.
        std.debug.assert(@as(usize, rem) + @as(usize, self.top) == self.buffer.len);
        return rem;
    }

    pub fn mark(self: *const Stack) Marker {
        self.assertInvariants();
        const m = self.top;
        // Postcondition: the marker must be within [0, capacity]. A mark outside this range
        // would be invalid for any future freeTo() call and indicates memory corruption.
        std.debug.assert(m <= @as(u32, @intCast(self.buffer.len)));
        return m;
    }

    pub fn freeTo(self: *Stack, marker: Marker) void {
        self.assertInvariants();
        std.debug.assert(marker <= self.top);
        self.top = marker;
        self.assertInvariants();
    }

    pub fn freeLast(self: *Stack) bool {
        self.assertInvariants();
        const last = self.lastHeader() orelse return false;
        const header = last.header.*;
        std.debug.assert(header.prev_offset < self.top);
        std.debug.assert(header.payload_offset + header.payload_len <= last.header_start);
        self.top = header.prev_offset;
        self.assertInvariants();
        return true;
    }

    pub fn alloc(self: *Stack, len: u32, alignment: u32) StackError![]u8 {
        self.assertInvariants();
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;

        const layout = computeLayout(
            self.top,
            len,
            alignment,
            self.buffer.len,
            &self.high_water,
        ) catch |err| {
            if (err == error.OutOfMemory) self.overflow_count +|= 1;
            return err;
        };

        const header = self.headerPtr(layout.header_start);
        header.* = .{
            .prev_offset = self.top,
            .payload_offset = @intCast(layout.payload_start),
            .payload_len = len,
        };

        self.top = @intCast(layout.next_top);
        if (self.top > self.high_water) self.high_water = self.top;
        self.assertInvariants();

        return self.buffer[layout.payload_start .. layout.payload_start + @as(usize, len)];
    }

    pub fn allocator(self: *Stack) std.mem.Allocator {
        self.assertInvariants();
        std.debug.assert(@intFromPtr(self) != 0);
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn computeLayout(top: u32, len: u32, alignment: u32, capacity_bytes: usize, high_water: ?*u32) StackError!Layout {
        const top_usize: usize = @intCast(top);
        const align_usize: usize = @intCast(alignment);
        const len_usize: usize = @intCast(len);

        const payload_start = std.mem.alignForward(usize, top_usize, align_usize);
        const payload_end = std.math.add(usize, payload_start, len_usize) catch return error.OutOfMemory;
        const header_start = std.mem.alignForward(usize, payload_end, header_align);
        const next_top = std.math.add(usize, header_start, header_size) catch return error.OutOfMemory;

        if (next_top > capacity_bytes) {
            if (high_water) |hw| {
                if (next_top <= std.math.maxInt(u32)) {
                    const needed: u32 = @intCast(next_top);
                    if (needed > hw.*) hw.* = needed;
                }
            }
            return error.OutOfMemory;
        }

        return .{
            .payload_start = payload_start,
            .header_start = header_start,
            .next_top = next_top,
        };
    }

    fn headerPtr(self: *Stack, header_start: usize) *Header {
        const header_bytes = self.buffer[header_start .. header_start + header_size];
        return @ptrCast(@alignCast(header_bytes.ptr));
    }

    fn lastHeader(self: *Stack) ?struct { header: *Header, header_start: usize } {
        if (self.top == 0) return null;

        const top_usize: usize = @intCast(self.top);
        std.debug.assert(top_usize >= header_size);

        const header_start = top_usize - header_size;
        std.debug.assert(header_start + header_size <= self.buffer.len);

        return .{
            .header = self.headerPtr(header_start),
            .header_start = header_start,
        };
    }

    fn assertInvariants(self: *const Stack) void {
        std.debug.assert(self.buffer.len != 0);
        std.debug.assert(@as(usize, self.top) <= self.buffer.len);
        std.debug.assert(self.high_water >= self.top);
    }

    fn allocRaw(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Stack = @ptrCast(@alignCast(ctx));

        if (len > std.math.maxInt(u32)) return null;
        const align_bytes = alignment.toByteUnits();
        if (align_bytes == 0 or align_bytes > std.math.maxInt(u32)) return null;

        const slice = self.alloc(@intCast(len), @intCast(align_bytes)) catch return null;
        return slice.ptr;
    }

    fn resizeRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *Stack = @ptrCast(@alignCast(ctx));
        self.assertInvariants();
        if (new_len > std.math.maxInt(u32)) return false;

        const align_bytes = alignment.toByteUnits();
        if (align_bytes == 0 or align_bytes > std.math.maxInt(u32)) return false;

        const last = self.lastHeader() orelse return false;
        const header = last.header.*;

        const payload_offset: usize = header.payload_offset;
        const payload_len: usize = header.payload_len;
        const base = @intFromPtr(self.buffer.ptr);
        const mem_ptr = @intFromPtr(memory.ptr);
        const expected_ptr = std.math.add(usize, base, payload_offset) catch return false;
        if (mem_ptr != expected_ptr) return false;
        if (memory.len != payload_len) return false;

        const layout = computeLayout(
            header.prev_offset,
            @intCast(new_len),
            @intCast(align_bytes),
            self.buffer.len,
            null,
        ) catch return false;

        if (layout.payload_start != payload_offset) return false;

        const header_ptr = self.headerPtr(layout.header_start);
        header_ptr.* = .{
            .prev_offset = header.prev_offset,
            .payload_offset = header.payload_offset,
            .payload_len = @intCast(new_len),
        };

        self.top = @intCast(layout.next_top);
        if (self.top > self.high_water) self.high_water = self.top;
        return true;
    }

    fn remapRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (resizeRaw(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
        return null;
    }

    fn freeRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *Stack = @ptrCast(@alignCast(ctx));
        self.assertInvariants();

        const last = self.lastHeader() orelse return;
        const header = last.header.*;

        const payload_offset: usize = header.payload_offset;
        const payload_len: usize = header.payload_len;
        const base = @intFromPtr(self.buffer.ptr);
        const mem_ptr = @intFromPtr(memory.ptr);

        const expected_ptr = std.math.add(usize, base, payload_offset) catch {
            if (std.debug.runtime_safety) std.debug.assert(false);
            return;
        };
        if (mem_ptr != expected_ptr or memory.len != payload_len) {
            if (std.debug.runtime_safety) std.debug.assert(false);
            return;
        }

        self.top = header.prev_offset;
    }
};

test "stack basic alloc/freeLast" {
    // Verifies LIFO allocation metadata and `freeLast()` behavior down to the empty stack.
    var stack = try Stack.init(std.testing.allocator, 128);
    defer stack.deinit();

    _ = try stack.alloc(8, 4);
    _ = try stack.alloc(16, 8);
    try std.testing.expect(stack.used() > 0);

    try std.testing.expect(stack.freeLast());
    try std.testing.expect(stack.freeLast());
    try std.testing.expect(!stack.freeLast());
    try std.testing.expectEqual(@as(u32, 0), stack.used());
}

test "stack mark/freeTo" {
    // Verifies mark/freeTo restores the stack cursor and safely discards newer allocations.
    var stack = try Stack.init(std.testing.allocator, 128);
    defer stack.deinit();

    _ = try stack.alloc(8, 4);
    const mark = stack.mark();
    _ = try stack.alloc(16, 8);
    stack.freeTo(mark);
    try std.testing.expectEqual(mark, stack.used());
}

test "stack rejects invalid alignment" {
    // Verifies alignment preconditions reject non-power-of-two and zero alignment values.
    var stack = try Stack.init(std.testing.allocator, 64);
    defer stack.deinit();

    try std.testing.expectError(error.InvalidAlignment, stack.alloc(8, 3));
    try std.testing.expectError(error.InvalidAlignment, stack.alloc(8, 0));
}

test "stack allocator resize and remap preserve LIFO contract" {
    // Verifies that the allocator facade can grow/shrink the top allocation, remap it in place,
    // and rejects resize attempts for non-top allocations.
    var stack = try Stack.init(std.testing.allocator, 64);
    defer stack.deinit();

    const alloc_if = stack.allocator();
    const first = try alloc_if.alloc(u8, 8);
    const used_after_first = stack.used();
    var second = try alloc_if.alloc(u8, 8);
    const used_after_second = stack.used();
    const second_ptr = second.ptr;

    try std.testing.expect(alloc_if.resize(second, 12));
    second = second_ptr[0..12];
    const used_after_resize = stack.used();
    try std.testing.expect(used_after_resize > used_after_second);

    const remapped = alloc_if.remap(second, 16);
    try std.testing.expect(remapped != null);
    second = remapped.?;
    try std.testing.expectEqual(@intFromPtr(second_ptr), @intFromPtr(second.ptr));
    try std.testing.expectEqual(@as(usize, 16), second.len);
    const used_after_remap = stack.used();
    try std.testing.expect(used_after_remap > used_after_resize);

    try std.testing.expect(!alloc_if.resize(first, 12));
    try std.testing.expectEqual(used_after_remap, stack.used());

    try std.testing.expect(stack.freeLast());
    try std.testing.expectEqual(used_after_first, stack.used());
    try std.testing.expect(stack.freeLast());
    try std.testing.expectEqual(@as(u32, 0), stack.used());
}

test "stack report tracks overflow and reset reuses memory" {
    // Verifies that failed growth updates diagnostics without advancing the cursor, and reset
    // rewinds the stack so the first allocation address is reused deterministically.
    var stack = try Stack.init(std.testing.allocator, 32);
    defer stack.deinit();

    const alloc_if = stack.allocator();
    const first = try alloc_if.alloc(u8, 8);
    const first_ptr = @intFromPtr(first.ptr);

    const used_before_overflow = stack.used();
    try std.testing.expectError(error.OutOfMemory, stack.alloc(24, 8));
    try std.testing.expectEqual(used_before_overflow, stack.used());
    try std.testing.expect(stack.overflowCount() >= 1);
    try std.testing.expect(stack.highWater() > stack.capacity());

    const report = stack.report();
    try std.testing.expectEqual(@as(u64, used_before_overflow), report.used);
    try std.testing.expectEqual(@as(u64, 32), report.capacity);
    try std.testing.expect(report.high_water > report.capacity);
    try std.testing.expect(report.overflow_count >= 1);

    stack.reset();
    try std.testing.expectEqual(@as(u32, 0), stack.used());
    try std.testing.expect(stack.highWater() > stack.capacity());

    const second = try alloc_if.alloc(u8, 8);
    try std.testing.expectEqual(first_ptr, @intFromPtr(second.ptr));
}
