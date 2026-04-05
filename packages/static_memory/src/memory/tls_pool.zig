//! Thread-local object pool with a bounded global free list.
//!
//! Key types: `TlsPool(T)`, `Config`, `TlsPoolError`.
//! Usage pattern: call `TlsPool(T).init` with a `Config`, then `acquire()` to borrow an object and
//! `release()` to return it. Call `deinit()` when done.
//! Thread safety: fully thread-safe. Each thread is assigned a slot on first use; `acquire`/`release`
//! are lock-free on the fast path and use a global mutex only when the local cache is empty or full.
//! `freeCount()` is best-effort due to the unsynchronised sum of local caches.
//! Memory budget: all object storage, local caches, and thread-slot tables are allocated once at init
//! and freed at deinit. No allocation occurs on the hot acquire/release path.

const std = @import("std");
const assert = std.debug.assert;
const sync = @import("static_sync");

pub const TlsPoolError = error{
    InvalidConfig,
    OutOfMemory,
    PoolExhausted,
    InvalidObject,
    TooManyThreads,
};

pub const Config = struct {
    total_capacity: u32,
    local_cache_size: u32 = 32,
    max_threads: u32 = 64,
    enable_safety_checks: bool = true,
};

// Monotonically increasing instance counter. Each TlsPool.init increments this
// and stamps the pool with the result so the TLS cache can detect stale entries
// when a new pool is initialized at the same address as a destroyed pool.
// Starts at 1 so that generation 0 is always the "uninitialized" sentinel.
var pool_generation_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub fn TlsPool(comptime T: type) type {
    comptime {
        if (@sizeOf(T) == 0) @compileError("TlsPool cannot pool zero-sized types");
    }

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        cfg: Config,

        storage: []T,
        global_free: []*T,
        global_free_count: u32,
        global_lock: Mutex,

        local_caches: []LocalCache,
        local_cache_storage: [][*]*T,

        thread_slots: []std.atomic.Value(u64),
        thread_slot_count: std.atomic.Value(u32),
        // Unique value assigned at init from pool_generation_counter. The TLS cache
        // stores this alongside the pool pointer so that a pool recreated at the same
        // address as a destroyed pool is not served stale slots from the old instance.
        generation: u64,

        const Allocator = std.mem.Allocator;
        const Mutex = std.Thread.Mutex;
        // `maxInt(u64)` is never a real thread identifier, so it is a stable empty-slot marker.
        const empty_slot_sentinel: u64 = std.math.maxInt(u64);

        const LocalCache = struct {
            objects: [*]*T,
            count: std.atomic.Value(u32),
            max_size: u32,
            active: std.atomic.Value(u8),
        };

        threadlocal var tls_cached_pool: usize = 0;
        threadlocal var tls_cached_slot: u32 = 0;
        threadlocal var tls_cached_generation: u64 = 0;

        pub fn init(allocator: Allocator, cfg: Config) TlsPoolError!Self {
            if (!sync.caps.Caps.threadsEnabled()) return error.InvalidConfig;
            // Preconditions: all capacity fields must be non-zero; zero values produce
            // degenerate pools that violate every downstream bounds invariant.
            if (cfg.total_capacity == 0) return error.InvalidConfig;
            if (cfg.max_threads == 0) return error.InvalidConfig;
            if (cfg.local_cache_size == 0) return error.InvalidConfig;

            const storage = allocator.alloc(T, cfg.total_capacity) catch return error.OutOfMemory;
            errdefer allocator.free(storage);

            const global_free = allocator.alloc(*T, cfg.total_capacity) catch return error.OutOfMemory;
            errdefer allocator.free(global_free);

            for (global_free, 0..) |*slot, i| {
                slot.* = &storage[i];
            }

            const local_caches = allocator.alloc(LocalCache, cfg.max_threads) catch return error.OutOfMemory;
            errdefer allocator.free(local_caches);

            const cache_storage_size: usize = std.math.mul(
                usize,
                @as(usize, cfg.local_cache_size),
                @as(usize, cfg.max_threads),
            ) catch return error.OutOfMemory;
            const cache_storage = allocator.alloc(*T, cache_storage_size) catch return error.OutOfMemory;
            errdefer allocator.free(cache_storage);

            const local_cache_storage = allocator.alloc([*]*T, cfg.max_threads) catch return error.OutOfMemory;
            errdefer allocator.free(local_cache_storage);

            for (local_caches, local_cache_storage, 0..) |*cache, *storage_ptr, i| {
                storage_ptr.* = cache_storage.ptr + i * @as(usize, cfg.local_cache_size);
                cache.* = .{
                    .objects = storage_ptr.*,
                    .count = std.atomic.Value(u32).init(0),
                    .max_size = cfg.local_cache_size,
                    .active = std.atomic.Value(u8).init(0),
                };
            }

            const thread_slots = allocator.alloc(std.atomic.Value(u64), cfg.max_threads) catch return error.OutOfMemory;
            errdefer allocator.free(thread_slots);
            for (thread_slots) |*slot| slot.* = std.atomic.Value(u64).init(empty_slot_sentinel);

            const out: Self = .{
                .allocator = allocator,
                .cfg = cfg,
                .storage = storage,
                .global_free = global_free,
                .global_free_count = cfg.total_capacity,
                .global_lock = .{},
                .local_caches = local_caches,
                .local_cache_storage = local_cache_storage,
                .thread_slots = thread_slots,
                .thread_slot_count = std.atomic.Value(u32).init(0),
                // fetchAdd returns the old value; counter starts at 1 so no pool ever
                // receives generation 0, which is the TLS cache "uninitialized" sentinel.
                .generation = pool_generation_counter.fetchAdd(1, .monotonic),
            };
            // Postcondition: generation must be non-zero so that TLS cache comparisons can
            // always distinguish an uninitialized (0) cache entry from a live pool.
            assert(out.generation != 0);
            // Postcondition: free count must equal total_capacity at construction; every
            // storage slot starts on the global free list.
            assert(out.global_free_count == cfg.total_capacity);
            return out;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: pool must be initialized (generation non-zero).
            assert(self.generation != 0);
            // Precondition: storage slice must be non-empty to ensure we free the right buffer.
            assert(self.storage.len != 0);
            // `init()` rejects configurations where this multiplication overflows `usize`.
            const cache_storage_size: usize = std.math.mul(
                usize,
                @as(usize, self.cfg.local_cache_size),
                @as(usize, self.cfg.max_threads),
            ) catch unreachable;
            const cache_base: [*]*T = self.local_cache_storage[0];
            self.allocator.free(cache_base[0..cache_storage_size]);

            self.allocator.free(self.local_cache_storage);
            self.allocator.free(self.local_caches);
            self.allocator.free(self.thread_slots);
            self.allocator.free(self.global_free);
            self.allocator.free(self.storage);
            self.* = undefined;
        }

        pub fn acquire(self: *Self) TlsPoolError!*T {
            // Precondition: pool must be initialized.
            assert(self.generation != 0);
            const slot = try self.getThreadSlot();
            // Precondition: the returned slot must be within the allocated thread slots range.
            assert(@as(usize, slot) < self.local_caches.len);
            const cache = &self.local_caches[@intCast(slot)];

            const count = cache.count.load(.monotonic);
            if (count > 0) {
                const next = count - 1;
                cache.count.store(next, .monotonic);
                return cache.objects[next];
            }

            return self.refillAndAcquire(cache);
        }

        pub fn release(self: *Self, obj: *T) TlsPoolError!void {
            // Precondition: pool must be initialized.
            assert(self.generation != 0);
            // Precondition: released pointer must be non-null.
            assert(@intFromPtr(obj) != 0);
            if (self.cfg.enable_safety_checks) {
                const obj_addr = @intFromPtr(obj);
                const start = @intFromPtr(self.storage.ptr);
                const bytes = std.math.mul(usize, @sizeOf(T), self.storage.len) catch return error.InvalidObject;
                const end = std.math.add(usize, start, bytes) catch return error.InvalidObject;
                if (obj_addr < start or obj_addr >= end) return error.InvalidObject;
                if ((obj_addr - start) % @sizeOf(T) != 0) return error.InvalidObject;
            }

            const slot = try self.getThreadSlot();
            // Postcondition: slot must be in range after allocation.
            assert(@as(usize, slot) < self.local_caches.len);
            const cache = &self.local_caches[@intCast(slot)];

            const count = cache.count.load(.monotonic);
            if (count < cache.max_size) {
                cache.objects[count] = obj;
                cache.count.store(count + 1, .monotonic);
                return;
            }

            self.drainAndRelease(cache, obj);
        }

        pub fn freeCount(self: *Self) u32 {
            // Precondition: pool must be initialized.
            assert(self.generation != 0);
            var total: u32 = 0;

            self.global_lock.lock();
            total = self.global_free_count;
            // Precondition: global free count must never exceed total capacity.
            assert(total <= self.cfg.total_capacity);
            self.global_lock.unlock();

            for (self.local_caches) |*cache| {
                if (cache.active.load(.acquire) != 0) total +|= cache.count.load(.monotonic);
            }

            return total;
        }

        fn getThreadSlot(self: *Self) TlsPoolError!u32 {
            const self_id: usize = @intFromPtr(self);
            assert(self.generation != 0);
            // Validate both address and generation: a pool recreated at the same address
            // as a destroyed pool will have a different generation, preventing stale reuse.
            if (tls_cached_pool == self_id and tls_cached_generation == self.generation) {
                // Pair assertion: cached slot must be within the local_caches bounds.
                assert(@as(usize, tls_cached_slot) < self.local_caches.len);
                return tls_cached_slot;
            }

            const slot = try self.allocateThreadSlot();
            // Postcondition: the freshly allocated slot must be in bounds.
            assert(@as(usize, slot) < self.thread_slots.len);
            tls_cached_pool = self_id;
            tls_cached_generation = self.generation;
            tls_cached_slot = slot;
            return slot;
        }

        fn allocateThreadSlot(self: *Self) TlsPoolError!u32 {
            const thread_id: u64 = @intCast(std.Thread.getCurrentId());
            // A real thread ID must never equal the empty sentinel; if it did, the slot
            // registration CAS would incorrectly claim an already-occupied slot or loop
            // forever. Assert here so any future port to a platform with TID == maxInt(u64)
            // fails visibly rather than corrupting the slot table silently.
            assert(thread_id != empty_slot_sentinel);
            // Precondition: thread_slots must have been allocated.
            assert(self.thread_slots.len != 0);

            for (self.thread_slots, 0..) |*slot, i| {
                const current = slot.load(.monotonic);

                if (current == empty_slot_sentinel) {
                    if (slot.cmpxchgWeak(empty_slot_sentinel, thread_id, .acquire, .monotonic) == null) {
                        self.local_caches[i].active.store(1, .release);
                        _ = self.thread_slot_count.fetchAdd(1, .monotonic);
                        return @intCast(i);
                    }
                } else if (current == thread_id) {
                    return @intCast(i);
                }
            }

            return error.TooManyThreads;
        }

        fn refillAndAcquire(self: *Self, cache: *LocalCache) TlsPoolError!*T {
            self.global_lock.lock();
            defer self.global_lock.unlock();

            if (self.global_free_count == 0) return error.PoolExhausted;

            // Precondition: global free count must be within capacity bounds.
            assert(self.global_free_count <= self.global_free.len);
            const take_u32: u32 = @min(self.global_free_count, cache.max_size / 2 + 1);
            // Precondition: take must be at least 1 because global_free_count > 0 above.
            assert(take_u32 > 0);
            const take: usize = @intCast(take_u32);
            const start: usize = @intCast(self.global_free_count - take_u32);

            std.mem.copyForwards(*T, cache.objects[0..take], self.global_free[start .. start + take]);

            self.global_free_count -= take_u32;
            cache.count.store(take_u32 - 1, .monotonic);
            return cache.objects[take_u32 - 1];
        }

        fn drainAndRelease(self: *Self, cache: *LocalCache, obj: *T) void {
            self.global_lock.lock();
            defer self.global_lock.unlock();

            // Precondition: released object pointer must be non-null.
            assert(@intFromPtr(obj) != 0);
            const count = cache.count.load(.monotonic);
            const to_drain_u32: u32 = count / 2;
            const keep_u32: u32 = count - to_drain_u32;

            const to_drain: usize = @intCast(to_drain_u32);
            const keep: usize = @intCast(keep_u32);

            // Widen to u64 before addition: both operands are u32 and their sum could
            // overflow u32 if near maxInt(u32), producing a false bound check.
            assert(
                @as(u64, self.global_free_count) + @as(u64, to_drain_u32) <= self.global_free.len,
            );
            std.mem.copyForwards(
                *T,
                self.global_free[@intCast(self.global_free_count)..][0..to_drain],
                cache.objects[keep .. keep + to_drain],
            );

            self.global_free_count += to_drain_u32;
            cache.count.store(keep_u32, .monotonic);

            cache.objects[@intCast(keep_u32)] = obj;
            cache.count.store(keep_u32 + 1, .monotonic);
        }
    };
}

test "TlsPool basic acquire/release" {
    // Verifies basic acquire/release behavior and that freed objects are reused by subsequent acquires.
    const testing = std.testing;
    if (!sync.caps.Caps.threadsEnabled()) return error.SkipZigTest;

    var pool = try TlsPool(u32).init(testing.allocator, .{
        .total_capacity = 8,
        .max_threads = 4,
        .local_cache_size = 4,
    });
    defer pool.deinit();

    const a = try pool.acquire();
    a.* = 123;
    try pool.release(a);

    const b = try pool.acquire();
    try testing.expectEqual(@as(u32, 123), b.*);
    try pool.release(b);
}

test "TlsPool rejects invalid config" {
    // Verifies invalid configurations are rejected deterministically.
    const testing = std.testing;

    try testing.expectError(error.InvalidConfig, TlsPool(u32).init(testing.allocator, .{
        .total_capacity = 0,
        .max_threads = 1,
        .local_cache_size = 1,
    }));
    try testing.expectError(error.InvalidConfig, TlsPool(u32).init(testing.allocator, .{
        .total_capacity = 1,
        .max_threads = 0,
        .local_cache_size = 1,
    }));
    try testing.expectError(error.InvalidConfig, TlsPool(u32).init(testing.allocator, .{
        .total_capacity = 1,
        .max_threads = 1,
        .local_cache_size = 0,
    }));
}

test "TlsPool returns PoolExhausted when empty" {
    // Verifies exhaustion is surfaced via `error.PoolExhausted` once all objects are acquired.
    const testing = std.testing;
    if (!sync.caps.Caps.threadsEnabled()) return error.SkipZigTest;

    var pool = try TlsPool(u32).init(testing.allocator, .{
        .total_capacity = 2,
        .max_threads = 1,
        .local_cache_size = 2,
    });
    defer pool.deinit();

    const a = try pool.acquire();
    const b = try pool.acquire();
    try testing.expectError(error.PoolExhausted, pool.acquire());

    try pool.release(a);
    try pool.release(b);
}

test "TlsPool release rejects non-owned objects when safety checks enabled" {
    // Verifies `release()` rejects pointers not sourced from the pool's backing storage.
    const testing = std.testing;
    if (!sync.caps.Caps.threadsEnabled()) return error.SkipZigTest;

    var pool = try TlsPool(u32).init(testing.allocator, .{
        .total_capacity = 1,
        .max_threads = 1,
        .local_cache_size = 1,
        .enable_safety_checks = true,
    });
    defer pool.deinit();

    const other = try testing.allocator.create(u32);
    defer testing.allocator.destroy(other);
    try testing.expectError(error.InvalidObject, pool.release(other));
}
