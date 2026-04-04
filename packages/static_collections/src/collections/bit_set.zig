//! Fixed-capacity and dynamic bit sets.
//!
//! Key types: `BitSet` (heap-allocated, runtime bit count), `FixedBitSet(N)` (stack-allocated,
//! comptime bit count).
//!
//! Both types share word-level logic via the private `BitOps` namespace, which operates
//! on a raw `[]usize` word slice. Trailing bits in the last word beyond the declared
//! bit count must always be zero; both types enforce this invariant.
//!
//! Thread safety: none. External synchronization required.
const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    InvalidInput,
};

// ---------------------------------------------------------------------------
// Shared word-level operations
// ---------------------------------------------------------------------------

/// Core bit operations on a word slice.
///
/// Used by both `BitSet` and `FixedBitSet`. The caller is responsible for
/// ensuring that `words.len == wordsForBits(bit_count)` and that trailing
/// bits in the last word beyond `bit_count` remain zero after any mutation.
const BitOps = struct {
    /// Set bit `index` in `words`. Index must be < `bit_count`.
    fn set(words: []usize, index: usize, bit_count: usize) void {
        assert(index < bit_count);
        assert(words.len == wordsForBits(bit_count));
        const wi = index / wordBits();
        assert(wi < words.len);
        const mask = @as(usize, 1) << @intCast(index % wordBits());
        words[wi] |= mask;
    }

    /// Clear bit `index` in `words`. Index must be < `bit_count`.
    fn clear(words: []usize, index: usize, bit_count: usize) void {
        assert(index < bit_count);
        assert(words.len == wordsForBits(bit_count));
        const wi = index / wordBits();
        assert(wi < words.len);
        const mask = @as(usize, 1) << @intCast(index % wordBits());
        words[wi] &= ~mask;
    }

    /// Return true when bit `index` is set. Index must be < `bit_count`.
    fn isSet(words: []const usize, index: usize, bit_count: usize) bool {
        assert(index < bit_count);
        assert(words.len == wordsForBits(bit_count));
        const wi = index / wordBits();
        assert(wi < words.len);
        const mask = @as(usize, 1) << @intCast(index % wordBits());
        return (words[wi] & mask) != 0;
    }
};

// ---------------------------------------------------------------------------
// BitSet — heap-allocated, runtime capacity
// ---------------------------------------------------------------------------

pub const BitSet = struct {
    allocator: std.mem.Allocator,
    words: []usize,
    bit_count: usize,

    pub const Config = struct {
        bit_count: usize,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!BitSet {
        if (cfg.bit_count == 0) return error.InvalidInput;
        const sum = std.math.add(usize, cfg.bit_count, wordBits() - 1) catch return error.InvalidInput;
        const word_count = sum / wordBits();
        assert(word_count > 0);
        const words = try allocator.alloc(usize, word_count);
        assert(words.len == word_count);
        @memset(words, 0);
        var self: BitSet = .{
            .allocator = allocator,
            .words = words,
            .bit_count = cfg.bit_count,
        };
        self.assertInvariants();
        return self;
    }

    pub fn deinit(self: *BitSet) void {
        self.assertInvariants();
        self.allocator.free(self.words);
        self.* = undefined;
    }

    pub fn set(self: *BitSet, index: usize) Error!void {
        self.assertInvariants();
        if (index < self.bit_count) {
            BitOps.set(self.words, index, self.bit_count);
            self.assertInvariants();
        } else {
            return error.InvalidInput;
        }
    }

    pub fn clear(self: *BitSet, index: usize) Error!void {
        self.assertInvariants();
        if (index < self.bit_count) {
            BitOps.clear(self.words, index, self.bit_count);
            self.assertInvariants();
        } else {
            return error.InvalidInput;
        }
    }

    pub fn isSet(self: *const BitSet, index: usize) bool {
        self.assertInvariants();
        if (index < self.bit_count) {
            return BitOps.isSet(self.words, index, self.bit_count);
        }
        return false;
    }

    fn assertInvariants(self: *const BitSet) void {
        assert(self.bit_count > 0);
        assert(self.words.len == wordsForBits(self.bit_count));
        assert(self.words.len > 0);
    }
};

// ---------------------------------------------------------------------------
// FixedBitSet — stack-allocated, comptime capacity
// ---------------------------------------------------------------------------

pub fn FixedBitSet(comptime N: usize) type {
    return struct {
        const Self = @This();
        pub const bit_count: usize = N;
        comptime {
            if (N == 0) @compileError("FixedBitSet requires at least one bit.");
        }

        words: [wordsForBits(N)]usize = [_]usize{0} ** wordsForBits(N),

        pub fn set(self: *Self, index: usize) Error!void {
            self.assertInvariants();
            if (index < N) {
                BitOps.set(&self.words, index, N);
                self.assertInvariants();
            } else {
                return error.InvalidInput;
            }
        }

        pub fn clear(self: *Self, index: usize) Error!void {
            self.assertInvariants();
            if (index < N) {
                BitOps.clear(&self.words, index, N);
                self.assertInvariants();
            } else {
                return error.InvalidInput;
            }
        }

        pub fn isSet(self: *const Self, index: usize) bool {
            self.assertInvariants();
            if (index < N) {
                return BitOps.isSet(&self.words, index, N);
            }
            return false;
        }

        /// Verify structural invariants: word count matches the bit capacity, and all
        /// trailing bits in the last word beyond N are zero (no stray set bits).
        fn assertInvariants(self: *const Self) void {
            // Invariant: word array is exactly the right size for N bits.
            assert(self.words.len == wordsForBits(N));
            // Invariant: no bits beyond index N-1 may be set in the last word.
            // Trailing bits in the last word are unused padding; they must remain zero
            // so that any word-level population count or comparison is well-defined.
            const trailing_bits = self.words.len * wordBits() - N;
            if (trailing_bits > 0) {
                const last = self.words[self.words.len - 1];
                const used_mask = (@as(usize, 1) << @intCast(wordBits() - trailing_bits)) - 1;
                assert(last == (last & used_mask));
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn wordBits() usize {
    return @bitSizeOf(usize);
}

fn wordsForBits(bits: usize) usize {
    return (bits + wordBits() - 1) / wordBits();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bit set operations" {
    // Goal: verify the basic set/clear lifecycle on a single bit.
    // Method: set one bit, assert it becomes visible, then clear it.
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = 16 });
    defer b.deinit();
    try b.set(3);
    try std.testing.expect(b.isSet(3));
    try b.clear(3);
    try std.testing.expect(!b.isSet(3));
}

test "bit set rejects zero bit_count" {
    // Goal: reject invalid zero-sized bitsets at construction time.
    // Method: initialize with bit_count=0 and assert InvalidInput.
    try std.testing.expectError(error.InvalidInput, BitSet.init(std.testing.allocator, .{ .bit_count = 0 }));
}

test "bit set out-of-bounds set and clear return InvalidInput" {
    // Goal: confirm out-of-range mutations fail without corrupting state.
    // Method: issue invalid set/clear/isSet calls at index==bit_count.
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer b.deinit();
    try std.testing.expectError(error.InvalidInput, b.set(8));
    try std.testing.expectError(error.InvalidInput, b.clear(8));
    // Out-of-bounds isSet must return false, not panic.
    try std.testing.expect(!b.isSet(8));
}

test "bit set crosses word boundary" {
    // Goal: verify bit operations remain correct across machine-word edges.
    // Method: target the final bit in the second word and round-trip set/clear.
    const bits = @bitSizeOf(usize) + 1;
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = bits });
    defer b.deinit();
    try b.set(bits - 1);
    try std.testing.expect(b.isSet(bits - 1));
    try b.clear(bits - 1);
    try std.testing.expect(!b.isSet(bits - 1));
}

test "FixedBitSet basic set/clear/isSet" {
    // Goal: verify the fixed-size variant tracks bits consistently.
    // Method: mutate both first and last valid bits and check visibility.
    var fb = FixedBitSet(32){};
    try fb.set(0);
    try fb.set(31);
    try std.testing.expect(fb.isSet(0));
    try std.testing.expect(fb.isSet(31));
    try fb.clear(0);
    try std.testing.expect(!fb.isSet(0));
    try std.testing.expect(fb.isSet(31));
}

test "FixedBitSet out-of-bounds returns InvalidInput or false" {
    // Goal: ensure fixed-size bounds checks mirror dynamic BitSet behavior.
    // Method: probe index==N with set and isSet and assert safe failure.
    var fb = FixedBitSet(8){};
    try std.testing.expectError(error.InvalidInput, fb.set(8));
    try std.testing.expect(!fb.isSet(8));
}

test "bit set does not mutate adjacent boundary bits" {
    // Goal: validate negative-space behavior near word boundaries.
    // Method: set only one boundary-adjacent bit and assert neighbors stay clear.
    const edge = @bitSizeOf(usize);
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = edge + 2 });
    defer b.deinit();

    try b.set(edge);
    try std.testing.expect(!b.isSet(edge - 1));
    try std.testing.expect(b.isSet(edge));
    try std.testing.expect(!b.isSet(edge + 1));
}
