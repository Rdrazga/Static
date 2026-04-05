//! Slot map: stable handles with O(1) insert, lookup, and remove.
//!
//! Key type: `SlotMap(T)`. Provides stable `Handle` identifiers that survive
//! reallocation. Generation counters in handles detect use-after-free of a slot.
//! Free slots are tracked in an embedded free list within the slot array.
//!
//! Generation counters use wrapping arithmetic (`+%`). After 2^32 - 1 remove
//! and reinsert cycles on the same slot, the generation wraps and a very old
//! stale handle could falsely validate. This is a known limitation of 32-bit
//! generational handles and is sufficient for virtually all practical workloads.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const memory = @import("static_memory");
const handle_mod = @import("handle.zig");
const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    NotFound,
    Overflow,
    NoSpaceLeft,
    InvalidConfig,
};

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Handle = handle_mod.Handle;
        pub const Config = struct {
            initial_capacity: u32 = 0,
            budget: ?*memory.budget.Budget,
        };

        const invalid_index = std.math.maxInt(u32);
        const Slot = struct {
            generation: u32 = 1,
            occupied: bool = false,
            next_free: u32 = invalid_index,
            value: T = undefined,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        budget_reserved_capacity: usize = 0,
        slots: std.ArrayListUnmanaged(Slot) = .{},
        free_head: ?u32 = null,
        live: usize = 0,

        fn slotBytesForCapacity(cap: usize) error{Overflow}!usize {
            return std.math.mul(usize, cap, @sizeOf(Slot));
        }

        fn ensureBudgetCapacity(self: *Self, needed: usize) Error!void {
            if (self.budget == null) return;
            if (needed <= self.budget_reserved_capacity) return;
            const budget = self.budget.?;
            const new_bytes = slotBytesForCapacity(needed) catch return error.Overflow;
            const old_bytes = slotBytesForCapacity(self.budget_reserved_capacity) catch return error.Overflow;
            assert(new_bytes >= old_bytes);
            const delta = new_bytes - old_bytes;
            budget.tryReserve(delta) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
            self.budget_reserved_capacity = needed;
        }

        /// Grows the slot backing array to at least `required` capacity using
        /// geometric growth. Budget tracks the actual allocated capacity (not
        /// logical length) so that budget accounting matches real memory usage.
        fn ensureSlotGrowth(self: *Self, required: usize) Error!void {
            assert(required > 0);
            if (required <= self.slots.capacity) return;

            const old_capacity = self.slots.capacity;
            const candidate = if (old_capacity == 0)
                required
            else blk: {
                const doubled = std.math.mul(usize, old_capacity, 2) catch return error.Overflow;
                break :blk @max(required, doubled);
            };

            const old_budget = self.budget_reserved_capacity;
            try self.ensureBudgetCapacity(candidate);

            self.slots.ensureTotalCapacityPrecise(self.allocator, candidate) catch {
                if (self.budget) |budget| {
                    if (self.budget_reserved_capacity > old_budget) {
                        // Safety: both capacities were validated on the forward path.
                        const rollback = (slotBytesForCapacity(self.budget_reserved_capacity) catch unreachable) -
                            (slotBytesForCapacity(old_budget) catch unreachable);
                        budget.release(rollback);
                        self.budget_reserved_capacity = old_budget;
                    }
                }
                return error.OutOfMemory;
            };
            assert(self.slots.capacity >= candidate);
        }

        pub fn init(allocator: std.mem.Allocator, config: Config) Error!Self {
            var self: Self = .{
                .allocator = allocator,
                .budget = config.budget,
            };
            if (config.initial_capacity > 0) {
                try self.ensureBudgetCapacity(config.initial_capacity);
                self.slots.ensureTotalCapacityPrecise(allocator, config.initial_capacity) catch {
                    if (self.budget) |budget| {
                        // Safety: initial_capacity is u32; product fits usize.
                        const bytes = slotBytesForCapacity(config.initial_capacity) catch unreachable;
                        budget.release(bytes);
                        self.budget_reserved_capacity = 0;
                    }
                    return error.OutOfMemory;
                };
            }
            self.assertFullInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertFullInvariants();
            if (self.budget) |budget| {
                // Safety: budget_reserved_capacity was validated at reservation time.
                const bytes = slotBytesForCapacity(self.budget_reserved_capacity) catch unreachable;
                budget.release(bytes);
            }
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        /// Creates an independent copy with its own backing memory.
        /// The free list is embedded in the slot array. Only occupied slots'
        /// payloads are copied; free slots keep undefined payload state.
        pub fn clone(self: *const Self) Error!Self {
            self.assertStructuralInvariants();
            const cap = self.slots.capacity;
            const slot_len = self.slots.items.len;

            if (cap == 0) {
                return Self{
                    .allocator = self.allocator,
                    .budget = self.budget,
                    .free_head = self.free_head,
                    .live = self.live,
                };
            }

            const bytes = slotBytesForCapacity(cap) catch return error.Overflow;
            if (self.budget) |budget| {
                budget.tryReserve(bytes) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.InvalidConfig => return error.InvalidConfig,
                    error.Overflow => return error.Overflow,
                };
            }

            const new_buf = self.allocator.alloc(Slot, cap) catch {
                if (self.budget) |budget| budget.release(bytes);
                return error.OutOfMemory;
            };
            var index: usize = 0;
            while (index < slot_len) : (index += 1) {
                const src = self.slots.items[index];
                new_buf[index].generation = src.generation;
                new_buf[index].occupied = src.occupied;
                new_buf[index].next_free = src.next_free;
                if (src.occupied) {
                    new_buf[index].value = src.value;
                } else {
                    new_buf[index].value = undefined;
                }
            }

            // Manual ArrayListUnmanaged construction: std.ArrayListUnmanaged
            // does not expose a clone or init-from-buffer API, so we must set
            // .items and .capacity directly. This couples to the stdlib type's
            // internal layout — revisit if the layout changes.
            var result: Self = .{
                .allocator = self.allocator,
                .budget = self.budget,
                .budget_reserved_capacity = self.budget_reserved_capacity,
                .slots = .{
                    .items = new_buf[0..slot_len],
                    .capacity = cap,
                },
                .free_head = self.free_head,
                .live = self.live,
            };
            result.assertFullInvariants();
            return result;
        }

        pub fn len(self: *const Self) usize {
            self.assertStructuralInvariants();
            return self.live;
        }

        pub fn insert(self: *Self, value: T) Error!Handle {
            self.assertStructuralInvariants();
            const before_live = self.live;
            if (self.free_head) |head| {
                const idx: usize = head;
                assert(idx < self.slots.items.len);
                var slot = &self.slots.items[idx];
                assert(!slot.occupied);
                self.free_head = if (slot.next_free == invalid_index) null else slot.next_free;
                slot.value = value;
                slot.occupied = true;
                slot.next_free = invalid_index;
                self.live += 1;
                assert(self.live == before_live + 1);
                const handle: Handle = .{
                    .index = @intCast(idx),
                    .generation = slot.generation,
                };
                assert(handle.isValid());
                self.assertFullInvariants();
                return handle;
            }

            const index = self.slots.items.len;
            if (index >= std.math.maxInt(u32)) return error.Overflow;
            const needed_capacity = std.math.add(usize, index, 1) catch return error.Overflow;
            try self.ensureSlotGrowth(needed_capacity);
            self.slots.appendAssumeCapacity(.{
                .generation = 1,
                .occupied = true,
                .next_free = invalid_index,
                .value = value,
            });
            self.live += 1;
            assert(self.live == before_live + 1);
            assert(index < std.math.maxInt(u32));
            const handle: Handle = .{
                .index = @intCast(index),
                .generation = 1,
            };
            assert(handle.isValid());
            self.assertFullInvariants();
            return handle;
        }

        pub fn get(self: *Self, h: Handle) ?*T {
            self.assertStructuralInvariants();
            if (!h.isValid()) return null;
            const idx: usize = h.index;
            if (idx >= self.slots.items.len) return null;
            const slot = &self.slots.items[idx];
            if (!slot.occupied) return null;
            if (slot.generation != h.generation) return null;
            return &slot.value;
        }

        pub fn getConst(self: *const Self, h: Handle) ?*const T {
            self.assertStructuralInvariants();
            if (!h.isValid()) return null;
            const idx: usize = h.index;
            if (idx >= self.slots.items.len) return null;
            const slot = &self.slots.items[idx];
            if (!slot.occupied) return null;
            if (slot.generation != h.generation) return null;
            return &slot.value;
        }

        /// Resets the slot map to empty without releasing backing memory or
        /// budget reservation. All existing handles become stale (generations
        /// are bumped). The free list is rebuilt in forward order so that
        /// free_head points to the highest index — subsequent inserts reuse
        /// slots in descending index order (LIFO).
        pub fn clear(self: *Self) void {
            self.assertStructuralInvariants();
            var free_prev: ?u32 = null;
            for (self.slots.items, 0..) |*slot, i| {
                if (slot.occupied) {
                    slot.generation +%= 1;
                    if (slot.generation == 0) slot.generation = 1;
                }
                slot.occupied = false;
                slot.next_free = free_prev orelse invalid_index;
                slot.value = undefined;
                assert(i <= std.math.maxInt(u32));
                free_prev = @intCast(i);
            }
            self.free_head = free_prev;
            self.live = 0;
            assert(self.live == 0);
            self.assertFullInvariants();
        }

        pub fn remove(self: *Self, h: Handle) Error!T {
            self.assertStructuralInvariants();
            if (!h.isValid()) return error.NotFound;
            const idx: usize = h.index;
            if (idx >= self.slots.items.len) return error.NotFound;

            var slot = &self.slots.items[idx];
            if (!slot.occupied or slot.generation != h.generation) return error.NotFound;

            const out = slot.value;
            const before_live = self.live;
            assert(before_live > 0);
            slot.occupied = false;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.next_free = if (self.free_head) |free| free else invalid_index;
            self.free_head = @intCast(idx);
            self.live -= 1;
            assert(self.live == before_live - 1);
            self.assertFullInvariants();
            return out;
        }

        pub const IterEntry = struct {
            handle: Handle,
            value_ptr: *T,
        };

        pub const Iterator = struct {
            slots: []Slot,
            index: usize = 0,

            pub fn next(self: *Iterator) ?IterEntry {
                while (self.index < self.slots.len) {
                    const i = self.index;
                    self.index += 1;
                    if (self.slots[i].occupied) {
                        assert(i <= std.math.maxInt(u32));
                        return .{
                            .handle = .{ .index = @intCast(i), .generation = self.slots[i].generation },
                            .value_ptr = &self.slots[i].value,
                        };
                    }
                }
                return null;
            }
        };

        /// Returns an iterator over all live entries as (Handle, *T) pairs.
        ///
        /// The iterator borrows the current slot slice. Any structural mutation
        /// (`insert`, `remove`, `clear`, or any operation that may grow slots)
        /// invalidates the iterator and all `value_ptr` pointers it has yielded.
        /// Restart iteration after any structural change.
        pub fn iterator(self: *Self) Iterator {
            self.assertStructuralInvariants();
            return .{ .slots = self.slots.items };
        }

        /// O(1) structural checks: live count bounded, free_head in range.
        fn assertStructuralInvariants(self: *const Self) void {
            const slot_count = self.slots.items.len;
            assert(self.live <= slot_count);
            if (self.free_head) |head| assert(head < slot_count);
        }

        /// O(n) full validation: walks all slots and the free list to prove
        /// live count, occupied/free consistency, and free-list integrity.
        /// Called only after mutations (insert, remove) and at init/deinit.
        fn assertFullInvariants(self: *const Self) void {
            self.assertStructuralInvariants();
            const slot_count = self.slots.items.len;

            var live_count: usize = 0;
            var unoccupied_count: usize = 0;
            for (self.slots.items) |slot| {
                if (slot.occupied) {
                    live_count += 1;
                    assert(slot.generation != 0);
                    assert(slot.next_free == invalid_index);
                } else {
                    unoccupied_count += 1;
                    assert(slot.next_free == invalid_index or slot.next_free < slot_count);
                }
            }
            assert(live_count == self.live);

            var free_count: usize = 0;
            var cursor = self.free_head;
            while (cursor) |idx| {
                assert(idx < slot_count);
                assert(free_count < slot_count);

                const slot = self.slots.items[idx];
                assert(!slot.occupied);
                if (slot.next_free != invalid_index) {
                    assert(slot.next_free < slot_count);
                }

                free_count += 1;
                cursor = if (slot.next_free == invalid_index) null else slot.next_free;
            }

            assert(free_count == unoccupied_count);
        }
    };
}

test "slot map generation checks reject stale handles" {
    // Goal: stale handles must fail after remove due to generation mismatch.
    // Method: insert-get-remove and assert old handle lookup returns null.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    const h = try sm.insert(7);
    std.debug.assert(sm.len() == 1);
    try std.testing.expectEqual(@as(u32, 7), sm.get(h).?.*);
    _ = try sm.remove(h);
    try std.testing.expect(sm.get(h) == null);
    try std.testing.expectEqual(@as(usize, 0), sm.len());
}

test "slot map slot is reused and old handle is stale after reuse" {
    // Goal: confirm free-list slot reuse bumps generation for safety.
    // Method: remove a handle, insert again, and compare index/generation.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    const h1 = try sm.insert(10);
    _ = try sm.remove(h1);

    const h2 = try sm.insert(20);
    assert(h1.index == h2.index);
    assert(h2.generation != h1.generation);
    try std.testing.expect(sm.get(h1) == null);
    try std.testing.expectEqual(@as(u32, 20), sm.get(h2).?.*);
}

test "slot map remove on stale handle returns NotFound" {
    // Goal: remove must reject stale generation values.
    // Method: remove once, then remove same handle again and expect NotFound.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    const h = try sm.insert(99);
    _ = try sm.remove(h);
    try std.testing.expectError(error.NotFound, sm.remove(h));
}

test "slot map multiple inserts and removes" {
    // Goal: validate live-count tracking through mixed insert/remove operations.
    // Method: insert three values, remove middle, and assert survivors are intact.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    const a = try sm.insert(1);
    const b = try sm.insert(2);
    const c = try sm.insert(3);
    try std.testing.expectEqual(@as(usize, 3), sm.len());

    _ = try sm.remove(b);
    try std.testing.expectEqual(@as(usize, 2), sm.len());
    try std.testing.expectEqual(@as(u32, 1), sm.get(a).?.*);
    try std.testing.expectEqual(@as(u32, 3), sm.get(c).?.*);
    try std.testing.expect(sm.get(b) == null);
}

test "slot map invalid sentinel handle is rejected" {
    // Goal: reject invalid handle sentinel across read and remove paths.
    // Method: query and remove Handle.invalid() and assert safe failure.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    const invalid = handle_mod.Handle.invalid();
    try std.testing.expect(sm.get(invalid) == null);
    try std.testing.expectError(error.NotFound, sm.remove(invalid));
}

test "slot map clear invalidates all handles and allows reuse" {
    // Goal: confirm clear resets length and stales all handles while preserving capacity.
    // Method: insert values, clear, verify old handles are stale, then insert again.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    const a = try sm.insert(1);
    const b = try sm.insert(2);
    try std.testing.expectEqual(@as(usize, 2), sm.len());

    sm.clear();
    try std.testing.expectEqual(@as(usize, 0), sm.len());
    try std.testing.expect(sm.get(a) == null);
    try std.testing.expect(sm.get(b) == null);

    const c = try sm.insert(3);
    try std.testing.expectEqual(@as(usize, 1), sm.len());
    try std.testing.expectEqual(@as(u32, 3), sm.get(c).?.*);
}

test "slot map iterator yields all live entries" {
    // Goal: verify iterator visits all live entries and skips freed slots.
    // Method: insert three values, remove middle, iterate and sum remaining.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    _ = try sm.insert(10);
    const b = try sm.insert(20);
    _ = try sm.insert(30);
    _ = try sm.remove(b);

    var it = sm.iterator();
    var sum: u32 = 0;
    var count: usize = 0;
    while (it.next()) |entry| {
        sum += entry.value_ptr.*;
        try std.testing.expect(sm.get(entry.handle) != null);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u32, 40), sum);
}

test "slot map budget tracks actual capacity" {
    // Goal: verify budget accounting matches actual slot capacity.
    // Method: create with budget, insert values, verify budget used, deinit, verify released.
    const slot_size = @sizeOf(SlotMap(u32).Slot);
    var budget = try memory.budget.Budget.init(slot_size * 16);

    {
        var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = &budget });
        defer sm.deinit();

        _ = try sm.insert(1);
        _ = try sm.insert(2);
        _ = try sm.insert(3);

        const expected_bytes = sm.slots.capacity * slot_size;
        try std.testing.expectEqual(@as(u64, expected_bytes), budget.used());
    }
    try std.testing.expectEqual(@as(u64, 0), budget.used());
}

test "slot map clone produces independent copy" {
    // Goal: verify clone creates a separate copy with intact free list.
    // Method: clone after insert+remove, verify both work independently.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    const a = try sm.insert(10);
    _ = try sm.insert(20);
    _ = try sm.remove(a);

    var c = try sm.clone();
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 1), c.len());

    // Clone's free list should work independently.
    const d = try c.insert(30);
    try std.testing.expectEqual(@as(u32, 30), c.get(d).?.*);
    try std.testing.expectEqual(@as(usize, 2), c.len());
    try std.testing.expectEqual(@as(usize, 1), sm.len());
}

test "slot map clone after clear preserves reusable free-list state" {
    var sm = try SlotMap(u32).init(std.testing.allocator, .{ .budget = null });
    defer sm.deinit();

    _ = try sm.insert(10);
    _ = try sm.insert(20);
    sm.clear();

    var clone = try sm.clone();
    defer clone.deinit();

    try std.testing.expectEqual(@as(usize, 0), clone.len());
    const handle = try clone.insert(30);
    try std.testing.expectEqual(@as(u32, 30), clone.get(handle).?.*);
}
