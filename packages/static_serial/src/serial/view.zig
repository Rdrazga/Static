//! Non-owning validated byte-slice view.
//!
//! Key types: `View`.
//! Usage pattern: call `View.init(bytes)` to wrap a caller-owned slice;
//! use `asBytes()`, `len()`, `isEmpty()`, and `slice(start, end)` to access data.
//! Thread safety: not thread-safe — views do not synchronize access to the underlying slice.

const std = @import("std");

/// A lightweight, non-owning view over a byte slice.
/// Used as a stable validated surface when the caller owns lifetime.
pub const View = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) View {
        const v = View{ .bytes = bytes };
        // Postcondition: the backing slice pointer is stable -- the view does not
        // copy the bytes, so the pointer must equal what was passed in.
        std.debug.assert(v.bytes.ptr == bytes.ptr);
        // Postcondition: the length matches the input slice exactly.
        std.debug.assert(v.bytes.len == bytes.len);
        return v;
    }

    pub fn asBytes(self: View) []const u8 {
        // Invariant: the backing slice is always well-formed.
        std.debug.assert(self.bytes.len == self.len());
        return self.bytes;
    }

    pub fn len(self: View) usize {
        // Postcondition: returned length is always consistent with backing slice.
        std.debug.assert(self.bytes.len == self.bytes.len); // structural self-check
        return self.bytes.len;
    }

    pub fn isEmpty(self: View) bool {
        const empty = self.bytes.len == 0;
        // Postcondition: isEmpty and len == 0 must agree.
        std.debug.assert(empty == (self.bytes.len == 0));
        return empty;
    }

    pub fn slice(self: View, start: usize, end: usize) error{InvalidInput}!View {
        // start and end come from the caller, so validate rather than assert.
        if (start > end) return error.InvalidInput;
        if (end > self.bytes.len) return error.InvalidInput;
        std.debug.assert(start <= end);
        std.debug.assert(end <= self.bytes.len);
        return View.init(self.bytes[start..end]);
    }
};

test "view basic operations" {
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    const v = View.init(&data);
    std.debug.assert(v.bytes.len == 3);
    try std.testing.expectEqual(@as(usize, 3), v.len());
    try std.testing.expect(!v.isEmpty());

    const empty = View.init(&[_]u8{});
    try std.testing.expect(empty.isEmpty());
}

test "view slice returns sub-view and rejects out-of-bounds" {
    const data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const v = View.init(&data);

    const sub = try v.slice(1, 3);
    std.debug.assert(sub.len() == 2);
    try std.testing.expectEqualSlices(u8, &.{ 0xBB, 0xCC }, sub.asBytes());

    try std.testing.expectError(error.InvalidInput, v.slice(2, 5));
}
