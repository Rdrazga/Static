//! Bounded byte accounting for allocators and growth policies.
//!
//! Key types: `Budget`, `BudgetedAllocator`, `Error`.
//! Usage pattern: create a `Budget` with `Budget.init`, optionally wrap an allocator with
//! `BudgetedAllocator.init` or `budgetedAllocator()`, then use `tryReserve`/`release` directly or
//! via the allocator interface. Call `lock()` (or `lockIn()`) after startup to mark the budget as
//! locked for callers that observe the flag; the lock bit is not consulted by the accounting
//! logic itself.
//! Thread safety: not thread-safe. Callers must serialise access externally.
//! Memory budget: `Budget` and `BudgetedAllocator` are stack-allocated value types with no heap
//! allocation of their own. All allocation goes through the wrapped parent allocator.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const CapacityReport = @import("capacity_report.zig").CapacityReport;

pub const Error = error{
    InvalidConfig,
    NoSpaceLeft,
    Overflow,
};

pub const Budget = struct {
    limit_bytes: u64,
    used_bytes: u64 = 0,
    locked: bool = false,
    high_water_bytes: u64 = 0,
    overflow_count: u32 = 0,

    pub fn init(limit_bytes: usize) Error!Budget {
        if (limit_bytes == 0) return error.InvalidConfig;
        // usize fits in u64 on all supported platforms; the widening is always safe.
        const out: Budget = .{ .limit_bytes = @as(u64, limit_bytes) };
        // Postcondition: the configured limit must be non-zero in the returned struct.
        assert(out.limit_bytes != 0);
        // Postcondition: used bytes must start at zero; no reservations have been made yet.
        assert(out.used_bytes == 0);
        return out;
    }

    pub fn lock(self: *Budget) void {
        assert(self.limit_bytes != 0);
        self.locked = true;
        // Postcondition: lock must be observable immediately after setting it.
        assert(self.locked);
    }

    pub fn lockIn(self: *Budget) void {
        self.lock();
    }

    pub fn isLocked(self: *const Budget) bool {
        assert(self.limit_bytes != 0);
        const locked = self.locked;
        // Pair assertion: the returned value must be consistent with the field from both
        // the true and false directions. A torn read or aliasing bug here could allow
        // reservations to bypass the lock check entirely.
        assert(locked == self.locked);
        return locked;
    }

    pub fn used(self: *const Budget) u64 {
        assert(self.limit_bytes != 0);
        // Postcondition: used bytes must never exceed the configured limit. An exceedance
        // means a reservation bypassed the bounds check in tryReserve.
        assert(self.used_bytes <= self.limit_bytes);
        return self.used_bytes;
    }

    pub fn limit(self: *const Budget) u64 {
        assert(self.limit_bytes != 0);
        // Postcondition: the limit must be at least as large as the bytes already reserved.
        // A limit smaller than used_bytes indicates the accounting is corrupt because
        // tryReserve enforces this invariant on every reservation.
        assert(self.limit_bytes >= self.used_bytes);
        return self.limit_bytes;
    }

    pub fn remaining(self: *const Budget) u64 {
        assert(self.limit_bytes != 0);
        assert(self.used_bytes <= self.limit_bytes);
        assert(self.high_water_bytes >= self.used_bytes);
        return self.limit_bytes - self.used_bytes;
    }

    pub fn overflowCount(self: *const Budget) u32 {
        assert(self.limit_bytes != 0);
        // Pair assertion: if any overflow was recorded, the high-water mark must exceed
        // the limit, because an overflow only occurs when the requested next value surpasses
        // limit_bytes inside tryReserve.
        if (self.overflow_count > 0) assert(self.high_water_bytes > self.limit_bytes);
        return self.overflow_count;
    }

    pub fn highWater(self: *const Budget) u64 {
        assert(self.limit_bytes != 0);
        assert(self.high_water_bytes >= self.used_bytes);
        return self.high_water_bytes;
    }

    pub fn tryReserve(self: *Budget, bytes: usize) Error!void {
        assert(self.limit_bytes != 0);
        assert(self.used_bytes <= self.limit_bytes);
        if (bytes == 0) return;

        // usize fits in u64 on all supported platforms; the widening is always safe.
        const next = std.math.add(u64, self.used_bytes, @as(u64, bytes)) catch return error.Overflow;
        if (next > self.limit_bytes) {
            self.overflow_count +|= 1;
            if (next > self.high_water_bytes) self.high_water_bytes = next;
            return error.NoSpaceLeft;
        }

        self.used_bytes = next;
        if (self.used_bytes > self.high_water_bytes) self.high_water_bytes = self.used_bytes;
        // Postcondition: used must not exceed limit after a successful reservation.
        assert(self.used_bytes <= self.limit_bytes);
    }

    pub fn release(self: *Budget, bytes: usize) void {
        assert(self.limit_bytes != 0);
        assert(self.used_bytes <= self.limit_bytes);
        if (bytes == 0) return;
        // usize fits in u64 on all supported platforms; the widening is always safe.
        const release_bytes = @as(u64, bytes);
        if (release_bytes > self.used_bytes) @panic("Budget.release: over-release");
        self.used_bytes -= release_bytes;
        assert(self.used_bytes <= self.limit_bytes);
    }

    pub fn reportBytes(self: *const Budget) CapacityReport {
        assert(self.limit_bytes != 0);
        assert(self.used_bytes <= self.limit_bytes);
        assert(self.high_water_bytes >= self.used_bytes);
        return .{
            .unit = .bytes,
            .used = self.used_bytes,
            .high_water = self.high_water_bytes,
            .capacity = self.limit_bytes,
            .overflow_count = self.overflow_count,
        };
    }
};

pub const BudgetedAllocator = struct {
    const Self = @This();

    parent: std.mem.Allocator,
    budget: *Budget,
    denied_last: bool = false,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(parent: std.mem.Allocator, budget: *Budget) Self {
        // Precondition: budget must be a valid non-null pointer.
        assert(@intFromPtr(budget) != 0);
        const out: Self = .{
            .parent = parent,
            .budget = budget,
            .denied_last = false,
        };
        // Postcondition: denied_last must start false since no allocation has been attempted.
        assert(!out.denied_last);
        return out;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        assert(@intFromPtr(self) != 0);
        const alloc_if: std.mem.Allocator = .{ .ptr = self, .vtable = &vtable };
        // Postcondition: the vtable must be the one associated with this type.
        assert(alloc_if.vtable == &vtable);
        return alloc_if;
    }

    pub fn takeDeniedLast(self: *Self) bool {
        // Returns `true` only when the budget rejected the last allocation attempt (not when the parent OOMed).
        const value = self.denied_last;
        self.denied_last = false;
        // Postcondition: denied_last must be false after consumption.
        assert(!self.denied_last);
        return value;
    }

    pub fn takeDeniedFromAllocator(a: std.mem.Allocator) bool {
        // Precondition: the allocator pointer must be non-null.
        assert(@intFromPtr(a.ptr) != 0);
        if (a.vtable != &vtable) return false;
        const self: *Self = @ptrCast(@alignCast(a.ptr));
        return self.takeDeniedLast();
    }

    fn reserveGrowth(self: *Self, old_len: usize, new_len: usize) bool {
        // Precondition: budget must be non-null.
        assert(@intFromPtr(self.budget) != 0);
        if (new_len <= old_len) return true;
        const delta = new_len - old_len;
        self.budget.tryReserve(delta) catch {
            self.denied_last = true;
            return false;
        };
        // Postcondition: on success, denied_last must be false (a successful reserve is not a denial).
        assert(!self.denied_last);
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.denied_last = false;

        self.budget.tryReserve(len) catch {
            self.denied_last = true;
            return null;
        };

        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse {
            self.budget.release(len);
            return null;
        };
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.denied_last = false;

        if (!self.reserveGrowth(memory.len, new_len)) return false;
        const grew = new_len > memory.len;

        const ok = self.parent.rawResize(memory, alignment, new_len, ret_addr);
        if (!ok and grew) {
            self.budget.release(new_len - memory.len);
            return false;
        }
        if (ok and new_len < memory.len) {
            self.budget.release(memory.len - new_len);
        }
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.denied_last = false;

        if (!self.reserveGrowth(memory.len, new_len)) return null;
        const grew = new_len > memory.len;

        const out = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            if (grew) self.budget.release(new_len - memory.len);
            return null;
        };
        if (new_len < memory.len) {
            self.budget.release(memory.len - new_len);
        }
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.budget.release(memory.len);
    }
};

pub fn budgetedAllocator(parent: std.mem.Allocator, budget: *Budget) BudgetedAllocator {
    // Precondition: budget must be non-null.
    assert(@intFromPtr(budget) != 0);
    const out = BudgetedAllocator.init(parent, budget);
    // Postcondition: the wrapper must reference the same budget pointer passed in.
    assert(out.budget == budget);
    return out;
}

test "budget reserve/release and lock-in is deterministic" {
    // Verifies budget accounting and lock flag behavior without depending on allocator plumbing.
    var budget = try Budget.init(16);
    try budget.tryReserve(8);
    try testing.expectEqual(@as(u64, 8), budget.used());
    budget.lock();
    try testing.expect(budget.isLocked());
    try testing.expectError(error.NoSpaceLeft, budget.tryReserve(9));
    budget.release(3);
    try testing.expectEqual(@as(u64, 5), budget.used());
}

test "budget init rejects zero limit" {
    // Verifies the public constructor rejects a nonsensical zero-byte budget up front.
    try testing.expectError(error.InvalidConfig, Budget.init(0));
}

fn isOverReleaseChild() bool {
    var env_map = std.process.Environ.createMap(testing.environ, testing.allocator) catch return false;
    defer env_map.deinit();
    return env_map.get(over_release_child_env) != null;
}

fn currentExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
            const path_w = std.os.windows.kernel32.GetModuleFileNameW(null, &path_w_buf, path_w_buf.len);
            return std.unicode.utf16LeToUtf8Alloc(allocator, path_w_buf[0..path_w]);
        },
        .linux, .serenity => {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = try std.Io.Dir.readLinkAbsolute(testing.io, "/proc/self/exe", path_buf[0..]);
            return allocator.dupe(u8, path_buf[0..len]);
        },
        else => return error.Unavailable,
    }
}

const over_release_child_env = "STATIC_MEMORY_BUDGET_OVER_RELEASE_CHILD";

test "budget release panics on over-release" {
    if (isOverReleaseChild()) {
        var budget = try Budget.init(4);
        try budget.tryReserve(1);
        budget.release(2);
        return;
    }

    if (builtin.os.tag != .windows and builtin.os.tag != .linux and builtin.os.tag != .serenity) {
        return error.SkipZigTest;
    }

    var env_map = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env_map.deinit();
    try env_map.put(over_release_child_env, "1");

    const exe_path = try currentExePathAlloc(testing.allocator);
    defer testing.allocator.free(exe_path);

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{exe_path},
        .environ_map = &env_map,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try testing.expect(code != 0),
        else => {},
    }
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Budget.release: over-release") != null);
}

test "budgeted allocator sets denied_last on budget rejection" {
    // Verifies that budget rejection is observable via `takeDeniedLast()` while parent allocator OOM is not.
    var backing = [_]u8{0} ** 32;
    var fba = std.heap.FixedBufferAllocator.init(&backing);

    var budget = try Budget.init(8);
    var wrapper = BudgetedAllocator.init(fba.allocator(), &budget);
    const a = wrapper.allocator();

    const first = try a.alloc(u8, 4);
    defer a.free(first);

    try testing.expectEqual(@as(u64, 4), budget.used());
    try testing.expect(!wrapper.takeDeniedLast());

    try testing.expectError(error.OutOfMemory, a.alloc(u8, 9));
    try testing.expect(wrapper.takeDeniedLast());
}

test "budgeted allocator takeDeniedFromAllocator consumes denied_last" {
    // Verifies the helper path observes the same denial state as the wrapper and clears it on read.
    var backing = [_]u8{0} ** 32;
    var fba = std.heap.FixedBufferAllocator.init(&backing);

    var budget = try Budget.init(8);
    var wrapper = BudgetedAllocator.init(fba.allocator(), &budget);
    const a = wrapper.allocator();

    const first = try a.alloc(u8, 4);
    defer a.free(first);

    try testing.expectError(error.OutOfMemory, a.alloc(u8, 9));
    try testing.expect(BudgetedAllocator.takeDeniedFromAllocator(a));
    try testing.expect(!wrapper.takeDeniedLast());
}

test "budgetedAllocator helper preserves budget pointer and allocator behavior" {
    // Verifies the helper constructor keeps the caller's budget and produces a working wrapper.
    var backing = [_]u8{0} ** 32;
    var fba = std.heap.FixedBufferAllocator.init(&backing);

    var budget = try Budget.init(8);
    var wrapper = budgetedAllocator(fba.allocator(), &budget);
    try testing.expect(wrapper.budget == &budget);

    const a = wrapper.allocator();
    const first = try a.alloc(u8, 4);
    defer a.free(first);

    try testing.expectEqual(@as(u64, 4), budget.used());
    try testing.expect(!BudgetedAllocator.takeDeniedFromAllocator(a));
}

test "budgeted allocator clears denied_last on parent OOM during resize" {
    // Verifies that growth reservations are rolled back cleanly when the parent allocator cannot resize in place.
    var backing = [_]u8{0} ** 4;
    var fba = std.heap.FixedBufferAllocator.init(&backing);

    var budget = try Budget.init(8);
    var wrapper = BudgetedAllocator.init(fba.allocator(), &budget);
    const a = wrapper.allocator();

    const first = try a.alloc(u8, 4);
    defer a.free(first);

    try testing.expect(!wrapper.takeDeniedLast());
    try testing.expect(!a.resize(first, 6));
    try testing.expect(!wrapper.takeDeniedLast());
    try testing.expectEqual(@as(u64, 4), budget.used());
    try testing.expectEqual(@as(u64, 6), budget.highWater());
    try testing.expectEqual(@as(u32, 0), budget.overflowCount());
}

test "budgeted allocator remap sets denied_last on budget rejection" {
    // Verifies that remap preserves accounting and exposes a budget denial without mutating state.
    var backing = [_]u8{0} ** 8;
    var fba = std.heap.FixedBufferAllocator.init(&backing);

    var budget = try Budget.init(5);
    var wrapper = BudgetedAllocator.init(fba.allocator(), &budget);
    const a = wrapper.allocator();

    const mem = try a.alloc(u8, 4);
    defer a.free(mem);

    const remapped = a.remap(mem, 6);
    try testing.expect(remapped == null);
    try testing.expect(wrapper.takeDeniedLast());
    try testing.expectEqual(@as(u64, 4), budget.used());
    try testing.expectEqual(@as(u64, 6), budget.highWater());
    try testing.expectEqual(@as(u32, 1), budget.overflowCount());
}

test "budgeted allocator remap clears denied_last on parent OOM" {
    // Verifies that a parent remap failure rolls back the reservation and does not surface as a budget denial.
    var backing = [_]u8{0} ** 4;
    var fba = std.heap.FixedBufferAllocator.init(&backing);

    var budget = try Budget.init(8);
    var wrapper = BudgetedAllocator.init(fba.allocator(), &budget);
    const a = wrapper.allocator();

    const mem = try a.alloc(u8, 4);
    defer a.free(mem);

    const remapped = a.remap(mem, 6);
    try testing.expect(remapped == null);
    try testing.expect(!wrapper.takeDeniedLast());
    try testing.expectEqual(@as(u64, 4), budget.used());
    try testing.expectEqual(@as(u64, 6), budget.highWater());
    try testing.expectEqual(@as(u32, 0), budget.overflowCount());
}

test "budget tracks high-water on failed reservation attempts" {
    // Verifies that `high_water_bytes` reflects peak attempted usage even when the reservation was denied.
    var budget = try Budget.init(16);
    try budget.tryReserve(8);

    try testing.expectError(error.NoSpaceLeft, budget.tryReserve(9));
    try testing.expectEqual(@as(u32, 1), budget.overflowCount());
    try testing.expectEqual(@as(u64, 17), budget.highWater());
    try testing.expectEqual(@as(u64, 8), budget.used());
}

test "budget tryReserve returns Overflow on arithmetic overflow" {
    // Verifies that arithmetic overflow is surfaced as an explicit error (and does not corrupt accounting).
    var budget: Budget = .{
        .limit_bytes = std.math.maxInt(u64),
        .used_bytes = std.math.maxInt(u64) - 1,
        .locked = false,
        .high_water_bytes = std.math.maxInt(u64) - 1,
        .overflow_count = 0,
    };

    try testing.expectError(error.Overflow, budget.tryReserve(10));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), budget.used());
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), budget.highWater());
    try testing.expectEqual(@as(u32, 0), budget.overflowCount());
}
