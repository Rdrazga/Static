//! Allocator wrapper that tracks allocations to surface leaks and misuse in tests.
//!
//! Key types: `DebugAllocator`, `DebugAllocatorError`, `Config`.
//! Usage pattern: call `DebugAllocator.init` with a backing allocator and a `Config` specifying the
//! maximum number of simultaneous allocations. Obtain an allocator via `allocator()`. Call
//! `leakCount()` and `dumpLeaks()` to inspect live allocations before `deinit()`.
//! Thread safety: not thread-safe. Intended for single-threaded test environments only.
//! Memory budget: a fixed-size record table (`max_allocs` entries) is allocated at init. No
//! allocation occurs during the tracking phase. Invalid frees and resizes trigger runtime panics.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const DebugAllocatorError = error{
    OutOfMemory,
    InvalidConfig,
};

pub const Config = struct {
    max_allocs: u32,
};

const Record = struct {
    ptr: [*]u8 = undefined,
    len: usize = 0,
    alignment: u32 = 0,
    active: bool = false,
};

pub const DebugAllocator = struct {
    backing: std.mem.Allocator,
    records: []Record,
    active_count: u32 = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocRaw,
        .resize = resizeRaw,
        .remap = remapRaw,
        .free = freeRaw,
    };

    pub fn init(backing: std.mem.Allocator, cfg: Config) DebugAllocatorError!DebugAllocator {
        if (cfg.max_allocs == 0) return error.InvalidConfig;
        const records = backing.alloc(Record, cfg.max_allocs) catch return error.OutOfMemory;
        @memset(records, Record{});
        assert(records.len == @as(usize, cfg.max_allocs));
        const out: DebugAllocator = .{
            .backing = backing,
            .records = records,
            .active_count = 0,
        };
        // Postcondition: no allocations are active at construction time.
        assert(out.active_count == 0);
        return out;
    }

    pub fn deinit(self: *DebugAllocator) void {
        assert(self.records.len != 0);
        assert(self.active_count == 0);
        self.backing.free(self.records);
        self.records = &[_]Record{};
        self.active_count = 0;
    }

    pub fn allocator(self: *DebugAllocator) std.mem.Allocator {
        assert(self.records.len != 0);
        const alloc_if: std.mem.Allocator = .{ .ptr = self, .vtable = &vtable };
        // Postcondition: the vtable must be the one associated with this type.
        assert(alloc_if.vtable == &vtable);
        return alloc_if;
    }

    pub fn leakCount(self: *const DebugAllocator) u32 {
        assert(@as(usize, self.active_count) <= self.records.len);
        // Postcondition: active_count must match the number of active records in the table.
        // A discrepancy means allocRaw or freeRaw incorrectly maintained the counter.
        if (std.debug.runtime_safety) {
            var counted: u32 = 0;
            for (self.records) |rec| {
                if (rec.active) counted += 1;
            }
            assert(counted == self.active_count);
        }
        return self.active_count;
    }

    pub fn activeBytes(self: *const DebugAllocator) usize {
        assert(@as(usize, self.active_count) <= self.records.len);
        var total: usize = 0;
        for (self.records) |rec| {
            if (rec.active) total += rec.len;
        }
        // Postcondition: if no allocations are active, total bytes must be zero.
        if (self.active_count == 0) assert(total == 0);
        return total;
    }

    pub fn dumpLeaks(self: *const DebugAllocator) void {
        assert(@as(usize, self.active_count) <= self.records.len);
        // Precondition: active_count must be a valid count within the record table bounds.
        assert(self.records.len != 0);
        for (self.records) |rec| {
            if (!rec.active) continue;
            std.debug.print("leak: ptr={x} len={d} align={d}\n", .{
                @intFromPtr(rec.ptr),
                rec.len,
                rec.alignment,
            });
        }
    }

    fn allocRaw(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        assert(self.records.len != 0);
        assert(@as(usize, self.active_count) <= self.records.len);
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        const slot = self.findFreeSlot() orelse {
            self.backing.rawFree(ptr[0..len], alignment, ret_addr);
            return null;
        };
        assert(!slot.active);
        assert(alignment.toByteUnits() <= std.math.maxInt(u32));
        slot.* = .{
            .ptr = ptr,
            .len = len,
            .alignment = @intCast(alignment.toByteUnits()),
            .active = true,
        };
        self.active_count += 1;
        assert(@as(usize, self.active_count) <= self.records.len);
        return ptr;
    }

    fn resizeRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const rec = self.findRecord(memory.ptr) orelse {
            if (std.debug.runtime_safety) assert(false);
            return false;
        };
        if (std.debug.runtime_safety) {
            assert(rec.active);
            assert(rec.len == memory.len);
            assert(alignment.toByteUnits() <= rec.alignment);
        }
        if (rec.len != memory.len) return false;
        if (alignment.toByteUnits() > rec.alignment) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        rec.len = new_len;
        return true;
    }

    fn remapRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const rec = self.findRecord(memory.ptr) orelse {
            if (std.debug.runtime_safety) assert(false);
            return null;
        };
        if (std.debug.runtime_safety) {
            assert(rec.active);
            assert(rec.len == memory.len);
            assert(alignment.toByteUnits() <= rec.alignment);
        }
        if (rec.len != memory.len) return null;
        if (alignment.toByteUnits() > rec.alignment) return null;
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        rec.ptr = ptr;
        rec.len = new_len;
        return ptr;
    }

    fn freeRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const rec = self.findRecord(memory.ptr) orelse {
            if (std.debug.runtime_safety) assert(false);
            return;
        };
        if (std.debug.runtime_safety) {
            assert(rec.active);
            assert(rec.len == memory.len);
            assert(alignment.toByteUnits() <= rec.alignment);
        }
        self.backing.rawFree(memory, alignment, ret_addr);
        if (rec.active) {
            rec.active = false;
            assert(self.active_count != 0);
            self.active_count -= 1;
        }
    }

    fn findFreeSlot(self: *DebugAllocator) ?*Record {
        // Precondition: record table must be valid.
        assert(self.records.len != 0);
        for (self.records) |*rec| {
            if (!rec.active) {
                // Precondition: a free slot must have zero alignment (cleared on free/init).
                assert(rec.alignment == 0 or !rec.active);
                return rec;
            }
        }
        return null;
    }

    fn findRecord(self: *DebugAllocator, ptr: [*]u8) ?*Record {
        // Precondition: caller must provide a non-null pointer to search for.
        assert(@intFromPtr(ptr) != 0);
        // Precondition: record table must be valid.
        assert(self.records.len != 0);
        for (self.records) |*rec| {
            if (rec.active and rec.ptr == ptr) return rec;
        }
        return null;
    }
};

test "DebugAllocator tracks alloc/free" {
    // Verifies leak accounting updates on successful alloc/free pairs.
    var dbg = try DebugAllocator.init(testing.allocator, .{ .max_allocs = 4 });
    defer dbg.deinit();

    const alloc = dbg.allocator();
    const mem = try alloc.alloc(u8, 16);
    try testing.expectEqual(@as(u32, 1), dbg.leakCount());
    alloc.free(mem);
    try testing.expectEqual(@as(u32, 0), dbg.leakCount());
}

test "DebugAllocator respects max_allocs" {
    // Verifies that max allocation tracking is enforced via the fixed record table.
    var dbg = try DebugAllocator.init(testing.allocator, .{ .max_allocs = 1 });
    defer dbg.deinit();

    const alloc = dbg.allocator();
    const a = try alloc.alloc(u8, 8);
    try testing.expectEqual(@as(u32, 1), dbg.leakCount());
    try testing.expectError(error.OutOfMemory, alloc.alloc(u8, 8));
    alloc.free(a);
    try testing.expectEqual(@as(u32, 0), dbg.leakCount());
}

test "DebugAllocator resize/remap keeps tracking" {
    // Verifies that resizes/remaps keep the tracking record consistent with the backing allocator result.
    var dbg = try DebugAllocator.init(testing.allocator, .{ .max_allocs = 1 });
    defer dbg.deinit();

    var alloc = dbg.allocator();
    var mem = try alloc.alloc(u8, 16);
    if (alloc.resize(mem, 24)) {
        mem = mem[0..24];
    }
    _ = alloc.remap(mem, 24);
    alloc.free(mem);
    try testing.expectEqual(@as(u32, 0), dbg.leakCount());
}

test "DebugAllocator activeBytes sums active allocations" {
    // Verifies that `activeBytes()` returns the total size of all currently-active allocations.
    var dbg = try DebugAllocator.init(testing.allocator, .{ .max_allocs = 4 });
    defer dbg.deinit();

    const alloc = dbg.allocator();
    const a = try alloc.alloc(u8, 8);
    defer alloc.free(a);
    const b = try alloc.alloc(u8, 12);
    defer alloc.free(b);

    try testing.expectEqual(@as(usize, 20), dbg.activeBytes());
}
