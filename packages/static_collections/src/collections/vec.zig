//! Dynamic array (Vec) with optional memory budget integration.
//!
//! Key type: `Vec(T)`. A heap-allocated growable array. Integrates with `static_memory`
//! Budget to enforce per-subsystem memory caps. Capacity growth is controlled by the
//! configured growth strategy.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
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
            budget: ?*memory.budget.Budget = null,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        budget_reserved_capacity: u32 = 0,
        storage: std.ArrayListUnmanaged(T) = .{},

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            var self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
            };
            if (cfg.initial_capacity > 0) {
                try self.ensureCapacity(cfg.initial_capacity);
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

        pub fn len(self: Self) usize {
            self.assertInvariants();
            return self.storage.items.len;
        }

        pub fn capacity(self: Self) usize {
            self.assertInvariants();
            return self.storage.capacity;
        }

        pub fn items(self: Self) []T {
            self.assertInvariants();
            return self.storage.items;
        }

        pub fn append(self: *Self, value: T) Error!void {
            self.assertInvariants();
            const before_len = self.storage.items.len;
            const needed_capacity = std.math.add(usize, before_len, 1) catch return error.Overflow;
            try self.ensureCapacity(needed_capacity);
            assert(self.storage.capacity > before_len);
            self.storage.appendAssumeCapacity(value);
            assert(self.storage.items.len == before_len + 1);
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
                // chosen_capacity is bounded by the usize → u32 narrowing assertion below because
                // bytesForCapacity already guards overflow at the top of ensureCapacity, so any
                // capacity that passes that check fits in a usize; the u32 bound is tighter and
                // is enforced here explicitly before the cast.
                assert(chosen_capacity <= std.math.maxInt(u32));
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

        fn assertInvariants(self: Self) void {
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
    var v = try Vec(u8).init(std.testing.allocator, .{ .budget = &budget });
    defer v.deinit();

    try v.append(1);
    try v.append(2);
    try std.testing.expectEqual(@as(usize, 2), v.len());
}

test "vec pop returns last element or null when empty" {
    // Goal: validate LIFO pop semantics and empty-vector behavior.
    // Method: pop from empty, then append/pop two values back to empty.
    var v = try Vec(u32).init(std.testing.allocator, .{});
    defer v.deinit();

    try std.testing.expect(v.pop() == null);
    try v.append(10);
    try v.append(20);
    try std.testing.expectEqual(@as(u32, 20), v.pop().?);
    try std.testing.expectEqual(@as(u32, 10), v.pop().?);
    try std.testing.expect(v.pop() == null);
    try std.testing.expectEqual(@as(usize, 0), v.len());
}

test "vec ensureCapacity with initial_capacity" {
    // Goal: honor initial_capacity at construction time.
    // Method: create with initial capacity and assert len starts at zero.
    var v = try Vec(u8).init(std.testing.allocator, .{ .initial_capacity = 8 });
    defer v.deinit();
    try std.testing.expect(v.capacity() >= 8);
    try std.testing.expectEqual(@as(usize, 0), v.len());
}

test "vec budget exhaustion returns NoSpaceLeft" {
    // Goal: map budget exhaustion to NoSpaceLeft.
    // Method: constrain budget to one byte and append twice.
    var budget = try memory.budget.Budget.init(1);
    var v = try Vec(u8).init(std.testing.allocator, .{ .budget = &budget });
    defer v.deinit();
    try v.append(1);
    // Second append requires more than 1 byte budget — should be NoSpaceLeft.
    try std.testing.expectError(error.NoSpaceLeft, v.append(2));
}

test "vec budget tracks logical reserved capacity" {
    // Goal: track budget by reserved backing capacity.
    // Method: append and assert budget usage equals `capacity * @sizeOf(T)`.
    var budget = try memory.budget.Budget.init(16);
    {
        var v = try Vec(u8).init(std.testing.allocator, .{ .budget = &budget });
        defer v.deinit();

        try v.append(1);
        try std.testing.expectEqual(v.capacity(), budget.used());
        try v.append(2);
        try std.testing.expectEqual(v.capacity(), budget.used());
        try v.append(3);
        try std.testing.expectEqual(v.capacity(), budget.used());
        try std.testing.expect(v.capacity() >= 3);
    }
    try std.testing.expectEqual(@as(usize, 0), budget.used());
}

test "vec ensureCapacity is monotonic" {
    // Goal: ensure explicit capacity requests never shrink backing storage.
    // Method: grow then request smaller capacity and verify non-decreasing cap.
    var v = try Vec(u8).init(std.testing.allocator, .{});
    defer v.deinit();

    try v.ensureCapacity(8);
    const grown = v.capacity();
    try v.ensureCapacity(4);
    try std.testing.expect(v.capacity() >= grown);
}

test "vec ensureCapacity detects element-size overflow" {
    // Goal: return Overflow rather than panicking or allocating on multiplication overflow.
    // Method: ask for a capacity which overflows `count * @sizeOf(T)` for `u16`.
    var v = try Vec(u16).init(std.testing.allocator, .{});
    defer v.deinit();

    const max_count = std.math.maxInt(usize) / @sizeOf(u16);
    try std.testing.expectError(error.Overflow, v.ensureCapacity(max_count + 1));
}
