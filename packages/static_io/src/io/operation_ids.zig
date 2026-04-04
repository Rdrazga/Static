//! Shared operation-id encoding for `static_io` backends.
//!
//! Layout:
//! - bit 31: reserved for backend-internal IDs
//! - bits 16..30: external generation
//! - bits 0..15: external slot index

const std = @import("std");
const types = @import("types.zig");

pub const internal_flag: types.OperationId = 0x8000_0000;
pub const index_bits: u5 = 16;
pub const index_mask: types.OperationId = (1 << index_bits) - 1;
pub const generation_mask: types.OperationId = 0x7FFF;
pub const max_external_slots: u32 = index_mask;

pub const DecodedOperationId = struct {
    index: u32,
    generation: u32,
};

comptime {
    std.debug.assert(index_mask == 0xFFFF);
    std.debug.assert(generation_mask == 0x7FFF);
}

pub fn encodeExternalOperationId(slot_index: u32, generation: u32) types.OperationId {
    std.debug.assert(slot_index <= max_external_slots);
    std.debug.assert(generation > 0);
    std.debug.assert(generation <= generation_mask);
    return (generation << index_bits) | slot_index;
}

pub fn decodeExternalOperationId(operation_id: types.OperationId) ?DecodedOperationId {
    if ((operation_id & internal_flag) != 0) return null;
    const decoded: DecodedOperationId = .{
        .index = operation_id & index_mask,
        .generation = (operation_id >> index_bits) & generation_mask,
    };
    if (decoded.generation == 0) return null;
    return decoded;
}

pub fn encodeInternalOperationId(namespace_id: u32) types.OperationId {
    std.debug.assert(namespace_id > 0);
    std.debug.assert(namespace_id < internal_flag);
    return internal_flag | namespace_id;
}

pub fn decodeInternalOperationId(operation_id: types.OperationId) ?u32 {
    if ((operation_id & internal_flag) == 0) return null;
    const namespace_id: u32 = operation_id & ~internal_flag;
    if (namespace_id == 0) return null;
    return namespace_id;
}

pub fn nextGeneration(current: u32) u32 {
    std.debug.assert(current <= generation_mask);
    if (current >= generation_mask) return 1;
    return current + 1;
}

test "external ids roundtrip and internal ids stay separate" {
    const external = encodeExternalOperationId(12, 7);
    const decoded = decodeExternalOperationId(external).?;
    try std.testing.expectEqual(@as(u32, 12), decoded.index);
    try std.testing.expectEqual(@as(u32, 7), decoded.generation);
    try std.testing.expect(decodeInternalOperationId(external) == null);

    const internal = encodeInternalOperationId(2);
    try std.testing.expect(decodeExternalOperationId(internal) == null);
    try std.testing.expectEqual(@as(?u32, 2), decodeInternalOperationId(internal));
}

test "next generation wraps to one" {
    try std.testing.expectEqual(@as(u32, 2), nextGeneration(1));
    try std.testing.expectEqual(@as(u32, 1), nextGeneration(generation_mask));
}
