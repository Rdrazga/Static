//! Verifies Handle struct layout, bit-packing, and sentinel values at compile time.
//! Checks that index and generation fields pack into the expected bit widths
//! and that sentinel handles are distinct from all valid handles.
const std = @import("std");
const testing = std.testing;
const static_collections = @import("static_collections");

const Handle = static_collections.handle.Handle;

test "handle invalid sentinel and packed layout stay bounded" {
    const invalid = Handle.invalid();
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), invalid.index);
    try testing.expectEqual(@as(u32, 0), invalid.generation);
    try testing.expect(!invalid.isValid());

    const valid: Handle = .{ .index = 7, .generation = 1 };
    try testing.expect(valid.isValid());

    const zero_generation: Handle = .{ .index = 7, .generation = 0 };
    try testing.expect(!zero_generation.isValid());

    const max_index: Handle = .{ .index = std.math.maxInt(u32), .generation = 1 };
    try testing.expect(!max_index.isValid());

    try testing.expectEqual(@as(usize, 8), @sizeOf(Handle));
    try testing.expectEqual(@as(usize, 64), @bitSizeOf(Handle));
}
