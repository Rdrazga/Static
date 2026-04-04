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
const memory = @import("static_memory");
const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    InvalidInput,
    NoSpaceLeft,
    InvalidConfig,
    Overflow,
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

    /// Population count: total number of set bits.
    fn count(words: []const usize) usize {
        var total: usize = 0;
        for (words) |w| {
            total += @popCount(w);
        }
        return total;
    }

    /// `dst |= other`
    fn setUnion(dst: []usize, other: []const usize) void {
        assert(dst.len == other.len);
        for (dst, other) |*d, o| d.* |= o;
    }

    /// `dst &= other`
    fn setIntersection(dst: []usize, other: []const usize) void {
        assert(dst.len == other.len);
        for (dst, other) |*d, o| d.* &= o;
    }

    /// `dst &= ~other`
    fn setDifference(dst: []usize, other: []const usize) void {
        assert(dst.len == other.len);
        for (dst, other) |*d, o| d.* &= ~o;
    }

    /// `dst ^= other`
    fn symmetricDifference(dst: []usize, other: []const usize) void {
        assert(dst.len == other.len);
        for (dst, other) |*d, o| d.* ^= o;
    }

    /// `words = ~words`, then zero trailing bits beyond bit_count.
    fn doComplement(words: []usize, bit_count: usize) void {
        assert(words.len == wordsForBits(bit_count));
        for (words) |*w| w.* = ~w.*;
        zeroTrailingBits(words, bit_count);
    }

    fn eql(a: []const usize, b: []const usize) bool {
        assert(a.len == b.len);
        for (a, b) |wa, wb| {
            if (wa != wb) return false;
        }
        return true;
    }

    /// Returns true if every bit set in `a` is also set in `b`.
    fn subsetOf(a: []const usize, b: []const usize) bool {
        assert(a.len == b.len);
        for (a, b) |wa, wb| {
            if ((wa & ~wb) != 0) return false;
        }
        return true;
    }

    /// Zero any bits in the last word that are beyond bit_count.
    fn zeroTrailingBits(words: []usize, bit_count: usize) void {
        assert(words.len == wordsForBits(bit_count));
        const trailing = words.len * wordBits() - bit_count;
        if (trailing > 0) {
            const used_bits = wordBits() - trailing;
            const used_mask = (@as(usize, 1) << @intCast(used_bits)) - 1;
            words[words.len - 1] &= used_mask;
        }
    }

    /// Verify that trailing padding bits in the final word stay zero.
    fn assertCanonical(words: []const usize, bit_count: usize) void {
        assert(words.len == wordsForBits(bit_count));
        const trailing = words.len * wordBits() - bit_count;
        if (trailing > 0) {
            const last = words[words.len - 1];
            const used_bits = wordBits() - trailing;
            const used_mask = (@as(usize, 1) << @intCast(used_bits)) - 1;
            assert(last == (last & used_mask));
        }
    }
};

// ---------------------------------------------------------------------------
// BitSet — heap-allocated, runtime capacity
// ---------------------------------------------------------------------------

pub const BitSet = struct {
    allocator: std.mem.Allocator,
    budget: ?*memory.budget.Budget,
    words: []usize,
    bit_count: usize,

    pub const Config = struct {
        bit_count: usize,
        budget: ?*memory.budget.Budget = null,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!BitSet {
        if (cfg.bit_count == 0) return error.InvalidInput;
        const sum = std.math.add(usize, cfg.bit_count, wordBits() - 1) catch return error.InvalidInput;
        const word_count = sum / wordBits();
        assert(word_count > 0);

        const alloc_bytes = std.math.mul(usize, word_count, @sizeOf(usize)) catch return error.Overflow;
        if (cfg.budget) |budget| {
            budget.tryReserve(alloc_bytes) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
        }

        const words = allocator.alloc(usize, word_count) catch {
            if (cfg.budget) |budget| budget.release(alloc_bytes);
            return error.OutOfMemory;
        };
        assert(words.len == word_count);
        @memset(words, 0);
        var self: BitSet = .{
            .allocator = allocator,
            .budget = cfg.budget,
            .words = words,
            .bit_count = cfg.bit_count,
        };
        self.assertInvariants();
        return self;
    }

    pub fn deinit(self: *BitSet) void {
        self.assertInvariants();
        if (self.budget) |budget| {
            const alloc_bytes = self.words.len * @sizeOf(usize);
            budget.release(alloc_bytes);
        }
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

    pub fn isSet(self: *const BitSet, index: usize) Error!bool {
        self.assertInvariants();
        if (index < self.bit_count) {
            return BitOps.isSet(self.words, index, self.bit_count);
        }
        return error.InvalidInput;
    }

    /// Creates an independent copy with its own backing memory.
    pub fn clone(self: *const BitSet) Error!BitSet {
        self.assertInvariants();
        const alloc_bytes = std.math.mul(usize, self.words.len, @sizeOf(usize)) catch return error.Overflow;
        if (self.budget) |budget| {
            budget.tryReserve(alloc_bytes) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.InvalidConfig => return error.InvalidConfig,
                error.Overflow => return error.Overflow,
            };
        }
        const new_words = self.allocator.alloc(usize, self.words.len) catch {
            if (self.budget) |budget| budget.release(alloc_bytes);
            return error.OutOfMemory;
        };
        @memcpy(new_words, self.words);
        var result: BitSet = .{
            .allocator = self.allocator,
            .budget = self.budget,
            .words = new_words,
            .bit_count = self.bit_count,
        };
        result.assertInvariants();
        return result;
    }

    pub fn count(self: *const BitSet) usize {
        self.assertInvariants();
        return BitOps.count(self.words);
    }

    pub fn setUnion(self: *BitSet, other: *const BitSet) Error!void {
        self.assertInvariants();
        if (self.bit_count != other.bit_count) return error.InvalidInput;
        BitOps.setUnion(self.words, other.words);
        self.assertInvariants();
    }

    pub fn setIntersection(self: *BitSet, other: *const BitSet) Error!void {
        self.assertInvariants();
        if (self.bit_count != other.bit_count) return error.InvalidInput;
        BitOps.setIntersection(self.words, other.words);
        self.assertInvariants();
    }

    pub fn setDifference(self: *BitSet, other: *const BitSet) Error!void {
        self.assertInvariants();
        if (self.bit_count != other.bit_count) return error.InvalidInput;
        BitOps.setDifference(self.words, other.words);
        self.assertInvariants();
    }

    pub fn symmetricDifference(self: *BitSet, other: *const BitSet) Error!void {
        self.assertInvariants();
        if (self.bit_count != other.bit_count) return error.InvalidInput;
        BitOps.symmetricDifference(self.words, other.words);
        self.assertInvariants();
    }

    pub fn complement(self: *BitSet) void {
        self.assertInvariants();
        BitOps.doComplement(self.words, self.bit_count);
        self.assertInvariants();
    }

    pub fn eql(self: *const BitSet, other: *const BitSet) Error!bool {
        self.assertInvariants();
        if (self.bit_count != other.bit_count) return error.InvalidInput;
        return BitOps.eql(self.words, other.words);
    }

    pub fn subsetOf(self: *const BitSet, other: *const BitSet) Error!bool {
        self.assertInvariants();
        if (self.bit_count != other.bit_count) return error.InvalidInput;
        return BitOps.subsetOf(self.words, other.words);
    }

    fn assertInvariants(self: *const BitSet) void {
        assert(self.bit_count > 0);
        assert(self.words.len == wordsForBits(self.bit_count));
        assert(self.words.len > 0);
        BitOps.assertCanonical(self.words, self.bit_count);
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

        pub fn isSet(self: *const Self, index: usize) Error!bool {
            self.assertInvariants();
            if (index < N) {
                return BitOps.isSet(&self.words, index, N);
            }
            return error.InvalidInput;
        }

        pub fn count(self: *const Self) usize {
            self.assertInvariants();
            return BitOps.count(&self.words);
        }

        pub fn setUnion(self: *Self, other: *const Self) void {
            self.assertInvariants();
            BitOps.setUnion(&self.words, &other.words);
            self.assertInvariants();
        }

        pub fn setIntersection(self: *Self, other: *const Self) void {
            self.assertInvariants();
            BitOps.setIntersection(&self.words, &other.words);
            self.assertInvariants();
        }

        pub fn setDifference(self: *Self, other: *const Self) void {
            self.assertInvariants();
            BitOps.setDifference(&self.words, &other.words);
            self.assertInvariants();
        }

        pub fn symmetricDifference(self: *Self, other: *const Self) void {
            self.assertInvariants();
            BitOps.symmetricDifference(&self.words, &other.words);
            self.assertInvariants();
        }

        pub fn complement(self: *Self) void {
            self.assertInvariants();
            BitOps.doComplement(&self.words, N);
            self.assertInvariants();
        }

        pub fn eql(self: *const Self, other: *const Self) bool {
            self.assertInvariants();
            return BitOps.eql(&self.words, &other.words);
        }

        pub fn subsetOf(self: *const Self, other: *const Self) bool {
            self.assertInvariants();
            return BitOps.subsetOf(&self.words, &other.words);
        }

        /// Verify structural invariants: word count matches the bit capacity, and all
        /// trailing bits in the last word beyond N are zero (no stray set bits).
        fn assertInvariants(self: *const Self) void {
            // Invariant: word array is exactly the right size for N bits.
            assert(self.words.len == wordsForBits(N));
            BitOps.assertCanonical(&self.words, N);
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
    try std.testing.expect(try b.isSet(3));
    try b.clear(3);
    try std.testing.expect(!try b.isSet(3));
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
    // Out-of-bounds isSet must return InvalidInput, matching set/clear.
    try std.testing.expectError(error.InvalidInput, b.isSet(8));
}

test "bit set crosses word boundary" {
    // Goal: verify bit operations remain correct across machine-word edges.
    // Method: target the final bit in the second word and round-trip set/clear.
    const bits = @bitSizeOf(usize) + 1;
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = bits });
    defer b.deinit();
    try b.set(bits - 1);
    try std.testing.expect(try b.isSet(bits - 1));
    try b.clear(bits - 1);
    try std.testing.expect(!try b.isSet(bits - 1));
}

test "FixedBitSet basic set/clear/isSet" {
    // Goal: verify the fixed-size variant tracks bits consistently.
    // Method: mutate both first and last valid bits and check visibility.
    var fb = FixedBitSet(32){};
    try fb.set(0);
    try fb.set(31);
    try std.testing.expect(try fb.isSet(0));
    try std.testing.expect(try fb.isSet(31));
    try fb.clear(0);
    try std.testing.expect(!try fb.isSet(0));
    try std.testing.expect(try fb.isSet(31));
}

test "FixedBitSet out-of-bounds returns InvalidInput" {
    // Goal: ensure fixed-size bounds checks mirror dynamic BitSet behavior.
    // Method: probe index==N with set and isSet and assert safe failure.
    var fb = FixedBitSet(8){};
    try std.testing.expectError(error.InvalidInput, fb.set(8));
    try std.testing.expectError(error.InvalidInput, fb.isSet(8));
}

test "bit set does not mutate adjacent boundary bits" {
    // Goal: validate negative-space behavior near word boundaries.
    // Method: set only one boundary-adjacent bit and assert neighbors stay clear.
    const edge = @bitSizeOf(usize);
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = edge + 2 });
    defer b.deinit();

    try b.set(edge);
    try std.testing.expect(!try b.isSet(edge - 1));
    try std.testing.expect(try b.isSet(edge));
    try std.testing.expect(!try b.isSet(edge + 1));
}

test "bit set count returns population count" {
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = 16 });
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 0), b.count());
    try b.set(0);
    try b.set(5);
    try b.set(15);
    try std.testing.expectEqual(@as(usize, 3), b.count());
}

test "bit set union intersection difference" {
    var a = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer a.deinit();
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer b.deinit();

    try a.set(0);
    try a.set(1);
    try b.set(1);
    try b.set(2);

    // Union: {0,1} | {1,2} = {0,1,2}
    var u = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer u.deinit();
    try u.set(0);
    try u.set(1);
    try u.setUnion(&b);
    try std.testing.expectEqual(@as(usize, 3), u.count());

    // Intersection: {0,1} & {1,2} = {1}
    var inter = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer inter.deinit();
    try inter.set(0);
    try inter.set(1);
    try inter.setIntersection(&b);
    try std.testing.expectEqual(@as(usize, 1), inter.count());
    try std.testing.expect(try inter.isSet(1));

    // Difference: {0,1} \ {1,2} = {0}
    var diff = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer diff.deinit();
    try diff.set(0);
    try diff.set(1);
    try diff.setDifference(&b);
    try std.testing.expectEqual(@as(usize, 1), diff.count());
    try std.testing.expect(try diff.isSet(0));
}

test "bit set complement preserves trailing-bit invariant" {
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = 5 });
    defer b.deinit();
    try b.set(0);
    b.complement();
    // Bits 1-4 should be set, bit 0 should be clear.
    try std.testing.expect(!try b.isSet(0));
    try std.testing.expect(try b.isSet(1));
    try std.testing.expect(try b.isSet(4));
    try std.testing.expectEqual(@as(usize, 4), b.count());
}

test "bit set eql and subsetOf" {
    var a = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer a.deinit();
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer b.deinit();

    try a.set(1);
    try b.set(1);
    try std.testing.expect(try a.eql(&b));
    try std.testing.expect(try a.subsetOf(&b));

    try b.set(3);
    try std.testing.expect(!try a.eql(&b));
    try std.testing.expect(try a.subsetOf(&b));
    try std.testing.expect(!try b.subsetOf(&a));
}

test "bit set mismatched bit_count returns InvalidInput" {
    var a = try BitSet.init(std.testing.allocator, .{ .bit_count = 8 });
    defer a.deinit();
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = 16 });
    defer b.deinit();
    try std.testing.expectError(error.InvalidInput, a.setUnion(&b));
    try std.testing.expectError(error.InvalidInput, a.eql(&b));
}

test "FixedBitSet set algebra operations" {
    var a = FixedBitSet(8){};
    var b = FixedBitSet(8){};
    try a.set(0);
    try a.set(2);
    try b.set(2);
    try b.set(4);

    a.setUnion(&b);
    try std.testing.expectEqual(@as(usize, 3), a.count());

    a.setIntersection(&b);
    try std.testing.expectEqual(@as(usize, 2), a.count());

    a.complement();
    try std.testing.expect(!try a.isSet(2));
    try std.testing.expect(try a.isSet(1));
}

test "bit set complement keeps dynamic bitset canonical at word tail" {
    const bits = wordBits() + 3;
    var b = try BitSet.init(std.testing.allocator, .{ .bit_count = bits });
    defer b.deinit();

    b.complement();
    const trailing = b.words.len * wordBits() - bits;
    const used_mask = (@as(usize, 1) << @intCast(wordBits() - trailing)) - 1;
    try std.testing.expectEqual(b.words[b.words.len - 1], b.words[b.words.len - 1] & used_mask);
}
