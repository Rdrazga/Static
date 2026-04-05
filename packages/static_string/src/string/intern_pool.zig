//! Deterministic bounded string interning over caller-provided storage.
//!
//! Key types: `InternPool`, `Entry`, `Symbol`, `InternError`, `LookupError`.
//! Usage pattern: allocate `[]Entry` and `[]u8` slices, call `InternPool.init(entries, bytes)`,
//! then `intern(value)` to obtain a stable `Symbol` (entry index); `resolve(symbol)` returns
//! the interned string. Duplicate strings return the same symbol without copying bytes again.
//! The pool never allocates; capacity is bounded by the provided slices.
//! Thread safety: not thread-safe — a single instance must be owned by one thread.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_hash = @import("static_hash");

pub const Symbol = u32;

pub const Entry = struct {
    offset: u32,
    len: u32,
    hash: u64,
};

pub const InternError = error{
    InvalidConfig,
    NoSpaceLeft,
};

pub const LookupError = error{
    NotFound,
};

pub const InternPool = struct {
    entries: []Entry,
    bytes: []u8,
    len_used: usize,
    bytes_used: usize,

    pub fn init(entries: []Entry, bytes: []u8) InternError!InternPool {
        const max_entries: usize = std.math.maxInt(Symbol);
        const max_bytes: usize = std.math.maxInt(u32);

        if (entries.len == 0) return error.InvalidConfig;
        if (bytes.len == 0) return error.InvalidConfig;
        if (entries.len > max_entries) return error.InvalidConfig;
        if (bytes.len > max_bytes) return error.InvalidConfig;
        return .{
            .entries = entries,
            .bytes = bytes,
            .len_used = 0,
            .bytes_used = 0,
        };
    }

    pub fn len(self: *const InternPool) usize {
        assert(self.len_used <= self.entries.len);
        return self.len_used;
    }

    pub fn capacity(self: *const InternPool) usize {
        const result = self.entries.len;
        // Postcondition: capacity must always be at least as large as the number
        // of currently interned entries. A capacity below len is a corrupt state.
        assert(result >= self.len_used);
        return result;
    }

    pub fn bytesUsed(self: *const InternPool) usize {
        assert(self.bytes_used <= self.bytes.len);
        return self.bytes_used;
    }

    pub fn bytesCapacity(self: *const InternPool) usize {
        const result = self.bytes.len;
        // Postcondition: byte capacity must always be at least the bytes consumed.
        assert(result >= self.bytes_used);
        return result;
    }

    pub fn intern(self: *InternPool, value: []const u8) InternError!Symbol {
        const max_symbol: usize = std.math.maxInt(Symbol);
        const max_offset: usize = std.math.maxInt(u32);

        assert(self.len_used <= self.entries.len);
        assert(self.bytes_used <= self.bytes.len);

        const hash = static_hash.fingerprint64(value);

        var index: usize = 0;
        while (index < self.len_used) : (index += 1) {
            const entry = self.entries[index];
            if (entry.hash != hash) continue;
            const existing = self.sliceFromEntry(entry);
            if (std.mem.eql(u8, existing, value)) {
                return @intCast(index);
            }
        }

        if (self.len_used > max_symbol) return error.NoSpaceLeft;
        if (self.len_used >= self.entries.len) return error.NoSpaceLeft;
        if (self.bytes_used > max_offset) return error.NoSpaceLeft;
        if (value.len > max_offset) return error.NoSpaceLeft;

        if (self.bytes.len - self.bytes_used < value.len) return error.NoSpaceLeft;

        const start = self.bytes_used;
        const end = start + value.len;
        assert(end <= self.bytes.len);
        @memcpy(self.bytes[start..end], value);
        self.bytes_used = end;

        self.entries[self.len_used] = .{
            .offset = @intCast(start),
            .len = @intCast(value.len),
            .hash = hash,
        };

        const symbol_index = self.len_used;
        self.len_used += 1;
        assert(self.len_used <= self.entries.len);
        return @intCast(symbol_index);
    }

    pub fn resolve(self: *const InternPool, symbol: Symbol) LookupError![]const u8 {
        assert(self.len_used <= self.entries.len);
        assert(self.bytes_used <= self.bytes.len);

        const index: usize = symbol;
        if (index >= self.len_used) return error.NotFound;
        return self.sliceFromEntry(self.entries[index]);
    }

    pub fn contains(self: *const InternPool, value: []const u8) bool {
        assert(self.len_used <= self.entries.len);
        assert(self.bytes_used <= self.bytes.len);

        const hash = static_hash.fingerprint64(value);

        var index: usize = 0;
        while (index < self.len_used) : (index += 1) {
            const entry = self.entries[index];
            if (entry.hash != hash) continue;
            if (std.mem.eql(u8, self.sliceFromEntry(entry), value)) return true;
        }
        return false;
    }

    fn sliceFromEntry(self: *const InternPool, entry: Entry) []const u8 {
        const start: usize = entry.offset;
        const end = start + entry.len;
        assert(start <= self.bytes_used);
        assert(end <= self.bytes_used);
        return self.bytes[start..end];
    }
};

test "InternPool init rejects zero capacities" {
    var no_entries: [0]Entry = .{};
    var bytes: [8]u8 = undefined;
    try testing.expectError(error.InvalidConfig, InternPool.init(no_entries[0..], bytes[0..]));

    var entries: [1]Entry = undefined;
    var no_bytes: [0]u8 = .{};
    try testing.expectError(error.InvalidConfig, InternPool.init(entries[0..], no_bytes[0..]));
}

test "InternPool duplicate strings return same symbol" {
    var entries: [4]Entry = undefined;
    var bytes: [32]u8 = undefined;
    var pool = try InternPool.init(entries[0..], bytes[0..]);

    const first = try pool.intern("hello");
    const second = try pool.intern("hello");
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), pool.len());
}

test "InternPool resolves symbols and reports NotFound" {
    var entries: [2]Entry = undefined;
    var bytes: [16]u8 = undefined;
    var pool = try InternPool.init(entries[0..], bytes[0..]);

    const symbol = try pool.intern("abc");
    const resolved = try pool.resolve(symbol);
    try testing.expectEqualStrings("abc", resolved);

    try testing.expectError(error.NotFound, pool.resolve(99));
}

test "InternPool returns NoSpaceLeft for entry limit" {
    var entries: [1]Entry = undefined;
    var bytes: [16]u8 = undefined;
    var pool = try InternPool.init(entries[0..], bytes[0..]);

    _ = try pool.intern("a");
    try testing.expectError(error.NoSpaceLeft, pool.intern("b"));
}

test "InternPool returns NoSpaceLeft for byte capacity" {
    var entries: [4]Entry = undefined;
    var bytes: [3]u8 = undefined;
    var pool = try InternPool.init(entries[0..], bytes[0..]);

    _ = try pool.intern("abc");
    try testing.expectError(error.NoSpaceLeft, pool.intern("d"));
}

test "InternPool contains matches interned values" {
    var entries: [4]Entry = undefined;
    var bytes: [16]u8 = undefined;
    var pool = try InternPool.init(entries[0..], bytes[0..]);

    try testing.expect(!pool.contains("alpha"));
    _ = try pool.intern("alpha");
    try testing.expect(pool.contains("alpha"));
    try testing.expect(!pool.contains("beta"));
}

test "InternPool bytesUsed tracks unique interned lengths" {
    var entries: [4]Entry = undefined;
    var bytes: [16]u8 = undefined;
    var pool = try InternPool.init(entries[0..], bytes[0..]);

    try testing.expectEqual(@as(usize, 0), pool.bytesUsed());

    _ = try pool.intern("a");
    _ = try pool.intern("bb");
    try testing.expectEqual(@as(usize, 3), pool.bytesUsed());

    _ = try pool.intern("a");
    try testing.expectEqual(@as(usize, 3), pool.bytesUsed());
}
