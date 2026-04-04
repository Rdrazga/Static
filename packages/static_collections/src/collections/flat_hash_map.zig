//! Open-addressing flat hash map and hash set.
//!
//! Key types: `FlatHashMap(K, V, Ctx)`, `FlatHashSet(K, Ctx)`.
//!
//! Uses linear probing with tombstone deletion. Capacity is always a power of two.
//! The optional `Ctx` type may provide `hash(key: K, seed: u64) u64` and/or
//! `eql(a: K, b: K) bool`; both are validated at comptime. Missing declarations
//! fall back to wyhash and `std.meta.eql` respectively.
//!
//! The default hash path uses `std.mem.asBytes(&key)`, which includes struct
//! padding bytes. Composite key types with padding must provide a custom
//! `Ctx.hash` to avoid padding-dependent hash instability. Primitive key types
//! (`u32`, `u64`, etc.) have no padding and work correctly with the default.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const memory = @import("static_memory");
const static_hash = @import("static_hash");
const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    AlreadyExists,
    NotFound,
    InvalidConfig,
    Overflow,
    NoSpaceLeft,
};

const SlotState = enum(u8) {
    empty = 0,
    tombstone = 1,
    occupied = 2,
};

/// Validate that `Ctx` supplies the required `hash` and `eql` declarations
/// with correct arity. Called comptime at the top of `FlatHashMap` to give a
/// clear error message instead of a cryptic missing-field type error.
fn validateCtx(comptime K: type, comptime Ctx: type) void {
    // If Ctx declares `hash`, it must be a two-parameter function (key, seed).
    if (@hasDecl(Ctx, "hash")) {
        const hash_info = @typeInfo(@TypeOf(Ctx.hash));
        if (hash_info != .@"fn") @compileError("Ctx.hash must be a function");
        const params = hash_info.@"fn".params;
        if (params.len != 2) @compileError(
            "Ctx.hash must have signature `fn(key: K, seed: u64) u64` (two parameters)",
        );
    }
    // If Ctx declares `eql`, it must be a two-parameter function (a, b).
    if (@hasDecl(Ctx, "eql")) {
        const eql_info = @typeInfo(@TypeOf(Ctx.eql));
        if (eql_info != .@"fn") @compileError("Ctx.eql must be a function");
        const params = eql_info.@"fn".params;
        if (params.len != 2) @compileError(
            "Ctx.eql must have signature `fn(a: K, b: K) bool` (two parameters)",
        );
        // Both parameters must accept the key type.
        const param0 = params[0].type orelse @compileError("Ctx.eql parameter 0 must have a concrete type");
        if (param0 != K) @compileError("Ctx.eql first parameter must be key type K");
    }
}

pub fn FlatHashMap(comptime K: type, comptime V: type, comptime Ctx: type) type {
    comptime validateCtx(K, Ctx);
    return struct {
        const Self = @This();

        pub const Key = K;
        pub const Value = V;
        pub const Context = Ctx;
        pub const Config = struct {
            initial_capacity: usize = 8,
            seed: u64 = 0,
            max_load_percent: u8 = 70,
            budget: ?*memory.budget.Budget = null,
        };

        const Entry = struct {
            key: K,
            value: V,
            hash: u64,
        };

        allocator: std.mem.Allocator,
        budget: ?*memory.budget.Budget,
        budget_reserved_bytes: usize = 0,
        entries: []Entry,
        states: []SlotState,
        count: usize = 0,
        tombstones: usize = 0,
        seed: u64,
        max_load_percent: u8,

        fn tableBytes(cap: usize) error{Overflow}!usize {
            const entry_bytes = std.math.mul(usize, cap, @sizeOf(Entry)) catch return error.Overflow;
            const state_bytes = std.math.mul(usize, cap, @sizeOf(SlotState)) catch return error.Overflow;
            return std.math.add(usize, entry_bytes, state_bytes) catch return error.Overflow;
        }

        fn reserveBudgetForCapacity(self: *Self, new_cap: usize) Error!void {
            if (self.budget == null) return;
            const budget = self.budget.?;
            const new_bytes = tableBytes(new_cap) catch return error.Overflow;
            if (new_bytes <= self.budget_reserved_bytes) return;
            const delta = new_bytes - self.budget_reserved_bytes;
            budget.tryReserve(delta) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
            self.budget_reserved_bytes = new_bytes;
        }

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            if (cfg.max_load_percent == 0 or cfg.max_load_percent > 95) return error.InvalidConfig;

            const cap = try nextPow2(@max(cfg.initial_capacity, 8));
            assert(cap >= 8);
            assert(std.math.isPowerOfTwo(cap));

            const init_bytes = tableBytes(cap) catch return error.Overflow;
            if (cfg.budget) |budget| {
                budget.tryReserve(init_bytes) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.InvalidConfig => return error.InvalidConfig,
                    error.Overflow => return error.Overflow,
                };
            }

            const entries = allocator.alloc(Entry, cap) catch {
                if (cfg.budget) |budget| budget.release(init_bytes);
                return error.OutOfMemory;
            };
            errdefer {
                allocator.free(entries);
                if (cfg.budget) |budget| budget.release(init_bytes);
            }

            const states = allocator.alloc(SlotState, cap) catch return error.OutOfMemory;
            assert(states.len == entries.len);
            @memset(states, .empty);

            var self: Self = .{
                .allocator = allocator,
                .budget = cfg.budget,
                .budget_reserved_bytes = init_bytes,
                .entries = entries,
                .states = states,
                .seed = cfg.seed,
                .max_load_percent = cfg.max_load_percent,
            };
            self.assertInvariants();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            if (self.budget) |budget| {
                budget.release(self.budget_reserved_bytes);
            }
            self.allocator.free(self.entries);
            self.allocator.free(self.states);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            self.assertInvariants();
            return self.count;
        }

        pub fn capacity(self: *const Self) usize {
            self.assertInvariants();
            return self.entries.len;
        }

        pub fn get(self: *Self, key: K) ?*V {
            self.assertInvariants();
            if (self.entries.len == 0) return null;
            const h = hashKey(key, self.seed);
            const slot = self.findSlot(key, h);
            if (!slot.found) return null;
            assert(slot.index < self.entries.len);
            return &self.entries[slot.index].value;
        }

        pub fn getConst(self: *const Self, key: K) ?*const V {
            self.assertInvariants();
            const h = hashKey(key, self.seed);
            const slot = self.findSlot(key, h);
            if (!slot.found) return null;
            assert(slot.index < self.entries.len);
            return &self.entries[slot.index].value;
        }

        pub fn put(self: *Self, key: K, value: V) Error!void {
            self.assertInvariants();
            const before_count = self.count;
            try self.ensureInsertCapacity();
            const h = hashKey(key, self.seed);
            const slot = self.findSlot(key, h);
            if (slot.found) {
                self.entries[slot.index].value = value;
                assert(self.count == before_count);
                self.assertInvariants();
                return;
            }
            self.insertAt(slot.index, key, value, h);
            assert(self.count == before_count + 1);
            self.assertInvariants();
        }

        pub fn putNoClobber(self: *Self, key: K, value: V) (error{AlreadyExists} || Error)!void {
            self.assertInvariants();
            const before_count = self.count;
            try self.ensureInsertCapacity();
            const h = hashKey(key, self.seed);
            const slot = self.findSlot(key, h);
            if (slot.found) return error.AlreadyExists;
            self.insertAt(slot.index, key, value, h);
            assert(self.count == before_count + 1);
            self.assertInvariants();
        }

        pub fn remove(self: *Self, key: K) (error{NotFound} || Error)!V {
            self.assertInvariants();
            if (self.entries.len == 0) return error.NotFound;
            const before_count = self.count;
            const before_tombstones = self.tombstones;
            const h = hashKey(key, self.seed);
            const slot = self.findSlot(key, h);
            if (!slot.found) return error.NotFound;

            const out = self.entries[slot.index].value;
            self.states[slot.index] = .tombstone;
            self.count -= 1;
            self.tombstones += 1;
            assert(self.count + 1 == before_count);
            assert(self.tombstones == before_tombstones + 1);
            self.assertInvariants();
            return out;
        }

        fn insertAt(self: *Self, idx: usize, key: K, value: V, h: u64) void {
            assert(idx < self.entries.len);
            assert(self.count + self.tombstones <= self.entries.len);
            if (self.states[idx] == .tombstone) {
                // Tombstone decrement guard: count must be positive before decrementing.
                assert(self.tombstones > 0);
                self.tombstones -= 1;
            }
            self.entries[idx] = .{ .key = key, .value = value, .hash = h };
            self.states[idx] = .occupied;
            self.count += 1;
            assert(self.count + self.tombstones <= self.entries.len);
        }

        fn ensureInsertCapacity(self: *Self) Error!void {
            self.assertInvariants();
            const cap = self.entries.len;
            if (cap == 0) return error.InvalidConfig;
            const used = std.math.add(usize, self.count, self.tombstones) catch return error.Overflow;
            const projected = std.math.add(usize, used, 1) catch return error.Overflow;
            const lhs = std.math.mul(usize, projected, 100) catch return error.Overflow;
            const rhs = std.math.mul(usize, cap, @as(usize, self.max_load_percent)) catch return error.Overflow;
            if (lhs <= rhs) return;
            const next = std.math.mul(usize, cap, 2) catch return error.Overflow;
            try self.rehash(next);
            self.assertInvariants();
        }

        fn rehash(self: *Self, new_capacity: usize) Error!void {
            const cap = try nextPow2(new_capacity);
            assert(std.math.isPowerOfTwo(cap));

            // Reserve budget for the new capacity before allocating.
            const new_bytes = tableBytes(cap) catch return error.Overflow;
            const old_budget_bytes = self.budget_reserved_bytes;
            if (self.budget) |budget| {
                if (new_bytes > old_budget_bytes) {
                    const delta = new_bytes - old_budget_bytes;
                    budget.tryReserve(delta) catch |err| switch (err) {
                        error.NoSpaceLeft => return error.NoSpaceLeft,
                        error.InvalidConfig => return error.InvalidConfig,
                        error.Overflow => return error.Overflow,
                    };
                    self.budget_reserved_bytes = new_bytes;
                }
            }

            const new_entries = self.allocator.alloc(Entry, cap) catch {
                // Roll back budget on alloc failure.
                if (self.budget) |budget| {
                    if (new_bytes > old_budget_bytes) {
                        budget.release(new_bytes - old_budget_bytes);
                        self.budget_reserved_bytes = old_budget_bytes;
                    }
                }
                return error.OutOfMemory;
            };
            errdefer self.allocator.free(new_entries);
            const new_states = self.allocator.alloc(SlotState, cap) catch return error.OutOfMemory;
            assert(new_states.len == new_entries.len);
            @memset(new_states, .empty);

            const old_entries = self.entries;
            const old_states = self.states;
            const old_len = old_entries.len;
            const old_count = self.count;

            self.entries = new_entries;
            self.states = new_states;
            self.count = 0;
            self.tombstones = 0;

            var i: usize = 0;
            while (i < old_len) : (i += 1) {
                if (old_states[i] != .occupied) continue;
                const entry = old_entries[i];
                const slot = self.findSlot(entry.key, entry.hash);
                self.insertAt(slot.index, entry.key, entry.value, entry.hash);
            }
            assert(self.count == old_count);
            assert(self.tombstones == 0);
            self.assertInvariants();

            self.allocator.free(old_entries);
            self.allocator.free(old_states);
        }

        const SlotSearch = struct {
            index: usize,
            found: bool,
        };

        fn findSlot(self: *const Self, key: K, h: u64) SlotSearch {
            assert(self.entries.len == self.states.len);
            assert(self.entries.len > 0);
            assert(std.math.isPowerOfTwo(self.entries.len));
            const mask = self.entries.len - 1;
            // @truncate: on 32-bit targets usize < u64; we want the lower
            // bits of the hash (the mask discards the rest anyway).
            var idx: usize = (@as(usize, @truncate(h)) & mask);
            var first_tombstone: ?usize = null;
            var probes: usize = 0;
            while (probes < self.entries.len) : (probes += 1) {
                switch (self.states[idx]) {
                    .empty => {
                        return .{
                            .index = first_tombstone orelse idx,
                            .found = false,
                        };
                    },
                    .tombstone => {
                        if (first_tombstone == null) first_tombstone = idx;
                    },
                    .occupied => {
                        const entry = self.entries[idx];
                        if (entry.hash == h and eqlKey(entry.key, key)) {
                            return .{ .index = idx, .found = true };
                        }
                    },
                }
                idx = (idx + 1) & mask;
            }
            // A full probe with no empty slot and no matching key means every slot is
            // either occupied (by a different key) or a tombstone. If first_tombstone is
            // set, reuse it. If not, the table is entirely occupied with distinct keys —
            // a state that cannot occur when insertions go through ensureInsertCapacity,
            // because the load-factor guard (count + tombstones + 1 <= capacity * load%)
            // prevents the table from ever being simultaneously full and tombstone-free.
            // Returning index 0 silently would corrupt the entry at slot 0; assert instead.
            assert(first_tombstone != null);
            return .{ .index = first_tombstone.?, .found = false };
        }

        fn hashKey(key: K, seed: u64) u64 {
            // Ctx.hash presence and arity are validated at comptime in validateCtx.
            if (comptime @hasDecl(Ctx, "hash")) {
                return Ctx.hash(key, seed);
            }
            return defaultHash(key, seed);
        }

        fn eqlKey(a: K, b: K) bool {
            // Ctx.eql presence and arity are validated at comptime in validateCtx.
            if (comptime @hasDecl(Ctx, "eql")) {
                return Ctx.eql(a, b);
            }
            return std.meta.eql(a, b);
        }

        fn defaultHash(key: K, seed: u64) u64 {
            var ctx = static_hash.wyhash.Wyhash64.init(seed);
            ctx.update(std.mem.asBytes(&key));
            return ctx.final();
        }

        fn nextPow2(n: usize) Error!usize {
            // Precondition: all callers guarantee n > 0 (init enforces >= 8,
            // rehash passes cap * 2). Assert the contract rather than degrading
            // silently with a fallback that would hide a broken caller.
            assert(n > 0);
            if (n == 1) return 1;
            const result = std.math.ceilPowerOfTwo(usize, n) catch return error.Overflow;
            assert(std.math.isPowerOfTwo(result));
            assert(result >= n);
            return result;
        }

        fn assertInvariants(self: *const Self) void {
            assert(self.entries.len == self.states.len);
            assert(self.entries.len > 0);
            assert(std.math.isPowerOfTwo(self.entries.len));
            assert(self.max_load_percent > 0);
            assert(self.max_load_percent <= 95);
            assert(self.count + self.tombstones <= self.entries.len);
        }
    };
}

pub fn FlatHashSet(comptime K: type, comptime Ctx: type) type {
    const Map = FlatHashMap(K, void, Ctx);
    return struct {
        const Self = @This();

        map: Map,

        pub fn init(allocator: std.mem.Allocator, cfg: Map.Config) Error!Self {
            return .{ .map = try Map.init(allocator, cfg) };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            return self.map.len();
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.map.getConst(key) != null;
        }

        pub fn insert(self: *Self, key: K) Error!void {
            try self.map.put(key, {});
        }

        pub fn remove(self: *Self, key: K) (error{NotFound} || Error)!void {
            _ = try self.map.remove(key);
        }
    };
}

test "flat hash map basic put/get/remove" {
    // Goal: verify basic CRUD behavior and missing-key semantics.
    // Method: insert, retrieve, remove, and assert NotFound on repeated removal.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(std.testing.allocator, .{});
    defer map.deinit();

    try map.put(1, 10);
    try map.putNoClobber(2, 20);
    try std.testing.expectEqual(@as(u32, 10), map.get(1).?.*);
    try std.testing.expectEqual(@as(u32, 20), map.get(2).?.*);
    try std.testing.expectEqual(@as(u32, 10), try map.remove(1));
    try std.testing.expectError(error.NotFound, map.remove(1));
}

test "flat hash map rejects invalid load factor configuration" {
    // Goal: reject configuration outside the supported load factor interval.
    // Method: initialize with max_load_percent at invalid low and high bounds.
    const Ctx = struct {};
    try std.testing.expectError(
        error.InvalidConfig,
        FlatHashMap(u32, u32, Ctx).init(std.testing.allocator, .{ .max_load_percent = 0 }),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        FlatHashMap(u32, u32, Ctx).init(std.testing.allocator, .{ .max_load_percent = 96 }),
    );
}

test "flat hash map put updates existing key without changing len" {
    // Goal: ensure put overwrites value for an existing key.
    // Method: write same key twice and assert cardinality remains one.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(std.testing.allocator, .{});
    defer map.deinit();

    try map.put(7, 10);
    try map.put(7, 20);
    std.debug.assert(map.len() == 1);
    try std.testing.expectEqual(@as(usize, 1), map.len());
    try std.testing.expectEqual(@as(u32, 20), map.get(7).?.*);
}

test "flat hash map reuses tombstone slots after remove" {
    // Goal: verify removed slots are reusable for future insertions.
    // Method: remove one key, insert another, then validate reachable values.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(std.testing.allocator, .{ .initial_capacity = 8 });
    defer map.deinit();

    try map.put(1, 10);
    try map.put(2, 20);
    _ = try map.remove(1);
    try map.put(3, 30);

    try std.testing.expect(map.get(1) == null);
    try std.testing.expectEqual(@as(u32, 20), map.get(2).?.*);
    try std.testing.expectEqual(@as(u32, 30), map.get(3).?.*);
}

test "flat hash map rehash preserves all entries" {
    // Goal: verify growth preserves key/value associations.
    // Method: insert enough keys to force resize and then read them all back.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(std.testing.allocator, .{ .initial_capacity = 8 });
    defer map.deinit();

    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        try map.put(i, i * 10);
    }
    try std.testing.expect(map.capacity() >= 64);

    i = 0;
    while (i < 64) : (i += 1) {
        try std.testing.expectEqual(i * 10, map.get(i).?.*);
    }
}

test "flat hash set insert contains remove" {
    // Goal: ensure set wrapper forwards map semantics correctly.
    // Method: insert one key, check containment, remove, then assert absence.
    const Ctx = struct {};
    var set = try FlatHashSet(u32, Ctx).init(std.testing.allocator, .{});
    defer set.deinit();

    try set.insert(9);
    try std.testing.expect(set.contains(9));
    try set.remove(9);
    try std.testing.expect(!set.contains(9));
    try std.testing.expectError(error.NotFound, set.remove(9));
}
