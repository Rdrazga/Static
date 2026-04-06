const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_ecs = @import("static_ecs");

const EncodedBundleEntryHeader = extern struct {
    component_id: static_ecs.ComponentTypeId,
    payload_size: u32,
};

test "world encoded bundle surfaces accept well-formed payloads" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Tag = struct {};
    const Components = .{ Position, Velocity, Tag };
    const World = static_ecs.World(Components);

    var world = try World.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 8,
        .chunk_rows_max = 4,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    var spawn_storage: [33]u8 = undefined;
    const spawn_entry_count: u32 = 2;
    const spawn_len = buildPositionTagBundle(spawn_storage[1..], Position{ .x = 1, .y = 2 });
    const spawn_bytes = spawn_storage[1 .. 1 + spawn_len];
    const spawned = try world.spawnBundleFromEncoded(spawn_bytes[0..], spawn_entry_count);
    try testing.expect(world.hasComponent(spawned, Position));
    try testing.expect(world.hasComponent(spawned, Tag));
    try testing.expectEqual(@as(f32, 1), world.componentPtrConst(spawned, Position).?.x);

    const existing = try world.spawn();
    var insert_storage: [33]u8 = undefined;
    const insert_entry_count: u32 = 2;
    const insert_len = buildPositionVelocityBundle(
        insert_storage[1..],
        Position{ .x = 10, .y = 20 },
        Velocity{ .x = 30, .y = 40 },
    );
    const insert_bytes = insert_storage[1 .. 1 + insert_len];
    try world.insertBundleEncoded(existing, insert_bytes[0..], insert_entry_count);
    try testing.expect(world.hasComponent(existing, Position));
    try testing.expect(world.hasComponent(existing, Velocity));
    try testing.expectEqual(@as(f32, 30), world.componentPtrConst(existing, Velocity).?.x);
}

test "world encoded bundle surfaces reject malformed payloads without mutating state" {
    const Position = struct { value: u32 };
    const Velocity = struct { value: u32 };
    const Components = .{ Position, Velocity };
    const World = static_ecs.World(Components);

    var world = try World.init(testing.allocator, .{
        .entities_max = 8,
        .archetypes_max = 8,
        .components_per_archetype_max = 4,
        .chunks_max = 8,
        .chunk_rows_max = 4,
        .command_buffer_entries_max = 8,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    var valid_storage: [16]u8 = undefined;
    const valid_entry_count: u32 = 1;
    const valid_len = buildSingleEntryBundle(valid_storage[0..], 0, Position{ .value = 7 });
    const valid_bytes = valid_storage[0..valid_len];

    try expectSpawnBundleError(&world, valid_bytes[0..4], valid_entry_count, error.MalformedBundle);
    try expectSpawnBundleError(&world, valid_bytes[0 .. valid_bytes.len - 1], valid_entry_count, error.MalformedBundle);

    var invalid_id_storage = valid_storage;
    const invalid_id_bytes = invalid_id_storage[0..valid_len];
    var invalid_id_header = readHeader(invalid_id_bytes[0..], 0);
    invalid_id_header.component_id = .{ .value = 2 };
    writeHeader(invalid_id_bytes[0..], 0, invalid_id_header);
    try expectSpawnBundleError(&world, invalid_id_bytes[0..], valid_entry_count, error.ComponentOutOfRange);

    var invalid_size_storage = valid_storage;
    const invalid_size_bytes = invalid_size_storage[0..valid_len];
    var invalid_size_header = readHeader(invalid_size_bytes[0..], 0);
    invalid_size_header.payload_size += 1;
    writeHeader(invalid_size_bytes[0..], 0, invalid_size_header);
    try expectSpawnBundleError(&world, invalid_size_bytes[0..], valid_entry_count, error.MalformedBundle);

    var duplicate_bytes: [24]u8 = undefined;
    const duplicate_payload = std.mem.asBytes(&Position{ .value = 11 });
    var duplicate_len = writeTestEntry(duplicate_bytes[0..], 0, .{
        .component_id = .{ .value = 0 },
        .payload_size = @intCast(duplicate_payload.len),
    }, duplicate_payload, @alignOf(Position));
    duplicate_len = writeTestEntry(duplicate_bytes[0..], duplicate_len, .{
        .component_id = .{ .value = 0 },
        .payload_size = @intCast(duplicate_payload.len),
    }, duplicate_payload, @alignOf(Position));
    try expectSpawnBundleError(&world, duplicate_bytes[0..duplicate_len], 2, error.DuplicateComponent);

    var unsorted_bytes: [24]u8 = undefined;
    const first_payload = std.mem.asBytes(&Velocity{ .value = 22 });
    const second_payload = std.mem.asBytes(&Position{ .value = 33 });
    var unsorted_len = writeTestEntry(unsorted_bytes[0..], 0, .{
        .component_id = .{ .value = 1 },
        .payload_size = @intCast(first_payload.len),
    }, first_payload, @alignOf(Velocity));
    unsorted_len = writeTestEntry(unsorted_bytes[0..], unsorted_len, .{
        .component_id = .{ .value = 0 },
        .payload_size = @intCast(second_payload.len),
    }, second_payload, @alignOf(Position));
    try expectSpawnBundleError(&world, unsorted_bytes[0..unsorted_len], 2, error.UnsortedComponentIds);
}

test "world encoded bundle spawn rejects entities not allocated by the world" {
    const Position = struct { x: f32, y: f32 };
    const Components = .{Position};
    const World = static_ecs.World(Components);

    var world = try World.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .command_buffer_entries_max = 4,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });
    defer world.deinit();

    var encoded_storage: [16]u8 = undefined;
    const entry_count: u32 = 1;
    const encoded_len = buildSingleEntryBundle(encoded_storage[0..], 0, Position{ .x = 1, .y = 2 });
    const encoded = encoded_storage[0..encoded_len];

    const fabricated: static_ecs.Entity = .{ .index = 0, .generation = 1 };
    try testing.expectError(error.EntityNotAllocated, world.spawnBundleEncoded(fabricated, encoded[0..], entry_count));
    try testing.expectEqual(@as(u32, 0), world.entityCount());
    try testing.expectEqual(@as(u32, 1), world.archetypeCount());
    try testing.expectEqual(@as(u32, 0), world.chunkCount());
    try testing.expect(!world.contains(fabricated));
}

test "world empty chunk retention survives retained-chunk reuse" {
    const Position = struct { x: f32, y: f32 };
    const Components = .{Position};
    const World = static_ecs.World(Components);

    var world = try World.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 1,
        .command_buffer_entries_max = 4,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 1,
        .budget = null,
    });
    defer world.deinit();

    var encoded_storage: [16]u8 = undefined;
    const entry_count: u32 = 1;
    const encoded_len = buildSingleEntryBundle(encoded_storage[0..], 0, Position{ .x = 1, .y = 2 });
    const encoded = encoded_storage[0..encoded_len];

    const first = try world.spawnBundleFromEncoded(encoded[0..], entry_count);
    const second = try world.spawnBundleFromEncoded(encoded[0..], entry_count);
    try testing.expectEqual(@as(u32, 2), world.chunkCount());

    try world.despawn(first);
    try testing.expectEqual(@as(u32, 2), world.chunkCount());

    const third = try world.spawnBundleFromEncoded(encoded[0..], entry_count);
    try testing.expectEqual(@as(u32, 2), world.chunkCount());
    try testing.expect(world.hasComponent(third, Position));

    try world.despawn(third);
    try testing.expectEqual(@as(u32, 2), world.chunkCount());
    try testing.expect(world.contains(second));
}

fn expectSpawnBundleError(
    world: anytype,
    bytes: []const u8,
    entry_count: u32,
    expected_error: anytype,
) !void {
    try testing.expectError(expected_error, world.spawnBundleFromEncoded(bytes, entry_count));
    try testing.expectEqual(@as(u32, 0), world.entityCount());
    try testing.expectEqual(@as(u32, 1), world.archetypeCount());
    try testing.expectEqual(@as(u32, 0), world.chunkCount());
}

fn writeTestEntry(
    out: []u8,
    start_offset: usize,
    header: EncodedBundleEntryHeader,
    payload: []const u8,
    payload_alignment: usize,
) usize {
    var offset = std.mem.alignForward(usize, start_offset, @alignOf(EncodedBundleEntryHeader));
    writeHeader(out, offset, header);
    offset += @sizeOf(EncodedBundleEntryHeader);

    if (payload.len != 0) {
        offset = std.mem.alignForward(usize, offset, payload_alignment);
        @memcpy(out[offset .. offset + payload.len], payload);
        offset += payload.len;
    }

    return offset;
}

fn buildSingleEntryBundle(out: []u8, component_id: u32, value: anytype) usize {
    const payload = std.mem.asBytes(&value);
    const end = writeTestEntry(out, 0, .{
        .component_id = .{ .value = component_id },
        .payload_size = @intCast(payload.len),
    }, payload, @alignOf(@TypeOf(value)));
    assert(end <= out.len);
    return end;
}

fn readHeader(bytes: []const u8, offset: usize) EncodedBundleEntryHeader {
    var header: EncodedBundleEntryHeader = undefined;
    @memcpy(
        std.mem.asBytes(&header),
        bytes[offset .. offset + @sizeOf(EncodedBundleEntryHeader)],
    );
    return header;
}

fn writeHeader(out: []u8, offset: usize, header: EncodedBundleEntryHeader) void {
    var header_copy = header;
    @memcpy(
        out[offset .. offset + @sizeOf(EncodedBundleEntryHeader)],
        std.mem.asBytes(&header_copy),
    );
}

fn buildPositionTagBundle(out: []u8, position: anytype) usize {
    const payload = std.mem.asBytes(&position);
    var end = writeTestEntry(out, 0, .{
        .component_id = .{ .value = 0 },
        .payload_size = @intCast(payload.len),
    }, payload, @alignOf(@TypeOf(position)));
    end = writeTestEntry(out, end, .{
        .component_id = .{ .value = 2 },
        .payload_size = 0,
    }, &.{}, 1);
    assert(end <= out.len);
    return end;
}

fn buildPositionVelocityBundle(out: []u8, position: anytype, velocity: anytype) usize {
    const position_payload = std.mem.asBytes(&position);
    const velocity_payload = std.mem.asBytes(&velocity);
    var end = writeTestEntry(out, 0, .{
        .component_id = .{ .value = 0 },
        .payload_size = @intCast(position_payload.len),
    }, position_payload, @alignOf(@TypeOf(position)));
    end = writeTestEntry(out, end, .{
        .component_id = .{ .value = 1 },
        .payload_size = @intCast(velocity_payload.len),
    }, velocity_payload, @alignOf(@TypeOf(velocity)));
    assert(end <= out.len);
    return end;
}
