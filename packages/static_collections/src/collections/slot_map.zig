//! Slot map: stable handles with O(1) insert, lookup, and remove.
//!
//! Key type: `SlotMap(T)`. Provides stable `Handle` identifiers that survive
//! reallocation. Generation counters in handles detect use-after-free of a slot.
//! Free slots are tracked in an embedded free list within the slot array.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const handle_mod = @import("handle.zig");
const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    NotFound,
    Overflow,
};

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Handle = handle_mod.Handle;
        pub const Config = struct {
            initial_capacity: u32 = 0,
        };

        const invalid_index = std.math.maxInt(u32);
        const Slot = struct {
            generation: u32 = 1,
            occupied: bool = false,
            next_free: u32 = invalid_index,
            value: T = undefined,
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayListUnmanaged(Slot) = .{},
        free_head: ?u32 = null,
        live: usize = 0,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            var self: Self = .{ .allocator = allocator };
            if (cfg.initial_capacity > 0) {
                try self.slots.ensureTotalCapacityPrecise(allocator, cfg.initial_capacity);
            }
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            self.assertInvariants();
            return self.live;
        }

        pub fn insert(self: *Self, value: T) Error!Handle {
            self.assertInvariants();
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
                self.assertInvariants();
                return handle;
            }

            const index = self.slots.items.len;
            if (index >= std.math.maxInt(u32)) return error.Overflow;
            self.slots.append(self.allocator, .{
                .generation = 1,
                .occupied = true,
                .next_free = invalid_index,
                .value = value,
            }) catch return error.OutOfMemory;
            self.live += 1;
            assert(self.live == before_live + 1);
            assert(index < std.math.maxInt(u32));
            const handle: Handle = .{
                .index = @intCast(index),
                .generation = 1,
            };
            assert(handle.isValid());
            self.assertInvariants();
            return handle;
        }

        pub fn get(self: *Self, h: Handle) ?*T {
            self.assertInvariants();
            if (!h.isValid()) return null;
            const idx: usize = h.index;
            if (idx >= self.slots.items.len) return null;
            const slot = &self.slots.items[idx];
            if (!slot.occupied) return null;
            if (slot.generation != h.generation) return null;
            return &slot.value;
        }

        pub fn getConst(self: *const Self, h: Handle) ?*const T {
            self.assertInvariants();
            if (!h.isValid()) return null;
            const idx: usize = h.index;
            if (idx >= self.slots.items.len) return null;
            const slot = &self.slots.items[idx];
            if (!slot.occupied) return null;
            if (slot.generation != h.generation) return null;
            return &slot.value;
        }

        pub fn remove(self: *Self, h: Handle) Error!T {
            self.assertInvariants();
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
            self.assertInvariants();
            return out;
        }

        fn assertInvariants(self: *const Self) void {
            const slot_count = self.slots.items.len;
            assert(self.live <= slot_count);
            if (self.free_head) |head| assert(head < slot_count);

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
    var sm = try SlotMap(u32).init(std.testing.allocator, .{});
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
    var sm = try SlotMap(u32).init(std.testing.allocator, .{});
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
    var sm = try SlotMap(u32).init(std.testing.allocator, .{});
    defer sm.deinit();

    const h = try sm.insert(99);
    _ = try sm.remove(h);
    try std.testing.expectError(error.NotFound, sm.remove(h));
}

test "slot map multiple inserts and removes" {
    // Goal: validate live-count tracking through mixed insert/remove operations.
    // Method: insert three values, remove middle, and assert survivors are intact.
    var sm = try SlotMap(u32).init(std.testing.allocator, .{});
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
    var sm = try SlotMap(u32).init(std.testing.allocator, .{});
    defer sm.deinit();

    const invalid = handle_mod.Handle.invalid();
    try std.testing.expect(sm.get(invalid) == null);
    try std.testing.expectError(error.NotFound, sm.remove(invalid));
}
