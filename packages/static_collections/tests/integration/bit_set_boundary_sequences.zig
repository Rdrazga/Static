const std = @import("std");
const static_collections = @import("static_collections");

const BitSet = static_collections.bit_set.BitSet;

fn expectTrailingBitsClear(words: []const usize, bit_count: usize) !void {
    const word_bits = @bitSizeOf(usize);
    try std.testing.expect(bit_count > 0);
    try std.testing.expect(words.len > 0);

    const capacity_bits = words.len * word_bits;
    const trailing_bits = capacity_bits - bit_count;
    if (trailing_bits == 0) return;

    const used_bits = word_bits - trailing_bits;
    const used_mask = (@as(usize, 1) << @intCast(used_bits)) - 1;
    const last = words[words.len - 1];
    try std.testing.expectEqual(last & used_mask, last);
}

test "bit_set keeps word-boundary visibility and trailing bits clear" {
    const word_bits = @bitSizeOf(usize);
    const bit_count = word_bits + 2;
    var bits = try BitSet.init(std.testing.allocator, .{ .bit_count = bit_count });
    defer bits.deinit();

    try bits.set(0);
    try bits.set(word_bits - 1);
    try bits.set(word_bits);
    try bits.set(bit_count - 1);

    try std.testing.expect(bits.isSet(0));
    try std.testing.expect(bits.isSet(word_bits - 1));
    try std.testing.expect(bits.isSet(word_bits));
    try std.testing.expect(bits.isSet(bit_count - 1));
    try expectTrailingBitsClear(bits.words, bits.bit_count);

    try bits.clear(word_bits - 1);
    try bits.clear(bit_count - 1);
    try std.testing.expect(bits.isSet(0));
    try std.testing.expect(!bits.isSet(word_bits - 1));
    try std.testing.expect(bits.isSet(word_bits));
    try std.testing.expect(!bits.isSet(bit_count - 1));
    try expectTrailingBitsClear(bits.words, bits.bit_count);

    try std.testing.expectError(error.InvalidInput, bits.set(bit_count));
    try std.testing.expectError(error.InvalidInput, bits.clear(bit_count));
    try std.testing.expect(!bits.isSet(bit_count));
}

test "FixedBitSet keeps boundary bits visible and rejects out-of-bounds access" {
    const word_bits = @bitSizeOf(usize);
    const Fixed = static_collections.bit_set.FixedBitSet(word_bits + 1);
    var bits = Fixed{};

    try bits.set(0);
    try bits.set(word_bits - 1);
    try bits.set(word_bits);

    try std.testing.expect(bits.isSet(0));
    try std.testing.expect(bits.isSet(word_bits - 1));
    try std.testing.expect(bits.isSet(word_bits));
    try expectTrailingBitsClear(bits.words[0..], Fixed.bit_count);

    try bits.clear(word_bits - 1);
    try std.testing.expect(bits.isSet(0));
    try std.testing.expect(!bits.isSet(word_bits - 1));
    try std.testing.expect(bits.isSet(word_bits));
    try expectTrailingBitsClear(bits.words[0..], Fixed.bit_count);

    try std.testing.expectError(error.InvalidInput, bits.set(word_bits + 1));
    try std.testing.expectError(error.InvalidInput, bits.clear(word_bits + 1));
    try std.testing.expect(!bits.isSet(word_bits + 1));
}
