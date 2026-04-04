const std = @import("std");
const static_collections = @import("static_collections");

const Handle = static_collections.handle.Handle;

test "handle invalid sentinel and packed layout stay bounded" {
    const invalid = Handle.invalid();
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), invalid.index);
    try std.testing.expectEqual(@as(u32, 0), invalid.generation);
    try std.testing.expect(!invalid.isValid());

    const valid: Handle = .{ .index = 7, .generation = 1 };
    try std.testing.expect(valid.isValid());

    const zero_generation: Handle = .{ .index = 7, .generation = 0 };
    try std.testing.expect(!zero_generation.isValid());

    const max_index: Handle = .{ .index = std.math.maxInt(u32), .generation = 1 };
    try std.testing.expect(!max_index.isValid());

    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Handle));
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(Handle));
}
