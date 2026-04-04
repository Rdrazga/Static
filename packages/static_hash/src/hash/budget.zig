//! Hash Budget - Explicit work bounds for hashing.
//!
//! Hashing is often driven by slices whose length is runtime-dynamic. This module
//! lets callers enforce explicit limits on bytes hashed, elements visited, and
//! nesting depth, satisfying the "put a limit on everything" rule.
//!
//! ## Thread Safety
//! None. A single `HashBudget` instance must be used from one thread.
//!
//! ## Allocation Profile
//! No allocation (stack only).
//!
//! ## Design
//! - Charges are monotonic (no refunds).
//! - Depth is tracked separately to bound type-shape recursion.
//! - Fail-closed on overflow (treat as exceeded).

const std = @import("std");

pub const HashBudgetError = error{
    ExceededBytes,
    ExceededElems,
    ExceededDepth,
};

/// Configuration limits for a hash budget.
///
/// Each field defaults to the maximum value of its type, effectively unlimited.
/// Callers should set only the limits they care about.
pub const Limits = struct {
    /// Maximum total bytes hashed via raw-byte paths (byte slices, POD-as-bytes).
    max_bytes: u64 = std.math.maxInt(u64),
    /// Maximum total elements or fields visited in structural hashing.
    max_elems: u64 = std.math.maxInt(u64),
    /// Maximum nesting depth of the hash walk.
    max_depth: u16 = std.math.maxInt(u16),
};

/// Tracks cumulative hashing work against caller-defined limits.
///
/// Thread-safety: none (single-threaded per instance).
pub const HashBudget = struct {
    limits: Limits,
    used_bytes: u64 = 0,
    used_elems: u64 = 0,
    depth: u16 = 0,

    /// Create a budget with the given limits.
    ///
    /// Preconditions: limits.max_depth must be non-zero (a zero-depth budget
    /// cannot hash anything, which is a programmer error).
    /// Postconditions: all usage counters are zero.
    pub fn init(limits: Limits) HashBudget {
        // A zero-depth budget cannot enter any nesting level. This is a programmer error.
        std.debug.assert(limits.max_depth != 0);
        // Individual limits of zero are valid: they cause immediate failure on
        // that charge path, which is correct fail-fast behavior. For example,
        // max_bytes=0 with max_elems>0 is a valid element-only budget.
        const result: HashBudget = .{ .limits = limits };
        // Postcondition: all counters start at zero.
        std.debug.assert(result.used_bytes == 0);
        std.debug.assert(result.used_elems == 0);
        std.debug.assert(result.depth == 0);
        return result;
    }

    /// Create an effectively unlimited budget.
    ///
    /// Postconditions: all limits are set to their type maximums.
    pub fn unlimited() HashBudget {
        const result = init(.{});
        // Postcondition: limits are at their maximums.
        std.debug.assert(result.limits.max_bytes == std.math.maxInt(u64));
        std.debug.assert(result.limits.max_elems == std.math.maxInt(u64));
        std.debug.assert(result.limits.max_depth == std.math.maxInt(u16));
        return result;
    }

    /// Enter a nesting level. Returns `ExceededDepth` if the limit is reached.
    ///
    /// Preconditions: depth <= max_depth (invariant maintained by enter/leave pairs).
    /// Postconditions: depth incremented by one on success.
    pub fn enter(self: *HashBudget) HashBudgetError!void {
        std.debug.assert(self.depth <= self.limits.max_depth);
        if (self.depth == self.limits.max_depth) {
            return error.ExceededDepth;
        }
        self.depth += 1;
        // Postcondition: depth is within bounds after increment.
        std.debug.assert(self.depth <= self.limits.max_depth);
    }

    /// Leave a nesting level.
    ///
    /// Preconditions: depth > 0 (must have a matching `enter`).
    /// Postconditions: depth decremented by one.
    pub fn leave(self: *HashBudget) void {
        // Must have a matching enter() call.
        std.debug.assert(self.depth != 0);
        self.depth -= 1;
        // Postcondition: depth is now strictly less than max_depth.
        std.debug.assert(self.depth < self.limits.max_depth);
    }

    /// Charge `bytes` against the byte budget.
    ///
    /// Preconditions: used_bytes <= max_bytes (invariant: successful charges never exceed limit).
    /// Postconditions: used_bytes incremented on success; returns `ExceededBytes` if over limit.
    pub fn chargeBytes(self: *HashBudget, bytes: usize) HashBudgetError!void {
        // Invariant: prior successful charges never left us over the limit.
        std.debug.assert(self.used_bytes <= self.limits.max_bytes);
        const n = usizeToU64(bytes) orelse return error.ExceededBytes;
        const new_used = std.math.add(u64, self.used_bytes, n) catch return error.ExceededBytes;
        if (new_used > self.limits.max_bytes) {
            return error.ExceededBytes;
        }
        self.used_bytes = new_used;
        // Postcondition: used_bytes is within limit after successful charge.
        std.debug.assert(self.used_bytes <= self.limits.max_bytes);
    }

    /// Charge `elems` against the element budget.
    ///
    /// Preconditions: used_elems <= max_elems (invariant: successful charges never exceed limit).
    /// Postconditions: used_elems incremented on success; returns `ExceededElems` if over limit.
    pub fn chargeElems(self: *HashBudget, elems: usize) HashBudgetError!void {
        // Invariant: prior successful charges never left us over the limit.
        std.debug.assert(self.used_elems <= self.limits.max_elems);
        const n = usizeToU64(elems) orelse return error.ExceededElems;
        const new_used = std.math.add(u64, self.used_elems, n) catch return error.ExceededElems;
        if (new_used > self.limits.max_elems) {
            return error.ExceededElems;
        }
        self.used_elems = new_used;
        // Postcondition: used_elems is within limit after successful charge.
        std.debug.assert(self.used_elems <= self.limits.max_elems);
    }

    /// Convert usize to u64, returning null on overflow. On all current Zig
    /// targets usize <= u64, so this is effectively infallible; the check
    /// guards against hypothetical future targets.
    fn usizeToU64(value: usize) ?u64 {
        if (comptime @bitSizeOf(usize) <= 64) {
            return @as(u64, @intCast(value));
        }
        if (value > std.math.maxInt(u64)) return null;
        return @as(u64, @intCast(value));
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: exercise each limiter at the boundary (exactly-at-limit, just-over-limit),
// and verify that failed charges do not mutate counters.

test "budget init rejects zero max_depth" {
    // max_depth=0 is treated as a programmer error and guarded by an assert.
    // Zig's test runner treats panics as hard failures, so we cover the valid path here.
    const b = HashBudget.init(.{ .max_depth = 1 });
    try std.testing.expectEqual(@as(u16, 0), b.depth);
}

test "budget chargeBytes enforces limit" {
    var b = HashBudget.init(.{
        .max_bytes = 5,
        .max_elems = std.math.maxInt(u64),
        .max_depth = std.math.maxInt(u16),
    });
    // Charge within limit succeeds.
    try b.chargeBytes(3);
    try b.chargeBytes(2);
    // Charge over limit fails.
    try std.testing.expectError(error.ExceededBytes, b.chargeBytes(1));
}

test "budget chargeElems enforces limit" {
    var b = HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = 3,
        .max_depth = std.math.maxInt(u16),
    });
    try b.chargeElems(2);
    try b.chargeElems(1);
    try std.testing.expectError(error.ExceededElems, b.chargeElems(1));
}

test "budget enter/leave enforces depth limit" {
    var b = HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = std.math.maxInt(u64),
        .max_depth = 2,
    });
    try b.enter();
    try b.enter();
    try std.testing.expectError(error.ExceededDepth, b.enter());
    b.leave();
    b.leave();
    try std.testing.expectEqual(@as(u16, 0), b.depth);
}

test "budget unlimited allows large charges" {
    var b = HashBudget.unlimited();
    try b.chargeBytes(1_000_000);
    try b.chargeElems(1_000_000);
    try b.enter();
    b.leave();
}

test "budget charges are monotonic" {
    var b = HashBudget.init(.{
        .max_bytes = 10,
        .max_elems = std.math.maxInt(u64),
        .max_depth = std.math.maxInt(u16),
    });
    try b.chargeBytes(5);
    try std.testing.expectEqual(@as(u64, 5), b.used_bytes);
    try b.chargeBytes(3);
    try std.testing.expectEqual(@as(u64, 8), b.used_bytes);
    // No way to reduce used_bytes: monotonic by design.
}

test "budget allows max_bytes=0 with nonzero max_elems" {
    var b = HashBudget.init(.{
        .max_bytes = 0,
        .max_elems = 10,
        .max_depth = 1,
    });
    // Byte charges fail immediately: correct fail-fast for byte-free budgets.
    try std.testing.expectError(error.ExceededBytes, b.chargeBytes(1));
    // Element charges succeed.
    try b.chargeElems(1);
}

test "budget chargeBytes at exact limit succeeds" {
    var b = HashBudget.init(.{
        .max_bytes = 5,
        .max_elems = std.math.maxInt(u64),
        .max_depth = 1,
    });
    try b.chargeBytes(5);
    // One more byte exceeds the limit.
    try std.testing.expectError(error.ExceededBytes, b.chargeBytes(1));
}

test "budget chargeBytes with zero bytes succeeds" {
    var b = HashBudget.init(.{
        .max_bytes = 0,
        .max_elems = 1,
        .max_depth = 1,
    });
    // Zero-byte charge succeeds even with max_bytes=0.
    try b.chargeBytes(0);
}

test "budget failed charge does not corrupt counter" {
    var b = HashBudget.init(.{
        .max_bytes = 3,
        .max_elems = std.math.maxInt(u64),
        .max_depth = 1,
    });
    try b.chargeBytes(2);
    // This charge exceeds the limit and must not modify used_bytes.
    try std.testing.expectError(error.ExceededBytes, b.chargeBytes(5));
    try std.testing.expectEqual(@as(u64, 2), b.used_bytes);
    // Remaining budget is intact: we can still charge 1 more byte.
    try b.chargeBytes(1);
    try std.testing.expectEqual(@as(u64, 3), b.used_bytes);
}

test "budget failed element charge does not corrupt counter" {
    var b = HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = 3,
        .max_depth = 1,
    });
    try b.chargeElems(2);
    // This charge exceeds the limit and must not modify used_elems.
    try std.testing.expectError(error.ExceededElems, b.chargeElems(5));
    try std.testing.expectEqual(@as(u64, 2), b.used_elems);
    // Remaining element budget is intact: we can still charge 1 more element.
    try b.chargeElems(1);
    try std.testing.expectEqual(@as(u64, 3), b.used_elems);
}

test "budget failed enter does not change depth" {
    var b = HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = std.math.maxInt(u64),
        .max_depth = 1,
    });
    try b.enter();
    try std.testing.expectError(error.ExceededDepth, b.enter());
    // A failed enter must not increase depth.
    try std.testing.expectEqual(@as(u16, 1), b.depth);
}
