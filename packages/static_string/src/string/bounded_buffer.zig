//! Fixed-capacity append buffer over caller-provided storage.
//!
//! Key types: `BoundedBuffer`, `BufferError`.
//! Usage pattern: allocate a `[]u8` storage slice, call `BoundedBuffer.init(storage)`,
//! then use `append`, `appendByte`, or `appendFmt` to write; call `bytes()` to read
//! the used prefix. `truncate` and `clear` reduce the length without reallocating.
//! All appends are atomic — they either succeed fully or leave the buffer unchanged.
//! Thread safety: not thread-safe — a single instance must be owned by one thread.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const BufferError = error{
    NoSpaceLeft,
};

pub const BoundedBuffer = struct {
    storage: []u8,
    len_used: usize,

    pub fn init(storage: []u8) BoundedBuffer {
        return .{
            .storage = storage,
            .len_used = 0,
        };
    }

    pub fn len(self: *const BoundedBuffer) usize {
        assert(self.len_used <= self.storage.len);
        return self.len_used;
    }

    pub fn capacity(self: *const BoundedBuffer) usize {
        return self.storage.len;
    }

    pub fn bytes(self: *const BoundedBuffer) []const u8 {
        assert(self.len_used <= self.storage.len);
        return self.storage[0..self.len_used];
    }

    pub fn clear(self: *BoundedBuffer) void {
        assert(self.len_used <= self.storage.len);
        self.len_used = 0;
        assert(self.len_used <= self.storage.len);
    }

    pub fn truncate(self: *BoundedBuffer, new_len: usize) void {
        assert(self.len_used <= self.storage.len);
        assert(new_len <= self.storage.len);
        assert(new_len <= self.len_used);
        self.len_used = new_len;
        assert(self.len_used <= self.storage.len);
    }

    pub fn appendByte(self: *BoundedBuffer, value: u8) BufferError!void {
        assert(self.len_used <= self.storage.len);
        if (self.len_used >= self.storage.len) return error.NoSpaceLeft;
        self.storage[self.len_used] = value;
        self.len_used += 1;
        assert(self.len_used <= self.storage.len);
    }

    pub fn append(self: *BoundedBuffer, value: []const u8) BufferError!void {
        assert(self.len_used <= self.storage.len);

        const remaining_len = self.storage.len - self.len_used;
        if (remaining_len < value.len) return error.NoSpaceLeft;
        const end = self.len_used + value.len;
        assert(end <= self.storage.len);
        @memcpy(self.storage[self.len_used..end], value);
        self.len_used = end;
        assert(self.len_used <= self.storage.len);
    }

    pub fn appendFmt(self: *BoundedBuffer, comptime fmt: []const u8, args: anytype) BufferError!void {
        assert(self.len_used <= self.storage.len);
        const remaining = self.storage[self.len_used..];
        const rendered = std.fmt.bufPrint(remaining, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => return error.NoSpaceLeft,
        };
        self.len_used += rendered.len;
        assert(self.len_used <= self.storage.len);
    }
};

test "BoundedBuffer append and bytes roundtrip" {
    var storage: [16]u8 = undefined;
    var buffer = BoundedBuffer.init(storage[0..]);
    try buffer.append("abc");
    try buffer.appendByte('d');
    try testing.expectEqualStrings("abcd", buffer.bytes());
}

test "BoundedBuffer append returns NoSpaceLeft without partial write" {
    var storage: [4]u8 = undefined;
    var buffer = BoundedBuffer.init(storage[0..]);
    try buffer.append("abcd");

    const before = buffer.len();
    try testing.expectError(error.NoSpaceLeft, buffer.appendByte('e'));
    try testing.expectEqual(before, buffer.len());
    try testing.expectEqualStrings("abcd", buffer.bytes());
}

test "BoundedBuffer append returns NoSpaceLeft without partial write (slice)" {
    var storage: [4]u8 = undefined;
    var buffer = BoundedBuffer.init(storage[0..]);
    try buffer.append("ab");

    const before = buffer.len();
    try testing.expectError(error.NoSpaceLeft, buffer.append("cde"));
    try testing.expectEqual(before, buffer.len());
    try testing.expectEqualStrings("ab", buffer.bytes());
}

test "BoundedBuffer appendFmt returns NoSpaceLeft without partial write" {
    var storage: [4]u8 = undefined;
    var buffer = BoundedBuffer.init(storage[0..]);
    try buffer.append("ab");

    const before = buffer.len();
    try testing.expectError(error.NoSpaceLeft, buffer.appendFmt("{s}", .{"cde"}));
    try testing.expectEqual(before, buffer.len());
    try testing.expectEqualStrings("ab", buffer.bytes());
}

test "BoundedBuffer truncate and clear" {
    var storage: [10]u8 = undefined;
    var buffer = BoundedBuffer.init(storage[0..]);
    try buffer.append("hello");
    buffer.truncate(2);
    try testing.expectEqualStrings("he", buffer.bytes());
    buffer.clear();
    try testing.expectEqual(@as(usize, 0), buffer.len());
}

test "BoundedBuffer appendFmt writes formatted text" {
    var storage: [32]u8 = undefined;
    var buffer = BoundedBuffer.init(storage[0..]);
    try buffer.appendFmt("{s}-{d}", .{ "value", 42 });
    try testing.expectEqualStrings("value-42", buffer.bytes());
}
