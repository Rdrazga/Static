//! Dynamic array (Vec) with optional memory budget integration.
//!
//! Key type: `Vec(T)`. A heap-allocated growable array. Integrates with `static_memory`
//! Budget to enforce per-subsystem memory caps. Capacity growth is controlled by the
//! configured growth strategy.
//!
//! Public capacity requests are bounded to `u32` elements even though the read-only
//! `len()` / `capacity()` accessors report `usize`. This keeps the budgeted and
//! non-budgeted growth paths on the same stable operating-error contract.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const testing = std.testing;
const memory = @import("static_memory");
const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    InvalidConfig,
    Overflow,
};

pub fn Vec(comptime T: type) type {
    comptime {
        if (@sizeOf(T) == 0) {
            @compileError("Vec does not support zero-sized element types");
        }
    }
    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Config = struct {
            initial_capacity: u32 = 0,
            budget: ?*memory.budget.Budget,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        budget_reserved_capacity: u32 = 0,
        storage: std.ArrayListUnmanaged(T) = .empty,

        const max_capacity_supported: usize = std.math.maxInt(u32);

        pub fn init(allocator: std.mem.Allocator, config: Config) Error!Self {
            var self: Self = .{
                .allocator = allocator,
                .budget = config.budget,
            };
            if (config.initial_capacity > 0) {
                try self.ensureCapacity(config.initial_capacity);
            }
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            if (self.budget) |budget| {
                assert(self.budget_reserved_capacity == self.storage.capacity);
                budget.release(bytesForCapacityExact(self.budget_reserved_capacity));
            }
            self.storage.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            self.assertInvariants();
            return self.storage.items.len;
        }

        pub fn capacity(self: *const Self) usize {
            self.assertInvariants();
            return self.storage.capacity;
        }

        pub fn items(self: *Self) []T {
            self.assertInvariants();
            return self.storage.items;
        }

        pub fn itemsConst(self: *const Self) []const T {
            self.assertInvariants();
            return self.storage.items;
        }

        pub fn append(self: *Self, value: T) Error!void {
            self.assertInvariants();
            const before_len = self.storage.items.len;
            // Defensive: physically unreachable but guards the arithmetic contract.
            const needed_capacity = std.math.add(usize, before_len, 1) catch return error.Overflow;
            try self.ensureCapacity(needed_capacity);
            assert(self.storage.capacity > before_len);
            self.storage.appendAssumeCapacity(value);
            assert(self.storage.items.len == before_len + 1);
            self.assertInvariants();
        }

        /// Bulk-append a slice of items without allocating. The caller must have
        /// already reserved sufficient capacity via `ensureCapacity`. Overlap is
        /// allowed, so callers may append from a slice borrowed from this same
        /// Vec as long as no reallocation is needed. This keeps all storage field
        /// access inside Vec, avoiding direct coupling to ArrayListUnmanaged
        /// internals from external callers.
        pub fn appendSliceAssumeCapacity(self: *Self, src: []const T) void {
            self.assertInvariants();
            const before_len = self.storage.items.len;
            assert(self.storage.capacity >= before_len + src.len);
            const dst = self.storage.items.ptr;
            @memmove(dst[before_len..][0..src.len], src);
            self.storage.items.len = before_len + src.len;
            assert(self.storage.items.len == before_len + src.len);
            self.assertInvariants();
        }

        /// Ensures at least `n` elements of capacity. Uses geometric growth
        /// (via `ensureTotalCapacity`) for amortized O(1) appends.
        ///
        /// When a budget is active, reservations track the backing buffer size
        /// in bytes. We prefer geometric growth, but fall back to precise growth
        /// when the remaining budget cannot afford the geometric step.
        pub fn ensureCapacity(self: *Self, n: usize) Error!void {
            self.assertInvariants();
            if (n > max_capacity_supported) return error.Overflow;
            _ = bytesForCapacity(n) catch return error.Overflow;
            if (self.budget) |budget| {
                if (n <= self.budget_reserved_capacity) return;

                const old_capacity = self.budget_reserved_capacity;
                const candidate_capacity = growCapacityCandidate(old_capacity, n) catch return error.Overflow;

                const chosen_capacity = reserveAndChooseCapacity(budget, old_capacity, candidate_capacity, n) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.InvalidConfig => return error.InvalidConfig,
                    error.Overflow => return error.Overflow,
                };

                const new_bytes = bytesForCapacity(chosen_capacity) catch return error.Overflow;
                const old_bytes = bytesForCapacity(old_capacity) catch return error.Overflow;
                assert(new_bytes >= old_bytes);
                const delta = new_bytes - old_bytes;

                self.storage.ensureTotalCapacityPrecise(self.allocator, chosen_capacity) catch {
                    budget.release(delta);
                    return error.OutOfMemory;
                };
                // chosen_capacity is bounded by the usize to u32 narrowing assertion below because
                // bytesForCapacity already guards overflow at the top of ensureCapacity, so any
                // capacity that passes that check fits in a usize; the u32 bound is tighter and
                // is enforced here explicitly before the cast.
                assert(chosen_capacity <= max_capacity_supported);
                self.budget_reserved_capacity = @intCast(chosen_capacity);
                assert(self.storage.capacity == chosen_capacity);
                self.assertInvariants();
                return;
            }
            if (n <= self.storage.capacity) return;
            self.storage.ensureTotalCapacity(self.allocator, n) catch
                return error.OutOfMemory;
            assert(self.storage.capacity >= n);
            self.assertInvariants();
        }

        pub fn pop(self: *Self) ?T {
            self.assertInvariants();
            if (self.storage.items.len == 0) return null;
            const out = self.storage.pop();
            self.assertInvariants();
            return out;
        }

        /// Creates an independent copy with its own backing memory.
        /// Uses the same allocator and budget as the source.
        pub fn clone(self: *const Self) Error!Self {
            self.assertInvariants();
            const cap = self.storage.capacity;
            const len_val = self.storage.items.len;

            if (cap == 0) {
                return Self{
                    .allocator = self.allocator,
                    .budget = self.budget,
                };
            }

            if (self.budget) |budget| {
                const bytes = bytesForCapacity(cap) catch return error.Overflow;
                budget.tryReserve(bytes) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.InvalidConfig => return error.InvalidConfig,
                    error.Overflow => return error.Overflow,
                };
            }

            const new_buf = self.allocator.alloc(T, cap) catch {
                if (self.budget) |budget| {
                    budget.release(bytesForCapacityExact(cap));
                }
                return error.OutOfMemory;
            };
            @memcpy(new_buf[0..len_val], self.storage.items);

            var result: Self = .{
                .allocator = self.allocator,
                .budget = self.budget,
                .budget_reserved_capacity = self.budget_reserved_capacity,
                .storage = .{
                    .items = new_buf[0..len_val],
                    .capacity = cap,
                },
            };
            result.assertInvariants();
            return result;
        }

        /// Shrinks backing capacity to match the current logical length.
        /// Best-effort: if the allocator cannot shrink in-place, capacity
        /// stays unchanged. Budget is released proportionally.
        pub fn shrinkToFit(self: *Self) void {
            self.assertInvariants();
            const old_capacity = self.storage.capacity;
            self.storage.shrinkAndFree(self.allocator, self.storage.items.len);
            const new_capacity = self.storage.capacity;
            if (self.budget != null and new_capacity < old_capacity) {
                const released = bytesForCapacityExact(old_capacity) - bytesForCapacityExact(new_capacity);
                self.budget.?.release(released);
                assert(new_capacity <= std.math.maxInt(u32));
                self.budget_reserved_capacity = @intCast(new_capacity);
            }
            self.assertInvariants();
        }

        /// Resets the logical length to zero without releasing backing memory
        /// or budget reservation. Capacity and budget remain unchanged.
        pub fn clear(self: *Self) void {
            self.assertInvariants();
            self.storage.clearRetainingCapacity();
            assert(self.storage.items.len == 0);
            self.assertInvariants();
        }

        fn growCapacityCandidate(old_capacity: usize, required_capacity: usize) error{Overflow}!usize {
            assert(required_capacity > old_capacity);
            if (old_capacity == 0) return required_capacity;
            const doubled = std.math.mul(usize, old_capacity, 2) catch return error.Overflow;
            return @max(required_capacity, doubled);
        }

        fn reserveAndChooseCapacity(
            budget: *memory.budget.Budget,
            old_capacity: usize,
            candidate_capacity: usize,
            required_capacity: usize,
        ) memory.budget.Error!usize {
            assert(required_capacity > old_capacity);
            assert(candidate_capacity >= required_capacity);

            const old_bytes = try bytesForCapacity(old_capacity);
            const candidate_bytes = try bytesForCapacity(candidate_capacity);
            assert(candidate_bytes >= old_bytes);
            const candidate_delta = candidate_bytes - old_bytes;

            if (candidate_capacity == required_capacity) {
                try budget.tryReserve(candidate_delta);
                return candidate_capacity;
            }

            budget.tryReserve(candidate_delta) catch |err| switch (err) {
                error.NoSpaceLeft => {
                    const required_bytes = try bytesForCapacity(required_capacity);
                    assert(required_bytes >= old_bytes);
                    const required_delta = required_bytes - old_bytes;
                    try budget.tryReserve(required_delta);
                    return required_capacity;
                },
                else => return err,
            };
            return candidate_capacity;
        }

        fn bytesForCapacity(capacity_count: usize) error{Overflow}!usize {
            return std.math.mul(usize, capacity_count, @sizeOf(T));
        }

        fn bytesForCapacityExact(capacity_count: usize) usize {
            assert(capacity_count <= std.math.maxInt(usize) / @sizeOf(T));
            return capacity_count * @sizeOf(T);
        }

        fn assertInvariants(self: *const Self) void {
            assert(self.storage.items.len <= self.storage.capacity);
            if (self.budget != null) {
                assert(self.budget_reserved_capacity == self.storage.capacity);
            } else {
                assert(self.budget_reserved_capacity == 0);
            }
        }
    };
}

test "vec append and budget behavior" {
    // Goal: confirm appends succeed while budget permits growth.
    // Method: append two values and validate resulting length.
    var budget = try memory.budget.Budget.init(16);
    var v = try Vec(u8).init(testing.allocator, .{ .budget = &budget });
    defer v.deinit();

    try v.append(1);
    try v.append(2);
    try testing.expectEqual(@as(usize, 2), v.len());
}

test "vec pop returns last element or null when empty" {
    // Goal: validate LIFO pop semantics and empty-vector behavior.
    // Method: pop from empty, then append/pop two values back to empty.
    var v = try Vec(u32).init(testing.allocator, .{ .budget = null });
    defer v.deinit();

    try testing.expect(v.pop() == null);
    try v.append(10);
    try v.append(20);
    try testing.expectEqual(@as(u32, 20), v.pop().?);
    try testing.expectEqual(@as(u32, 10), v.pop().?);
    try testing.expect(v.pop() == null);
    try testing.expectEqual(@as(usize, 0), v.len());
}

test "vec ensureCapacity with initial_capacity" {
    // Goal: honor initial_capacity at construction time.
    // Method: create with initial capacity and assert len starts at zero.
    var v = try Vec(u8).init(testing.allocator, .{ .initial_capacity = 8, .budget = null });
    defer v.deinit();
    try testing.expect(v.capacity() >= 8);
    try testing.expectEqual(@as(usize, 0), v.len());
}

test "vec budget exhaustion returns NoSpaceLeft" {
    // Goal: map budget exhaustion to NoSpaceLeft.
    // Method: constrain budget to one byte and append twice.
    var budget = try memory.budget.Budget.init(1);
    var v = try Vec(u8).init(testing.allocator, .{ .budget = &budget });
    defer v.deinit();
    try v.append(1);
    // Second append requires more than 1 byte budget and should fail cleanly.
    try testing.expectError(error.NoSpaceLeft, v.append(2));
}

test "vec budget tracks logical reserved capacity" {
    // Goal: track budget by reserved backing capacity.
    // Method: append and assert budget usage equals `capacity * @sizeOf(T)`.
    var budget = try memory.budget.Budget.init(16);
    {
        var v = try Vec(u8).init(testing.allocator, .{ .budget = &budget });
        defer v.deinit();

        try v.append(1);
        try testing.expectEqual(v.capacity(), budget.used());
        try v.append(2);
        try testing.expectEqual(v.capacity(), budget.used());
        try v.append(3);
        try testing.expectEqual(v.capacity(), budget.used());
        try testing.expect(v.capacity() >= 3);
    }
    try testing.expectEqual(@as(usize, 0), budget.used());
}

test "vec ensureCapacity is monotonic" {
    // Goal: ensure explicit capacity requests never shrink backing storage.
    // Method: grow then request smaller capacity and verify non-decreasing cap.
    var v = try Vec(u8).init(testing.allocator, .{ .budget = null });
    defer v.deinit();

    try v.ensureCapacity(8);
    const grown = v.capacity();
    try v.ensureCapacity(4);
    try testing.expect(v.capacity() >= grown);
}

test "vec clear resets length but preserves capacity and budget" {
    // Goal: confirm clear resets logical length without releasing capacity or budget.
    // Method: append values, clear, then assert length is zero while capacity and budget are unchanged.
    var budget = try memory.budget.Budget.init(64);
    var v = try Vec(u8).init(testing.allocator, .{ .budget = &budget });
    defer v.deinit();

    try v.append(1);
    try v.append(2);
    try v.append(3);
    const cap_before = v.capacity();
    const budget_before = budget.used();
    try testing.expect(cap_before > 0);

    v.clear();
    try testing.expectEqual(@as(usize, 0), v.len());
    try testing.expectEqual(cap_before, v.capacity());
    try testing.expectEqual(budget_before, budget.used());

    // Confirm the vec is reusable after clear.
    try v.append(4);
    try testing.expectEqual(@as(usize, 1), v.len());
    try testing.expectEqual(@as(u8, 4), v.items()[0]);
}

test "vec ensureCapacity detects element-size overflow" {
    // Goal: return Overflow rather than panicking or allocating on multiplication overflow.
    // Method: ask for a capacity which overflows `count * @sizeOf(T)` for `u16`.
    var v = try Vec(u16).init(testing.allocator, .{ .budget = null });
    defer v.deinit();

    const max_count = std.math.maxInt(usize) / @sizeOf(u16);
    try testing.expectError(error.Overflow, v.ensureCapacity(max_count + 1));
}

test "vec ensureCapacity rejects requests above the supported public capacity bound" {
    // Goal: keep budgeted and non-budgeted growth on the same stable overflow contract.
    // Method: request more than `u32` elements in both modes and assert Overflow before allocation.
    var plain = try Vec(u8).init(testing.allocator, .{ .budget = null });
    defer plain.deinit();
    try testing.expectError(error.Overflow, plain.ensureCapacity(@as(usize, std.math.maxInt(u32)) + 1));

    var budget = try memory.budget.Budget.init(64);
    var budgeted = try Vec(u8).init(testing.allocator, .{ .budget = &budget });
    defer budgeted.deinit();
    try testing.expectError(error.Overflow, budgeted.ensureCapacity(@as(usize, std.math.maxInt(u32)) + 1));
    try testing.expectEqual(@as(u64, 0), budget.used());
}

test "vec clone produces independent copy" {
    // Goal: verify clone creates a separate copy; mutations are independent.
    // Method: clone, mutate clone, verify original unchanged.
    var v = try Vec(u32).init(testing.allocator, .{ .budget = null });
    defer v.deinit();
    try v.append(10);
    try v.append(20);

    var c = try v.clone();
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.len());
    try testing.expectEqual(@as(u32, 10), c.items()[0]);

    try c.append(30);
    try testing.expectEqual(@as(usize, 3), c.len());
    try testing.expectEqual(@as(usize, 2), v.len());
}

test "vec appendSliceAssumeCapacity supports self-alias append with reserved capacity" {
    var v = try Vec(u32).init(testing.allocator, .{ .budget = null });
    defer v.deinit();

    try v.append(1);
    try v.append(2);
    try v.append(3);
    try v.ensureCapacity(6);

    const src = v.itemsConst();
    v.appendSliceAssumeCapacity(src);

    try testing.expectEqual(@as(usize, 6), v.len());
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 1, 2, 3 }, v.itemsConst());
}

test "vec const item access is read-only" {
    var v = try Vec(u32).init(testing.allocator, .{ .budget = null });
    defer v.deinit();
    try v.append(10);

    const const_v: *const Vec(u32) = &v;
    const items = const_v.itemsConst();
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqual(@as(u32, 10), items[0]);
}
