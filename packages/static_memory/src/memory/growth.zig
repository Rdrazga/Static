//! Growth budgeting for allocators that may perform dynamic allocation at runtime.
//!
//! Key types: `Guard`, `GuardedAllocator`, `GrowthPolicy`, `GrowthError`.
//! Usage pattern: choose a `GrowthPolicy` (`allow`, `deny`, or `allow_with_budget`), construct a
//! `GuardedAllocator` via `GuardedAllocator.init`, call `lock()` after startup to enforce the
//! policy, then use `allocator()` for allocation. Check `takeDeniedLast()` to distinguish policy
//! rejections from backing-allocator OOM.
//! Thread safety: not thread-safe. Callers must serialise access externally.
//! Memory budget: growth accounting is monotonic — it counts total bytes allocated after lock, not
//! instantaneous usage. Freed or shrunk memory does not reduce the growth counter.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const GrowthPolicy = union(enum) {
    allow,
    deny,
    allow_with_budget: u64,

    pub fn allowsDynamicAllocation(self: GrowthPolicy) bool {
        const result = switch (self) {
            .allow => true,
            .deny => false,
            .allow_with_budget => true,
        };
        // Pair assertion: `.deny` must always return false; allowing dynamic allocation
        // on a deny policy would silently bypass the growth guard's purpose.
        if (self == .deny) assert(!result);
        // Pair assertion: `.allow` must always return true.
        if (self == .allow) assert(result);
        return result;
    }
};

pub const GrowthError = error{NoSpaceLeft};

pub const Guard = struct {
    policy: GrowthPolicy,
    locked: bool = false,
    used_growth_bytes: u64 = 0,
    budget_growth_bytes: u64 = 0,

    pub fn init(policy: GrowthPolicy) Guard {
        const out = Guard{
            .policy = policy,
            .locked = false,
            .used_growth_bytes = 0,
            .budget_growth_bytes = switch (policy) {
                .allow => 0,
                .deny => 0,
                .allow_with_budget => |b| b,
            },
        };
        assert(!out.locked);
        assert(out.used_growth_bytes == 0);
        return out;
    }

    pub fn lock(self: *Guard) void {
        self.locked = true;
        assert(self.locked);
    }

    pub fn unlock(self: *Guard) void {
        self.locked = false;
        assert(!self.locked);
    }

    pub fn isLocked(self: *const Guard) bool {
        const locked = self.locked;
        // Pair assertion: the returned bool must be consistent with the stored field from
        // both the true and false directions. A discrepancy would indicate a torn read or
        // aliasing bug that could silently bypass policy enforcement.
        assert(locked == self.locked);
        assert(!locked == !self.locked);
        return locked;
    }

    pub fn usedBytes(self: *const Guard) u64 {
        const used = self.used_growth_bytes;
        // Postcondition: when a budget is configured, used growth must not exceed the budget.
        // Exceeding the budget means a commit bypassed canConsumeGrowthBytes, which is a
        // programmer error.
        if (self.policy == .allow_with_budget) {
            assert(used <= self.budget_growth_bytes);
        }
        // Postcondition: the returned value must equal the stored field (no silent transform).
        assert(used == self.used_growth_bytes);
        return used;
    }

    pub fn remainingBudget(self: *const Guard) u64 {
        const remaining = switch (self.policy) {
            .allow, .deny => @as(u64, 0),
            .allow_with_budget => blk: {
                if (self.used_growth_bytes < self.budget_growth_bytes) {
                    break :blk self.budget_growth_bytes - self.used_growth_bytes;
                } else {
                    break :blk @as(u64, 0);
                }
            },
        };
        // Postcondition: remaining budget cannot exceed total budget (used >= 0, always).
        if (self.policy == .allow_with_budget) {
            assert(remaining <= self.budget_growth_bytes);
        }
        // Postcondition: remaining + used == budget for the budget policy (when not over-limit).
        // When used exceeds the budget (possible if budget was reduced after commit), remaining
        // is clamped to 0, so the sum invariant does not hold in that edge case.
        if (self.policy == .allow_with_budget) {
            if (self.used_growth_bytes <= self.budget_growth_bytes) {
                assert(remaining + self.used_growth_bytes == self.budget_growth_bytes);
            }
        }
        return remaining;
    }

    pub fn canConsumeGrowthBytes(self: *const Guard, additional_bytes: u64) bool {
        if (!self.locked) return true;
        if (additional_bytes == 0) return true;

        const result = switch (self.policy) {
            .allow => true,
            .deny => false,
            .allow_with_budget => blk: {
                const next = std.math.add(u64, self.used_growth_bytes, additional_bytes) catch break :blk false;
                break :blk next <= self.budget_growth_bytes;
            },
        };
        // Pair assertion: `.deny` policy must always reject growth while locked; `.allow` must always permit it.
        if (self.locked) {
            if (self.policy == .deny) assert(!result);
            if (self.policy == .allow) assert(result);
        }
        return result;
    }

    pub fn commitGrowthBytes(self: *Guard, additional_bytes: u64) void {
        if (self.locked) assert(self.canConsumeGrowthBytes(additional_bytes));

        if (!self.locked) return;
        if (additional_bytes == 0) return;

        const old_used = self.used_growth_bytes;
        switch (self.policy) {
            .allow => {},
            .deny => {
                // commitGrowthBytes is only called after canConsumeGrowthBytes returns true.
                // canConsumeGrowthBytes returns false for .deny when locked, so reaching
                // here means either the caller violated the contract or we are unlocked
                // (handled by the early return above). This branch is unreachable.
                unreachable;
            },
            .allow_with_budget => {
                // Overflow is unreachable: the precondition assert above verified
                // canConsumeGrowthBytes, which performs this same checked addition
                // and returns false on overflow. Saturating here would mask bugs.
                const next = std.math.add(u64, self.used_growth_bytes, additional_bytes) catch unreachable;
                assert(next <= self.budget_growth_bytes);
                self.used_growth_bytes = next;
            },
        }
        assert(self.used_growth_bytes >= old_used);
    }

    pub fn tryConsumeGrowthBytes(self: *Guard, additional_bytes: u64) GrowthError!void {
        const old_used = self.used_growth_bytes;
        if (!self.canConsumeGrowthBytes(additional_bytes)) return error.NoSpaceLeft;
        self.commitGrowthBytes(additional_bytes);
        // Postcondition: used bytes must be >= the old value (monotonically increasing).
        assert(self.used_growth_bytes >= old_used);
        // Postcondition: if locked and the policy has a budget, used must not exceed it.
        if (self.locked) {
            if (self.policy == .allow_with_budget) {
                assert(self.used_growth_bytes <= self.budget_growth_bytes);
            }
        }
    }
};

pub const GuardedAllocator = struct {
    const Self = @This();

    inner: std.mem.Allocator,
    guard: Guard,
    denied_last: bool = false,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(inner: std.mem.Allocator, policy: GrowthPolicy) Self {
        const out: Self = .{
            .inner = inner,
            .guard = Guard.init(policy),
            .denied_last = false,
        };
        // Postcondition: guard must start unlocked so pre-lock allocations bypass policy.
        assert(!out.guard.locked);
        // Postcondition: denied_last must start false; no allocation has been attempted yet.
        assert(!out.denied_last);
        return out;
    }

    pub fn lock(self: *Self) void {
        self.guard.lock();
        // Postcondition: the underlying guard must now be locked.
        assert(self.guard.isLocked());
    }

    pub fn unlock(self: *Self) void {
        self.guard.unlock();
        // Postcondition: the underlying guard must now be unlocked.
        assert(!self.guard.isLocked());
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        assert(@intFromPtr(self) != 0);
        const alloc_if: std.mem.Allocator = .{ .ptr = self, .vtable = &vtable };
        // Postcondition: the vtable must be the one associated with this type; a mismatch
        // would silently route calls to the wrong dispatch functions.
        assert(alloc_if.vtable == &vtable);
        return alloc_if;
    }

    pub fn takeDeniedLast(self: *Self) bool {
        // Returns `true` only when the growth policy rejected the last attempt (not when the inner allocator OOMed).
        const value = self.denied_last;
        self.denied_last = false;
        // Postcondition: denied_last must be false after consumption.
        assert(!self.denied_last);
        return value;
    }

    pub fn takeDeniedFromAllocator(a: std.mem.Allocator) bool {
        if (a.vtable != &vtable) return false;
        const self: *Self = @ptrCast(@alignCast(a.ptr));
        return self.takeDeniedLast();
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.denied_last = false;

        const add_u64: u64 = @intCast(len);
        if (!self.guard.canConsumeGrowthBytes(add_u64)) {
            self.denied_last = true;
            return null;
        }

        const ptr = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.guard.commitGrowthBytes(add_u64);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.denied_last = false;

        if (new_len <= memory.len) {
            return self.inner.rawResize(memory, alignment, new_len, ret_addr);
        }

        const delta_u64: u64 = @intCast(new_len - memory.len);
        if (!self.guard.canConsumeGrowthBytes(delta_u64)) {
            self.denied_last = true;
            return false;
        }

        const ok = self.inner.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) self.guard.commitGrowthBytes(delta_u64);
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.denied_last = false;

        if (new_len <= memory.len) {
            return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
        }

        const delta_u64: u64 = @intCast(new_len - memory.len);
        if (!self.guard.canConsumeGrowthBytes(delta_u64)) {
            self.denied_last = true;
            return null;
        }

        const ptr = self.inner.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.guard.commitGrowthBytes(delta_u64);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

pub fn additionalBytesForRealloc(comptime Elem: type, old_len: usize, new_len: usize) u64 {
    if (new_len <= old_len) return 0;
    if (@sizeOf(Elem) == 0) return 0;

    const delta = new_len - old_len;
    const result = std.math.mul(u64, @as(u64, @intCast(delta)), @as(u64, @intCast(@sizeOf(Elem)))) catch {
        return std.math.maxInt(u64);
    };
    // Postcondition: the result must be non-zero when elements have positive size and new > old.
    assert(result > 0);
    // Postcondition: the result must not exceed maxInt(u64) (saturated at that value on overflow).
    assert(result <= std.math.maxInt(u64));
    return result;
}

pub fn additionalBytesForBitSetResize(old_max: u32, new_max: u32) u64 {
    if (new_max <= old_max) return 0;

    const old_words: u32 = (old_max + 63) / 64;
    const new_words: u32 = (new_max + 63) / 64;
    if (new_words <= old_words) return 0;

    const delta_words: u32 = new_words - old_words;
    const result = std.math.mul(u64, @as(u64, delta_words), @as(u64, @sizeOf(u64))) catch {
        return std.math.maxInt(u64);
    };
    // Postcondition: the result must be non-zero when words increased.
    assert(result > 0);
    // Postcondition: result must be a multiple of @sizeOf(u64) because bitset words are u64.
    assert(result % @as(u64, @sizeOf(u64)) == 0);
    return result;
}

test "guard policy enforcement" {
    // Verifies policy behavior for allow/deny/budget and validates accounting when locked.
    var allow_guard = Guard.init(.allow);
    allow_guard.lock();
    try testing.expect(allow_guard.canConsumeGrowthBytes(1000));

    var deny_guard = Guard.init(.deny);
    deny_guard.lock();
    try testing.expect(!deny_guard.canConsumeGrowthBytes(1));

    var budget_guard = Guard.init(.{ .allow_with_budget = 100 });
    budget_guard.lock();
    try testing.expect(budget_guard.canConsumeGrowthBytes(50));
    try testing.expect(budget_guard.canConsumeGrowthBytes(100));
    try testing.expect(!budget_guard.canConsumeGrowthBytes(101));

    try budget_guard.tryConsumeGrowthBytes(50);
    try testing.expectEqual(@as(u64, 50), budget_guard.usedBytes());
    try testing.expectEqual(@as(u64, 50), budget_guard.remainingBudget());
    try testing.expectError(error.NoSpaceLeft, budget_guard.tryConsumeGrowthBytes(51));
}

test "guard unlocked permits all allocations" {
    // Verifies that policy checks are bypassed before `lock()` is called.
    var guard = Guard.init(.deny);
    try testing.expect(guard.canConsumeGrowthBytes(1));
    try testing.expect(guard.canConsumeGrowthBytes(1_000_000));
}

test "guarded allocator sets denied_last on policy rejection" {
    // Verifies that guarded allocators surface policy rejections through `takeDeniedLast()`.
    var guarded = GuardedAllocator.init(testing.allocator, .{ .allow_with_budget = 16 });
    const a = guarded.allocator();

    // Before lock: not charged.
    const init_mem = try a.alloc(u8, 1024);
    a.free(init_mem);

    guarded.lock();

    const runtime_mem = try a.alloc(u8, 8);
    defer a.free(runtime_mem);
    try testing.expect(!guarded.takeDeniedLast());

    // Over budget.
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 32));
    try testing.expect(guarded.takeDeniedLast());
}

test "additionalBytesForRealloc computes delta bytes" {
    // Verifies that the helper returns `(new_len - old_len) * @sizeOf(Elem)` and treats zero-sized elements as free.
    try testing.expectEqual(@as(u64, 0), additionalBytesForRealloc(void, 0, 100));
    try testing.expectEqual(@as(u64, 10), additionalBytesForRealloc(u8, 0, 10));
    try testing.expectEqual(@as(u64, 16), additionalBytesForRealloc(u64, 1, 3));

    if (@sizeOf(usize) == 8) {
        const huge = additionalBytesForRealloc(u64, 0, std.math.maxInt(usize));
        try testing.expectEqual(std.math.maxInt(u64), huge);
    }
}

test "additionalBytesForBitSetResize computes delta words" {
    // Verifies the word-based delta for bitset growth (rounded up to 64-bit words).
    try testing.expectEqual(@as(u64, 0), additionalBytesForBitSetResize(0, 0));
    try testing.expectEqual(@as(u64, 0), additionalBytesForBitSetResize(63, 64));

    const one_word: u64 = @sizeOf(u64);
    try testing.expectEqual(one_word, additionalBytesForBitSetResize(64, 65));
    try testing.expectEqual(one_word, additionalBytesForBitSetResize(1, 65));
}
