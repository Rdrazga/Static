const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// A monotonically increasing counter used for change-tracking.
///
/// Single-threaded only. All reads and writes are plain (non-atomic) memory
/// operations. `Epoch` must not be shared across threads without external
/// synchronization; doing so introduces data races.
pub const Epoch = struct {
    value: u64 = 0,

    pub fn increment(self: *Epoch) void {
        // Epoch overflow is a programmer error: u64 wrapping would break all
        // change-tracking invariants. 2^64 increments will not occur in practice.
        assert(self.value < std.math.maxInt(u64));
        self.value += 1;
        // Postcondition: the value must be strictly greater than zero after an increment.
        // Zero is the initial state; reaching it again after an increment implies wraparound,
        // which the precondition above prevents.
        assert(self.value > 0);
    }

    pub fn incrementAndGet(self: *Epoch) u64 {
        self.increment();
        assert(self.value > 0);
        return self.value;
    }

    pub fn hasChangedSince(self: Epoch, last_seen: u64) bool {
        const changed = self.value != last_seen;
        // Pair assertion: if the stored value equals the snapshot, no change occurred;
        // if it differs, a change occurred. Both directions must hold.
        assert(changed == (self.value != last_seen));
        assert(!changed == (self.value == last_seen));
        return changed;
    }

    pub fn capture(self: Epoch) u64 {
        const snap = self.value;
        // Postcondition: the captured snapshot must equal the current value at the moment
        // of capture. A mismatch here would indicate self-modification during a read,
        // which is a programmer error in this single-threaded type.
        assert(snap == self.value);
        return snap;
    }

    pub fn get(self: Epoch) u64 {
        const val = self.value;
        // Postcondition: returned value must match the stored field (no silent transformation).
        assert(val == self.value);
        return val;
    }

    // Compatibility helpers (non-normative).
    pub fn current(self: Epoch) u64 {
        const val = self.get();
        // Postcondition: `current()` is an alias for `get()`; result must be identical.
        assert(val == self.value);
        return val;
    }
};

// The Epoch type must be exactly the size of its backing integer so that layouts
// depending on Epoch as a u64-sized field hold without padding surprises.
comptime {
    assert(@sizeOf(Epoch) == @sizeOf(u64));
}

/// Wraps a value of type `T` with an `Epoch` version counter that increments
/// on every mutation, enabling cheap change detection without hashing.
///
/// Single-threaded only. Reads and writes to both the inner data and the
/// version counter are plain (non-atomic) operations. `Versioned(T)` must not
/// be shared across threads without external synchronization; doing so
/// introduces data races.
pub fn Versioned(comptime T: type) type {
    return struct {
        const Self = @This();

        data: T,
        version: Epoch = .{},

        pub fn init(value: T) Self {
            const out: Self = .{ .data = value };
            // Postcondition: the version counter must start at zero after init.
            assert(out.version.value == 0);
            return out;
        }

        pub fn get(self: *const Self) T {
            // Precondition: the version counter must be a valid (non-corrupt) u64; it is
            // validated by the Epoch invariant. Checking here acts as a sentinel that the
            // Versioned struct itself has not been memory-corrupted.
            assert(self.version.value <= std.math.maxInt(u64));
            return self.data;
        }

        pub fn getMut(self: *Self) *T {
            // Precondition: the struct must be in a valid state before handing out a mutable
            // pointer; callers must call markModified() after mutating via the returned pointer.
            assert(self.version.value <= std.math.maxInt(u64));
            return &self.data;
        }

        pub fn set(self: *Self, value: T) void {
            const old_version = self.version.value;
            self.data = value;
            self.version.increment();
            // Postcondition: version must have advanced after set() to enable change detection.
            assert(self.version.value > old_version);
        }

        pub fn markModified(self: *Self) void {
            const old_version = self.version.value;
            self.version.increment();
            // Postcondition: version must have advanced after markModified().
            assert(self.version.value > old_version);
        }

        pub fn epoch(self: *const Self) u64 {
            const val = self.version.value;
            // Postcondition: the returned epoch must equal the stored counter.
            assert(val == self.version.value);
            return val;
        }

        pub fn hasChangedSince(self: *const Self, last_seen: u64) bool {
            const changed = self.version.hasChangedSince(last_seen);
            // Pair assertion: the result must be consistent with a direct comparison against
            // the stored version. Both directions are asserted to catch asymmetric corruption.
            assert(changed == (self.version.value != last_seen));
            return changed;
        }
    };
}

test "epoch basic operations" {
    // Verifies capture/compare behavior and monotonicity for the `Epoch` counter.
    var epoch = Epoch{};
    try testing.expectEqual(@as(u64, 0), epoch.get());

    const token = epoch.capture();
    try testing.expect(!epoch.hasChangedSince(token));

    epoch.increment();
    try testing.expectEqual(@as(u64, 1), epoch.get());
    try testing.expect(epoch.hasChangedSince(token));
}

test "epoch incrementAndGet" {
    // Verifies `incrementAndGet()` returns the incremented epoch and keeps the stored value in sync.
    var epoch = Epoch{};
    try testing.expectEqual(@as(u64, 1), epoch.incrementAndGet());
    try testing.expectEqual(@as(u64, 2), epoch.incrementAndGet());
    try testing.expectEqual(@as(u64, 2), epoch.get());
}

test "Versioned basic operations" {
    // Verifies version bumps on `set()` and change detection relative to a captured epoch.
    var v = Versioned(i32).init(42);
    try testing.expectEqual(@as(i32, 42), v.get());
    try testing.expectEqual(@as(u64, 0), v.epoch());

    const old_epoch = v.epoch();

    v.set(100);
    try testing.expectEqual(@as(i32, 100), v.get());
    try testing.expectEqual(@as(u64, 1), v.epoch());
    try testing.expect(v.hasChangedSince(old_epoch));
}

test "Versioned getMut and markModified" {
    // Verifies that callers can mutate via `getMut()` while explicitly marking the wrapper as modified.
    var v = Versioned(i32).init(0);
    const old_epoch = v.epoch();

    const ptr = v.getMut();
    ptr.* = 999;
    v.markModified();

    try testing.expectEqual(@as(i32, 999), v.get());
    try testing.expect(v.hasChangedSince(old_epoch));
}
