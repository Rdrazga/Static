//! PaddedAtomic: cache-line padded atomic wrapper to prevent false sharing.
//!
//! Thread safety: inherits the thread safety of the wrapped `std.atomic.Value`.
//! Single-threaded mode: padding is still present; no behavioral difference.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub fn PaddedAtomic(comptime T: type) type {
    return extern struct {
        pub const Value = T;
        pub const cache_line_bytes: usize = 64;

        comptime {
            assert(cache_line_bytes > 0);
            assert((cache_line_bytes & (cache_line_bytes - 1)) == 0);
            assert(cache_line_bytes >= @alignOf(std.atomic.Value(T)));
        }

        value: std.atomic.Value(T) align(cache_line_bytes),

        pub fn init(v: T) @This() {
            var padded = @This(){ .value = std.atomic.Value(T).init(v) };
            assert(@intFromPtr(&padded.value) % cache_line_bytes == 0);
            return padded;
        }

        pub fn load(self: *const @This(), comptime order: std.builtin.AtomicOrder) T {
            assert(@intFromPtr(&self.value) % cache_line_bytes == 0);
            return self.value.load(order);
        }

        pub fn store(self: *@This(), v: T, comptime order: std.builtin.AtomicOrder) void {
            assert(@intFromPtr(&self.value) % cache_line_bytes == 0);
            self.value.store(v, order);
        }

        pub fn swap(self: *@This(), v: T, comptime order: std.builtin.AtomicOrder) T {
            assert(@intFromPtr(&self.value) % cache_line_bytes == 0);
            return self.value.swap(v, order);
        }

        pub fn cmpxchgWeak(
            self: *@This(),
            expected: T,
            desired: T,
            comptime success: std.builtin.AtomicOrder,
            comptime failure: std.builtin.AtomicOrder,
        ) ?T {
            assert(@intFromPtr(&self.value) % cache_line_bytes == 0);
            return self.value.cmpxchgWeak(expected, desired, success, failure);
        }

        pub fn fetchAdd(self: *@This(), delta: T, comptime order: std.builtin.AtomicOrder) T {
            assert(@intFromPtr(&self.value) % cache_line_bytes == 0);
            return self.value.fetchAdd(delta, order);
        }
    };
}

test "padded atomic basic operations" {
    // Goal: verify simple load/store/swap semantics.
    // Method: perform sequential operations and assert observed values.
    var p = PaddedAtomic(u32).init(1);
    try testing.expectEqual(@as(u32, 1), p.load(.monotonic));
    p.store(2, .release);
    try testing.expectEqual(@as(u32, 2), p.swap(3, .acq_rel));
    try testing.expectEqual(@as(u32, 3), p.load(.acquire));
}

test "padded atomic is cache-line aligned" {
    // Goal: verify layout keeps value on cache-line boundaries.
    // Method: check type alignment and runtime pointer alignment.
    const Padded = PaddedAtomic(u64);
    try testing.expectEqual(@as(usize, 64), @alignOf(Padded));
    try testing.expect(@sizeOf(Padded) >= 64);

    var p = Padded.init(7);
    try testing.expect(@intFromPtr(&p.value) % Padded.cache_line_bytes == 0);
}

test "padded atomic cmpxchgWeak reports success and failure" {
    // Goal: verify compare-exchange return contract.
    // Method: perform a successful CAS then a failing CAS.
    var p = PaddedAtomic(u32).init(5);
    try testing.expectEqual(@as(?u32, null), p.cmpxchgWeak(5, 9, .acq_rel, .acquire));
    try testing.expectEqual(@as(u32, 9), p.load(.acquire));
    try testing.expectEqual(@as(?u32, 9), p.cmpxchgWeak(5, 11, .acq_rel, .acquire));
    try testing.expectEqual(@as(u32, 9), p.load(.acquire));
}
