//! Open-addressing flat hash map and hash set.
//!
//! Key types: `FlatHashMap(K, V, Ctx)`, `FlatHashSet(K, Ctx)`.
//!
//! Uses linear probing with tombstone deletion. Capacity is always a power of two.
//! The optional `Ctx` type may provide `hash(key: K, seed: u64) u64` and/or
//! `eql(a: K, b: K) bool`, or borrowed forms using `*const K`; both are
//! validated at comptime. Missing declarations fall back to wyhash and
//! `std.meta.eql` respectively.
//!
//! The default hash path uses `std.mem.asBytes(&key)`. Key types whose raw byte
//! representation may differ across semantically equal values, such as padded
//! composites or union-shaped payloads, must provide a custom `Ctx.hash` to
//! normalize the relevant fields explicitly. Primitive key types (`u32`, `u64`,
//! etc.) have stable raw-byte representations and work correctly with the
//! default.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const testing = std.testing;
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
    const BorrowedKey = *const K;
    if (!@hasDecl(Ctx, "hash") and hasDefaultHashRepresentationRisk(K)) {
        @compileError(
            "FlatHashMap default hashing cannot safely hash key type `" ++
                @typeName(K) ++
                "` because its raw byte representation is not stable across semantically equal values; provide Ctx.hash",
        );
    }
    // If Ctx declares `hash`, it must use either a value or borrowed key.
    if (@hasDecl(Ctx, "hash")) {
        const hash_info = @typeInfo(@TypeOf(Ctx.hash));
        if (hash_info != .@"fn") @compileError("Ctx.hash must be a function");
        const hfn = hash_info.@"fn";
        if (hfn.params.len != 2) @compileError(
            "Ctx.hash must have signature `fn(key: K, seed: u64) u64` or `fn(key: *const K, seed: u64) u64`",
        );
        const hp0 = hfn.params[0].type orelse @compileError("Ctx.hash parameter 0 must have a concrete type");
        if (hp0 != K and hp0 != BorrowedKey) {
            @compileError("Ctx.hash first parameter must be key type K or *const K");
        }
        const hp1 = hfn.params[1].type orelse @compileError("Ctx.hash parameter 1 must have a concrete type");
        if (hp1 != u64) @compileError("Ctx.hash second parameter must be u64");
        const hret = hfn.return_type orelse @compileError("Ctx.hash must have a concrete return type");
        if (hret != u64) @compileError("Ctx.hash must return u64");
    }
    // If Ctx declares `eql`, it must use either a value or borrowed key pair.
    if (@hasDecl(Ctx, "eql")) {
        const eql_info = @typeInfo(@TypeOf(Ctx.eql));
        if (eql_info != .@"fn") @compileError("Ctx.eql must be a function");
        const efn = eql_info.@"fn";
        if (efn.params.len != 2) @compileError(
            "Ctx.eql must have signature `fn(a: K, b: K) bool` or `fn(a: *const K, b: *const K) bool`",
        );
        const ep0 = efn.params[0].type orelse @compileError("Ctx.eql parameter 0 must have a concrete type");
        const ep1 = efn.params[1].type orelse @compileError("Ctx.eql parameter 1 must have a concrete type");
        const eret = efn.return_type orelse @compileError("Ctx.eql must have a concrete return type");
        if (eret != bool) @compileError("Ctx.eql must return bool");
        const uses_value_keys = ep0 == K and ep1 == K;
        const uses_borrowed_keys = ep0 == BorrowedKey and ep1 == BorrowedKey;
        if (!uses_value_keys and !uses_borrowed_keys) {
            @compileError("Ctx.eql parameters must both be K or both be *const K");
        }
    }
}

/// Comptime-only recursion bounded by the finite type graph. Each recursive
/// call descends one level in the type tree; Zig types form a DAG with no
/// cycles, so termination is guaranteed. TigerStyle 3.1 exception.
fn hasDefaultHashRepresentationRisk(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            if (info.layout == .@"packed") {
                inline for (info.fields) |field| {
                    if (field.is_comptime) continue;
                    if (hasDefaultHashRepresentationRisk(field.type)) break :blk true;
                }
                break :blk false;
            }
            var runtime_fields_size: usize = 0;
            inline for (info.fields) |field| {
                if (field.is_comptime) continue;
                if (hasDefaultHashRepresentationRisk(field.type)) break :blk true;
                runtime_fields_size += @sizeOf(field.type);
            }
            break :blk runtime_fields_size != @sizeOf(T);
        },
        .array => |info| hasDefaultHashRepresentationRisk(info.child),
        .vector => |info| hasDefaultHashRepresentationRisk(info.child),
        .optional => |info| hasDefaultHashRepresentationRisk(info.child),
        .error_union => |info| hasDefaultHashRepresentationRisk(info.payload),
        .@"union" => true,
        else => false,
    };
}

pub fn FlatHashMap(comptime K: type, comptime V: type, comptime Ctx: type) type {
    comptime validateCtx(K, Ctx);
    return struct {
        const Self = @This();

        pub const Key = K;
        pub const Value = V;
        pub const Context = Ctx;
        pub const GetOrPutResult = struct {
            value_ptr: *V,
            found_existing: bool,
        };
        pub const Config = struct {
            /// Requested initial slot count. Clamped to a minimum of 8 and
            /// rounded up to the next power of two.
            initial_capacity: usize = 8,
            seed: u64 = 0,
            max_load_percent: u8 = 70,
            budget: ?*memory.budget.Budget,
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

        pub fn init(allocator: std.mem.Allocator, config: Config) Error!Self {
            if (config.max_load_percent == 0 or config.max_load_percent > 95) return error.InvalidConfig;

            const cap = try nextPow2(@max(config.initial_capacity, 8));
            assert(cap >= 8);
            assert(std.math.isPowerOfTwo(cap));

            const init_bytes = tableBytes(cap) catch return error.Overflow;
            if (config.budget) |budget| {
                budget.tryReserve(init_bytes) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.InvalidConfig => return error.InvalidConfig,
                    error.Overflow => return error.Overflow,
                };
            }

            const entries = allocator.alloc(Entry, cap) catch {
                if (config.budget) |budget| budget.release(init_bytes);
                return error.OutOfMemory;
            };
            errdefer {
                allocator.free(entries);
                if (config.budget) |budget| budget.release(init_bytes);
            }

            const states = allocator.alloc(SlotState, cap) catch return error.OutOfMemory;
            assert(states.len == entries.len);
            @memset(states, .empty);

            var self: Self = .{
                .allocator = allocator,
                .budget = config.budget,
                .budget_reserved_bytes = init_bytes,
                .entries = entries,
                .states = states,
                .seed = config.seed,
                .max_load_percent = config.max_load_percent,
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

        /// Creates an independent copy with its own backing memory.
        pub fn clone(self: *const Self) Error!Self {
            self.assertInvariants();
            const cap = self.entries.len;
            const bytes = tableBytes(cap) catch return error.Overflow;

            if (self.budget) |budget| {
                budget.tryReserve(bytes) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.InvalidConfig => return error.InvalidConfig,
                    error.Overflow => return error.Overflow,
                };
            }

            const new_entries = self.allocator.alloc(Entry, cap) catch {
                if (self.budget) |budget| budget.release(bytes);
                return error.OutOfMemory;
            };
            errdefer {
                self.allocator.free(new_entries);
                if (self.budget) |budget| budget.release(bytes);
            }
            const new_states = self.allocator.alloc(SlotState, cap) catch return error.OutOfMemory;
            errdefer self.allocator.free(new_states);

            @memcpy(new_states, self.states);
            var index: usize = 0;
            while (index < cap) : (index += 1) {
                if (self.states[index] != .occupied) continue;
                new_entries[index] = self.entries[index];
            }

            var result: Self = .{
                .allocator = self.allocator,
                .budget = self.budget,
                .budget_reserved_bytes = bytes,
                .entries = new_entries,
                .states = new_states,
                .count = self.count,
                .tombstones = self.tombstones,
                .seed = self.seed,
                .max_load_percent = self.max_load_percent,
            };
            result.assertInvariants();
            return result;
        }

        pub fn len(self: *const Self) usize {
            self.assertInvariants();
            return self.count;
        }

        pub fn capacity(self: *const Self) usize {
            self.assertInvariants();
            return self.entries.len;
        }

        pub const IterEntry = struct {
            key_ptr: *const K,
            value_ptr: *V,
        };

        pub const ConstIterEntry = struct {
            key_ptr: *const K,
            value_ptr: *const V,
        };

        pub const Iterator = struct {
            entries: []Entry,
            states: []const SlotState,
            index: usize = 0,

            pub fn next(self: *Iterator) ?IterEntry {
                while (self.index < self.states.len) {
                    const index = self.index;
                    self.index += 1;
                    if (self.states[index] != .occupied) continue;
                    return .{
                        .key_ptr = &self.entries[index].key,
                        .value_ptr = &self.entries[index].value,
                    };
                }
                return null;
            }
        };

        pub const ConstIterator = struct {
            entries: []const Entry,
            states: []const SlotState,
            index: usize = 0,

            pub fn next(self: *ConstIterator) ?ConstIterEntry {
                while (self.index < self.states.len) {
                    const index = self.index;
                    self.index += 1;
                    if (self.states[index] != .occupied) continue;
                    return .{
                        .key_ptr = &self.entries[index].key,
                        .value_ptr = &self.entries[index].value,
                    };
                }
                return null;
            }
        };

        /// Returns an iterator over occupied entries only.
        /// Keys stay immutable through the iterator so callers cannot break
        /// the probing and stored-hash invariants by mutating them in place.
        pub fn iterator(self: *Self) Iterator {
            self.assertInvariants();
            return .{
                .entries = self.entries,
                .states = self.states,
            };
        }

        /// Returns a read-only iterator over occupied entries only.
        pub fn iteratorConst(self: *const Self) ConstIterator {
            self.assertInvariants();
            return .{
                .entries = self.entries,
                .states = self.states,
            };
        }

        /// Resets the map to empty without releasing backing memory or budget.
        /// Capacity and budget remain unchanged.
        pub fn clear(self: *Self) void {
            self.assertInvariants();
            @memset(self.states, .empty);
            self.count = 0;
            self.tombstones = 0;
            self.assertInvariants();
        }

        pub fn get(self: *Self, key: K) ?*V {
            const lookup_key = key;
            return self.getBorrowed(&lookup_key);
        }

        pub fn getBorrowed(self: *Self, key: *const K) ?*V {
            self.assertInvariants();
            const h = hashKeyBorrowed(key, self.seed);
            const slot = self.findSlot(key, h);
            if (!slot.found) return null;
            assert(slot.index < self.entries.len);
            return &self.entries[slot.index].value;
        }

        pub fn getConst(self: *const Self, key: K) ?*const V {
            const lookup_key = key;
            return self.getConstBorrowed(&lookup_key);
        }

        pub fn getConstBorrowed(self: *const Self, key: *const K) ?*const V {
            self.assertInvariants();
            const h = hashKeyBorrowed(key, self.seed);
            const slot = self.findSlot(key, h);
            if (!slot.found) return null;
            assert(slot.index < self.entries.len);
            return &self.entries[slot.index].value;
        }

        pub fn contains(self: *const Self, key: K) bool {
            const lookup_key = key;
            return self.containsBorrowed(&lookup_key);
        }

        pub fn containsBorrowed(self: *const Self, key: *const K) bool {
            self.assertInvariants();
            const h = hashKeyBorrowed(key, self.seed);
            return self.findExistingSlot(key, h) != null;
        }

        pub fn put(self: *Self, key: K, value: V) Error!void {
            self.assertInvariants();
            const before_count = self.count;
            const h = hashKeyBorrowed(&key, self.seed);
            if (self.findExistingSlot(&key, h)) |index| {
                self.entries[index].value = value;
                assert(self.count == before_count);
                self.assertInvariants();
                return;
            }
            try self.ensureInsertCapacity();
            const slot = self.findSlot(&key, h);
            assert(!slot.found);
            self.insertAt(slot.index, key, value, h);
            assert(self.count == before_count + 1);
            self.assertInvariants();
        }

        /// Returns the existing value pointer when `key` is already present, or
        /// inserts `default_value` and returns a pointer to the new slot.
        /// Any later structural mutation invalidates the returned pointer.
        pub fn getOrPut(self: *Self, key: K, default_value: V) Error!GetOrPutResult {
            self.assertInvariants();
            const h = hashKeyBorrowed(&key, self.seed);
            const slot_before_growth = self.findSlot(&key, h);
            if (slot_before_growth.found) {
                assert(slot_before_growth.index < self.entries.len);
                return .{
                    .value_ptr = &self.entries[slot_before_growth.index].value,
                    .found_existing = true,
                };
            }

            try self.ensureInsertCapacity();
            const slot = self.findSlot(&key, h);
            assert(!slot.found);
            self.insertAt(slot.index, key, default_value, h);
            self.assertInvariants();
            return .{
                .value_ptr = &self.entries[slot.index].value,
                .found_existing = false,
            };
        }

        pub fn putNoClobber(self: *Self, key: K, value: V) (error{AlreadyExists} || Error)!void {
            self.assertInvariants();
            const before_count = self.count;
            const h = hashKeyBorrowed(&key, self.seed);
            if (self.findExistingSlot(&key, h) != null) return error.AlreadyExists;
            try self.ensureInsertCapacity();
            const slot = self.findSlot(&key, h);
            assert(!slot.found);
            self.insertAt(slot.index, key, value, h);
            assert(self.count == before_count + 1);
            self.assertInvariants();
        }

        pub fn remove(self: *Self, key: K) Error!V {
            const lookup_key = key;
            return self.removeBorrowed(&lookup_key);
        }

        pub fn removeBorrowed(self: *Self, key: *const K) Error!V {
            self.assertInvariants();
            if (self.entries.len == 0) return error.NotFound;
            const before_count = self.count;
            const before_tombstones = self.tombstones;
            const h = hashKeyBorrowed(key, self.seed);
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

        pub fn removeOrNull(self: *Self, key: K) ?V {
            const lookup_key = key;
            return self.removeOrNullBorrowed(&lookup_key);
        }

        pub fn removeOrNullBorrowed(self: *Self, key: *const K) ?V {
            self.assertInvariants();
            if (self.entries.len == 0) return null;
            const before_count = self.count;
            const before_tombstones = self.tombstones;
            const h = hashKeyBorrowed(key, self.seed);
            const slot = self.findSlot(key, h);
            if (!slot.found) return null;

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
            errdefer {
                self.allocator.free(new_entries);
                if (self.budget) |budget| {
                    if (new_bytes > old_budget_bytes) {
                        budget.release(new_bytes - old_budget_bytes);
                        self.budget_reserved_bytes = old_budget_bytes;
                    }
                }
            }
            const new_states = self.allocator.alloc(SlotState, cap) catch return error.OutOfMemory;
            assert(new_states.len == new_entries.len);
            @memset(new_states, .empty);

            const old_entries = self.entries;
            const old_states = self.states;
            const old_len = old_entries.len;
            const old_count = self.count;

            // SAFETY: no fallible operations between self-mutation and old-table free.
            // The errdefer above references new_entries which becomes self.entries here.
            // Adding any `try` or error-returning call in this block would cause
            // use-after-free via the errdefer. Keep this section infallible.
            self.entries = new_entries;
            self.states = new_states;
            self.count = 0;
            self.tombstones = 0;

            var i: usize = 0;
            while (i < old_len) : (i += 1) {
                if (old_states[i] != .occupied) continue;
                const entry = old_entries[i];
                const slot = self.findSlot(&entry.key, entry.hash);
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

        fn findExistingSlot(self: *const Self, key: *const K, h: u64) ?usize {
            assert(self.entries.len == self.states.len);
            assert(self.entries.len > 0);
            assert(std.math.isPowerOfTwo(self.entries.len));
            const mask = self.entries.len - 1;
            var idx: usize = (@as(usize, @truncate(h)) & mask);
            var probes: usize = 0;
            while (probes < self.entries.len) : (probes += 1) {
                switch (self.states[idx]) {
                    .empty => return null,
                    .tombstone => {},
                    .occupied => {
                        if (self.entries[idx].hash == h and eqlKeyBorrowed(&self.entries[idx].key, key)) return idx;
                    },
                }
                idx = (idx + 1) & mask;
            }
            return null;
        }

        fn findSlot(self: *const Self, key: *const K, h: u64) SlotSearch {
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
                        if (self.entries[idx].hash == h and eqlKeyBorrowed(&self.entries[idx].key, key)) {
                            return .{ .index = idx, .found = true };
                        }
                    },
                }
                idx = (idx + 1) & mask;
            }
            // A full probe with no empty slot and no matching key means every slot is
            // either occupied (by a different key) or a tombstone. If first_tombstone is
            // set, reuse it. If not, the table is entirely occupied with distinct keys.
            // a state that cannot occur when insertions go through ensureInsertCapacity,
            // because the load-factor guard (count + tombstones + 1 <= capacity * load%)
            // prevents the table from ever being simultaneously full and tombstone-free.
            // Returning index 0 silently would corrupt the entry at slot 0; assert instead.
            assert(first_tombstone != null);
            return .{ .index = first_tombstone.?, .found = false };
        }

        fn hashKey(key: K, seed: u64) u64 {
            return hashKeyBorrowed(&key, seed);
        }

        fn hashKeyBorrowed(key: *const K, seed: u64) u64 {
            // Ctx.hash presence and arity are validated at comptime in validateCtx.
            if (comptime @hasDecl(Ctx, "hash")) {
                if (comptime ctxHashTakesBorrowed()) {
                    return Ctx.hash(key, seed);
                }
                return Ctx.hash(key.*, seed);
            }
            return defaultHashBorrowed(key, seed);
        }

        fn eqlKey(a: K, b: K) bool {
            return eqlKeyBorrowed(&a, &b);
        }

        fn eqlKeyBorrowed(a: *const K, b: *const K) bool {
            // Ctx.eql presence and arity are validated at comptime in validateCtx.
            if (comptime @hasDecl(Ctx, "eql")) {
                if (comptime ctxEqlTakesBorrowed()) {
                    return Ctx.eql(a, b);
                }
                return Ctx.eql(a.*, b.*);
            }
            return std.meta.eql(a.*, b.*);
        }

        fn defaultHash(key: K, seed: u64) u64 {
            return defaultHashBorrowed(&key, seed);
        }

        fn defaultHashBorrowed(key: *const K, seed: u64) u64 {
            var ctx = static_hash.wyhash.Wyhash64.init(seed);
            ctx.update(std.mem.asBytes(key));
            return ctx.final();
        }

        fn ctxHashTakesBorrowed() bool {
            const hash_info = @typeInfo(@TypeOf(Ctx.hash));
            const hash_fn = hash_info.@"fn";
            return hash_fn.params[0].type.? == *const K;
        }

        fn ctxEqlTakesBorrowed() bool {
            const eql_info = @typeInfo(@TypeOf(Ctx.eql));
            const eql_fn = eql_info.@"fn";
            return eql_fn.params[0].type.? == *const K;
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

        pub fn init(allocator: std.mem.Allocator, config: Map.Config) Error!Self {
            return .{ .map = try Map.init(allocator, config) };
        }

        pub fn clone(self: *const Self) Error!Self {
            return .{ .map = try self.map.clone() };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            return self.map.len();
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.map.contains(key);
        }

        pub fn containsBorrowed(self: *const Self, key: *const K) bool {
            return self.map.containsBorrowed(key);
        }

        pub fn insert(self: *Self, key: K) Error!void {
            try self.map.put(key, {});
        }

        pub fn remove(self: *Self, key: K) Error!void {
            _ = try self.map.remove(key);
        }

        pub fn removeBorrowed(self: *Self, key: *const K) Error!void {
            _ = try self.map.removeBorrowed(key);
        }

        pub fn removeOrNull(self: *Self, key: K) bool {
            return self.map.removeOrNull(key) != null;
        }

        pub fn removeOrNullBorrowed(self: *Self, key: *const K) bool {
            return self.map.removeOrNullBorrowed(key) != null;
        }

        pub fn clear(self: *Self) void {
            self.map.clear();
        }
    };
}

test "flat hash map basic put/get/remove" {
    // Goal: verify basic CRUD behavior and missing-key semantics.
    // Method: insert, retrieve, remove, and assert NotFound on repeated removal.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(1, 10);
    try map.putNoClobber(2, 20);
    try testing.expectEqual(@as(u32, 10), map.get(1).?.*);
    try testing.expectEqual(@as(u32, 20), map.get(2).?.*);
    try testing.expectEqual(@as(u32, 10), try map.remove(1));
    try testing.expectError(error.NotFound, map.remove(1));
}

test "flat hash map rejects invalid load factor configuration" {
    // Goal: reject configuration outside the supported load factor interval.
    // Method: initialize with max_load_percent at invalid low and high bounds.
    const Ctx = struct {};
    try testing.expectError(
        error.InvalidConfig,
        FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .max_load_percent = 0, .budget = null }),
    );
    try testing.expectError(
        error.InvalidConfig,
        FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .max_load_percent = 96, .budget = null }),
    );
}

test "flat hash map put updates existing key without changing len" {
    // Goal: ensure put overwrites value for an existing key.
    // Method: write same key twice and assert cardinality remains one.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(7, 10);
    try map.put(7, 20);
    assert(map.len() == 1);
    try testing.expectEqual(@as(usize, 1), map.len());
    try testing.expectEqual(@as(u32, 20), map.get(7).?.*);
}

test "flat hash map reuses tombstone slots after remove" {
    // Goal: verify removed slots are reusable for future insertions.
    // Method: remove one key, insert another, then validate reachable values.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .initial_capacity = 8, .budget = null });
    defer map.deinit();

    try map.put(1, 10);
    try map.put(2, 20);
    _ = try map.remove(1);
    try map.put(3, 30);

    try testing.expect(map.get(1) == null);
    try testing.expectEqual(@as(u32, 20), map.get(2).?.*);
    try testing.expectEqual(@as(u32, 30), map.get(3).?.*);
}

test "flat hash map rehash preserves all entries" {
    // Goal: verify growth preserves key/value associations.
    // Method: insert enough keys to force resize and then read them all back.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .initial_capacity = 8, .budget = null });
    defer map.deinit();

    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        try map.put(i, i * 10);
    }
    try testing.expect(map.capacity() >= 64);

    i = 0;
    while (i < 64) : (i += 1) {
        try testing.expectEqual(i * 10, map.get(i).?.*);
    }
}

test "flat hash set insert contains remove" {
    // Goal: ensure set wrapper forwards map semantics correctly.
    // Method: insert one key, check containment, remove, then assert absence.
    const Ctx = struct {};
    var set = try FlatHashSet(u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer set.deinit();

    try set.insert(9);
    try testing.expect(set.contains(9));
    try set.remove(9);
    try testing.expect(!set.contains(9));
    try testing.expectError(error.NotFound, set.remove(9));
}

test "flat hash map clear resets count and allows reuse" {
    // Goal: confirm clear resets logical state while preserving capacity and budget.
    // Method: insert values, clear, verify empty, then reinsert.
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(1, 10);
    try map.put(2, 20);
    try testing.expectEqual(@as(usize, 2), map.len());
    const cap_before = map.capacity();

    map.clear();
    try testing.expectEqual(@as(usize, 0), map.len());
    try testing.expectEqual(cap_before, map.capacity());
    try testing.expect(map.get(1) == null);

    try map.put(3, 30);
    try testing.expectEqual(@as(usize, 1), map.len());
    try testing.expectEqual(@as(u32, 30), map.get(3).?.*);
}

test "flat hash map with custom Ctx hash and eql" {
    // Goal: exercise the custom Ctx code path with explicit hash and eql.
    // Method: use a context that hashes only the low byte and compares mod 256.
    const ModCtx = struct {
        pub fn hash(key: u32, seed: u64) u64 {
            _ = seed;
            return @as(u64, key & 0xFF);
        }
        pub fn eql(a: u32, b: u32) bool {
            return (a & 0xFF) == (b & 0xFF);
        }
    };
    var map = try FlatHashMap(u32, u32, ModCtx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(1, 10);
    try map.put(2, 20);
    try testing.expectEqual(@as(u32, 10), map.get(1).?.*);
    try testing.expectEqual(@as(u32, 20), map.get(2).?.*);

    // 257 & 0xFF == 1, so this should overwrite key 1.
    try map.put(257, 99);
    try testing.expectEqual(@as(usize, 2), map.len());
    try testing.expectEqual(@as(u32, 99), map.get(1).?.*);
}

test "flat hash map supports borrowed lookups with pointer-style ctx callbacks" {
    const Key = struct {
        bucket: u64,
        id: u64,
        tag: u32,
        pad: u32 = 0,
    };
    const PtrCtx = struct {
        pub fn hash(key: *const Key, seed: u64) u64 {
            var hasher = static_hash.wyhash.Wyhash64.init(seed);
            hasher.update(std.mem.asBytes(&key.bucket));
            hasher.update(std.mem.asBytes(&key.id));
            hasher.update(std.mem.asBytes(&key.tag));
            return hasher.final();
        }

        pub fn eql(a: *const Key, b: *const Key) bool {
            return a.bucket == b.bucket and a.id == b.id and a.tag == b.tag;
        }
    };

    var map = try FlatHashMap(Key, u32, PtrCtx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(.{ .bucket = 1, .id = 10, .tag = 3 }, 100);
    try map.put(.{ .bucket = 2, .id = 20, .tag = 7 }, 200);

    const lookup = Key{ .bucket = 2, .id = 20, .tag = 7 };
    try testing.expect(map.containsBorrowed(&lookup));
    try testing.expectEqual(@as(u32, 200), map.getConstBorrowed(&lookup).?.*);
    try testing.expectEqual(@as(u32, 200), try map.removeBorrowed(&lookup));
    try testing.expect(!map.containsBorrowed(&lookup));
}

test "flat hash map clone preserves tombstones and live entries" {
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.putNoClobber(1, 10);
    try map.putNoClobber(2, 20);
    _ = try map.remove(1);
    try map.putNoClobber(3, 30);

    var clone = try map.clone();
    defer clone.deinit();

    try testing.expectEqual(map.len(), clone.len());
    try testing.expectEqual(map.tombstones, clone.tombstones);
    try testing.expect(clone.getConst(1) == null);
    try testing.expectEqual(@as(u32, 20), clone.getConst(2).?.*);
    try testing.expectEqual(@as(u32, 30), clone.getConst(3).?.*);
}

test "flat hash map iterator visits occupied entries and supports value mutation" {
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.putNoClobber(1, 10);
    try map.putNoClobber(2, 20);
    try map.putNoClobber(3, 30);
    _ = try map.remove(2);

    var count: usize = 0;
    var sum_keys: u32 = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        sum_keys += entry.key_ptr.*;
        entry.value_ptr.* += 5;
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(u32, 4), sum_keys);
    try testing.expectEqual(@as(u32, 15), map.getConst(1).?.*);
    try testing.expectEqual(@as(u32, 35), map.getConst(3).?.*);
}

test "flat hash map const iterator skips tombstones and empty slots" {
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.putNoClobber(4, 40);
    try map.putNoClobber(5, 50);
    _ = try map.remove(4);

    const const_map: *const FlatHashMap(u32, u32, Ctx) = &map;
    var count: usize = 0;
    var it = const_map.iteratorConst();
    while (it.next()) |entry| {
        try testing.expectEqual(@as(u32, 5), entry.key_ptr.*);
        try testing.expectEqual(@as(u32, 50), entry.value_ptr.*);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "flat hash map getOrPut reports whether insertion happened" {
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    const inserted = try map.getOrPut(8, 80);
    try testing.expect(!inserted.found_existing);
    inserted.value_ptr.* += 1;

    const existing = try map.getOrPut(8, 99);
    try testing.expect(existing.found_existing);
    try testing.expectEqual(@as(u32, 81), existing.value_ptr.*);
    try testing.expectEqual(@as(usize, 1), map.len());
}

test "flat hash map removeOrNull keeps strict remove available" {
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(1, 10);
    try testing.expectEqual(@as(?u32, 10), map.removeOrNull(1));
    try testing.expectEqual(@as(?u32, null), map.removeOrNull(1));
    try testing.expectError(error.NotFound, map.remove(1));
}

test "flat hash map clone after clear preserves empty logical state" {
    const Ctx = struct {};
    var map = try FlatHashMap(u32, u32, Ctx).init(testing.allocator, .{
        .initial_capacity = 16,
        .budget = null,
    });
    defer map.deinit();

    try map.putNoClobber(1, 10);
    try map.putNoClobber(2, 20);
    map.clear();

    var clone = try map.clone();
    defer clone.deinit();

    try testing.expectEqual(@as(usize, 0), clone.len());
    try testing.expectEqual(map.capacity(), clone.capacity());
    try testing.expect(clone.getConst(1) == null);

    try clone.putNoClobber(3, 30);
    try testing.expectEqual(@as(usize, 1), clone.len());
    try testing.expectEqual(@as(u32, 30), clone.getConst(3).?.*);
    try testing.expectEqual(@as(usize, 0), map.len());
}

test "flat hash map overwrite does not allocate before proving insertion is needed" {
    const Ctx = struct {};
    const Map = FlatHashMap(u32, u32, Ctx);
    const init_capacity = 8;
    const init_bytes = init_capacity * @sizeOf(Map.Entry) + init_capacity * @sizeOf(SlotState);
    var budget = try memory.budget.Budget.init(init_bytes);

    var map = try Map.init(testing.allocator, .{
        .initial_capacity = init_capacity,
        .budget = &budget,
    });
    defer map.deinit();

    var key: u32 = 0;
    while (key < 5) : (key += 1) {
        try map.putNoClobber(key, key * 10);
    }
    const cap_before = map.capacity();
    const budget_before = budget.used();

    try map.put(2, 999);

    try testing.expectEqual(cap_before, map.capacity());
    try testing.expectEqual(budget_before, budget.used());
    try testing.expectEqual(@as(usize, 5), map.len());
    try testing.expectEqual(@as(u32, 999), map.getConst(2).?.*);
}

test "flat hash map getOrPut existing key does not allocate before insertion is proven" {
    const Ctx = struct {};
    const Map = FlatHashMap(u32, u32, Ctx);
    const init_capacity = 8;
    const init_bytes = init_capacity * @sizeOf(Map.Entry) + init_capacity * @sizeOf(SlotState);
    var budget = try memory.budget.Budget.init(init_bytes);

    var map = try Map.init(testing.allocator, .{
        .initial_capacity = init_capacity,
        .budget = &budget,
    });
    defer map.deinit();

    var key: u32 = 0;
    while (key < 5) : (key += 1) {
        try map.putNoClobber(key, key * 10);
    }
    const cap_before = map.capacity();
    const budget_before = budget.used();

    const result = try map.getOrPut(2, 999);

    try testing.expect(result.found_existing);
    try testing.expectEqual(cap_before, map.capacity());
    try testing.expectEqual(budget_before, budget.used());
    try testing.expectEqual(@as(usize, 5), map.len());
    try testing.expectEqual(@as(u32, 20), result.value_ptr.*);
}

test "flat hash map duplicate rejection beats growth failure" {
    const Ctx = struct {};
    const Map = FlatHashMap(u32, u32, Ctx);
    const init_capacity = 8;
    const init_bytes = init_capacity * @sizeOf(Map.Entry) + init_capacity * @sizeOf(SlotState);
    var budget = try memory.budget.Budget.init(init_bytes);

    var map = try Map.init(testing.allocator, .{
        .initial_capacity = init_capacity,
        .budget = &budget,
    });
    defer map.deinit();

    var key: u32 = 0;
    while (key < 5) : (key += 1) {
        try map.putNoClobber(key, key * 10);
    }
    const cap_before = map.capacity();
    const budget_before = budget.used();

    try testing.expectError(error.AlreadyExists, map.putNoClobber(4, 444));
    try testing.expectEqual(cap_before, map.capacity());
    try testing.expectEqual(budget_before, budget.used());
    try testing.expectEqual(@as(u32, 40), map.getConst(4).?.*);
}

test "flat hash map custom hash supports padded composite keys" {
    const Key = struct {
        tag: u8,
        value: u32,
    };
    const PaddedCtx = struct {
        pub fn hash(key: Key, seed: u64) u64 {
            var hasher = static_hash.wyhash.Wyhash64.init(seed);
            hasher.update(std.mem.asBytes(&key.tag));
            hasher.update(std.mem.asBytes(&key.value));
            return hasher.final();
        }

        pub fn eql(a: Key, b: Key) bool {
            return a.tag == b.tag and a.value == b.value;
        }
    };
    const Map = FlatHashMap(Key, u32, PaddedCtx);

    var first: Key = undefined;
    @memset(std.mem.asBytes(&first), 0x00);
    first.tag = 7;
    first.value = 42;

    var second: Key = undefined;
    @memset(std.mem.asBytes(&second), 0xFF);
    second.tag = 7;
    second.value = 42;

    try testing.expect(std.meta.eql(first, second));

    var map = try Map.init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(first, 99);
    try testing.expectEqual(@as(u32, 99), map.getConst(second).?.*);
}

test "flat hash map default-hash risk helper flags union-shaped keys" {
    const UnionKey = union(enum) {
        number: u32,
        pair: struct { left: u32, right: u32 },
    };
    const NestedUnionKey = struct {
        key: UnionKey,
    };

    try testing.expect(hasDefaultHashRepresentationRisk(UnionKey));
    try testing.expect(hasDefaultHashRepresentationRisk(?UnionKey));
    try testing.expect(hasDefaultHashRepresentationRisk(NestedUnionKey));
    try testing.expect(!hasDefaultHashRepresentationRisk(u32));
    try testing.expect(!hasDefaultHashRepresentationRisk(struct { left: u32, right: u32 }));
}

test "flat hash map custom hash supports union-shaped keys" {
    const Key = union(enum) {
        number: u32,
        pair: struct { left: u32, right: u32 },
    };
    const UnionCtx = struct {
        pub fn hash(key: *const Key, seed: u64) u64 {
            var hasher = static_hash.wyhash.Wyhash64.init(seed);
            switch (key.*) {
                .number => |value| {
                    const tag: u8 = 0;
                    hasher.update(std.mem.asBytes(&tag));
                    hasher.update(std.mem.asBytes(&value));
                },
                .pair => |pair| {
                    const tag: u8 = 1;
                    hasher.update(std.mem.asBytes(&tag));
                    hasher.update(std.mem.asBytes(&pair.left));
                    hasher.update(std.mem.asBytes(&pair.right));
                },
            }
            return hasher.final();
        }

        pub fn eql(a: *const Key, b: *const Key) bool {
            return switch (a.*) {
                .number => |value_a| switch (b.*) {
                    .number => |value_b| value_a == value_b,
                    else => false,
                },
                .pair => |pair_a| switch (b.*) {
                    .pair => |pair_b| pair_a.left == pair_b.left and pair_a.right == pair_b.right,
                    else => false,
                },
            };
        }
    };

    var map = try FlatHashMap(Key, u32, UnionCtx).init(testing.allocator, .{ .budget = null });
    defer map.deinit();

    try map.put(.{ .number = 7 }, 70);
    try map.put(.{ .pair = .{ .left = 1, .right = 2 } }, 12);

    try testing.expectEqual(@as(u32, 70), map.getConst(.{ .number = 7 }).?.*);
    try testing.expectEqual(@as(u32, 12), map.getConst(.{ .pair = .{ .left = 1, .right = 2 } }).?.*);
}

test "flat hash set supports borrowed contains and remove" {
    const Key = struct {
        bucket: u64,
        id: u64,
        tag: u32,
        pad: u32 = 0,
    };
    const PtrCtx = struct {
        pub fn hash(key: *const Key, seed: u64) u64 {
            var hasher = static_hash.wyhash.Wyhash64.init(seed);
            hasher.update(std.mem.asBytes(&key.bucket));
            hasher.update(std.mem.asBytes(&key.id));
            hasher.update(std.mem.asBytes(&key.tag));
            return hasher.final();
        }

        pub fn eql(a: *const Key, b: *const Key) bool {
            return a.bucket == b.bucket and a.id == b.id and a.tag == b.tag;
        }
    };

    var set = try FlatHashSet(Key, PtrCtx).init(testing.allocator, .{ .budget = null });
    defer set.deinit();

    const entry = Key{ .bucket = 9, .id = 42, .tag = 1 };
    try set.insert(entry);
    try testing.expect(set.containsBorrowed(&entry));
    try set.removeBorrowed(&entry);
    try testing.expect(!set.containsBorrowed(&entry));
}
