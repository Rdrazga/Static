const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const component_registry_mod = @import("component_registry.zig");

pub const EncodedBundleEntryHeader = extern struct {
    component_id: component_registry_mod.ComponentTypeId,
    payload_size: u32,
};

pub const DecodeError = error{
    MalformedBundle,
    ComponentOutOfRange,
    DuplicateComponent,
    UnsortedComponentIds,
};

pub fn encodedBundleSize(comptime Components: anytype, bundle: anytype) usize {
    return encodedBundleSizeForType(Components, @TypeOf(bundle));
}

pub fn encodedBundleSizeForType(comptime Components: anytype, comptime BundleType: type) usize {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const component_count: usize = comptime Registry.count();
    comptime validateBundleTuple(Registry, BundleType);

    var offset: usize = 0;
    inline for (0..component_count) |index| {
        const T = Registry.typeAt(index);
        if (tupleContainsType(BundleType, T)) {
            offset = std.mem.alignForward(usize, offset, @alignOf(EncodedBundleEntryHeader));
            offset += @sizeOf(EncodedBundleEntryHeader);
            if (@sizeOf(T) != 0) {
                offset = std.mem.alignForward(usize, offset, @alignOf(T));
                offset += @sizeOf(T);
            }
        }
    }
    return offset;
}

pub fn encodeBundleTuple(comptime Components: anytype, bundle: anytype, out: []u8) u32 {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const component_count: usize = comptime Registry.count();
    comptime validateBundleTuple(Registry, @TypeOf(bundle));

    const needed = encodedBundleSize(Components, bundle);
    assert(out.len >= needed);

    var offset: usize = 0;
    var encoded_count: u32 = 0;
    inline for (0..component_count) |index| {
        const T = Registry.typeAt(index);
        const maybe_value = tupleValueOfType(bundle, T);
        if (maybe_value) |value| {
            offset = std.mem.alignForward(usize, offset, @alignOf(EncodedBundleEntryHeader));
            var header: EncodedBundleEntryHeader = .{
                .component_id = .{ .value = @intCast(index) },
                .payload_size = @intCast(@sizeOf(T)),
            };
            @memcpy(
                out[offset .. offset + @sizeOf(EncodedBundleEntryHeader)],
                std.mem.asBytes(&header),
            );
            offset += @sizeOf(EncodedBundleEntryHeader);

            if (@sizeOf(T) != 0) {
                offset = std.mem.alignForward(usize, offset, @alignOf(T));
                const payload_bytes = std.mem.asBytes(&value);
                @memcpy(out[offset .. offset + payload_bytes.len], payload_bytes);
                offset += @sizeOf(T);
            }
            encoded_count += 1;
        }
    }

    assert(offset == needed);
    return encoded_count;
}

pub fn Reader(comptime Components: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);

    return struct {
        const Self = @This();

        pub const Error = DecodeError;

        pub const Entry = struct {
            component_id: component_registry_mod.ComponentTypeId,
            payload: []const u8,
        };

        bytes: []const u8,
        next_offset: usize = 0,
        remaining: u32,
        previous_component_id: ?u32 = null,

        pub fn init(bytes: []const u8, entry_count: u32) Self {
            return .{
                .bytes = bytes,
                .remaining = entry_count,
            };
        }

        pub fn next(self: *Self) Error!?Entry {
            if (self.remaining == 0) return null;

            var offset = std.mem.alignForward(usize, self.next_offset, @alignOf(EncodedBundleEntryHeader));
            if (offset > self.bytes.len or @sizeOf(EncodedBundleEntryHeader) > self.bytes.len - offset) {
                return error.MalformedBundle;
            }
            var header: EncodedBundleEntryHeader = undefined;
            @memcpy(
                std.mem.asBytes(&header),
                self.bytes[offset .. offset + @sizeOf(EncodedBundleEntryHeader)],
            );
            offset += @sizeOf(EncodedBundleEntryHeader);

            const payload_size = payloadSizeForId(Registry, header.component_id) orelse return error.ComponentOutOfRange;
            if (payload_size != header.payload_size) return error.MalformedBundle;
            if (self.previous_component_id) |previous_id| {
                if (header.component_id.value == previous_id) return error.DuplicateComponent;
                if (header.component_id.value < previous_id) return error.UnsortedComponentIds;
            }

            var payload: []const u8 = &.{};
            if (payload_size != 0) {
                const payload_alignment = payloadAlignmentForId(Registry, header.component_id).?;
                offset = std.mem.alignForward(usize, offset, payload_alignment);
                if (offset > self.bytes.len or payload_size > self.bytes.len - offset) {
                    return error.MalformedBundle;
                }
                payload = self.bytes[offset .. offset + payload_size];
                offset += payload_size;
            }

            self.next_offset = offset;
            self.remaining -= 1;
            self.previous_component_id = header.component_id.value;
            return .{
                .component_id = header.component_id,
                .payload = payload,
            };
        }
    };
}

fn tupleFields(comptime BundleType: type, comptime err: []const u8) []const std.builtin.Type.StructField {
    const info = @typeInfo(BundleType);
    switch (info) {
        .@"struct" => |struct_info| {
            if (!struct_info.is_tuple) {
                @compileError(err);
            }
            return struct_info.fields;
        },
        else => @compileError(err),
    }
}

fn tupleContainsType(comptime BundleType: type, comptime T: type) bool {
    const fields = tupleFields(BundleType, "bundle values must be passed as a comptime tuple.");
    inline for (fields) |field| {
        if (field.type == T) return true;
    }
    return false;
}

fn tupleValueOfType(bundle: anytype, comptime T: type) ?T {
    const fields = tupleFields(@TypeOf(bundle), "bundle values must be passed as a comptime tuple.");
    inline for (fields) |field| {
        const value = @field(bundle, field.name);
        if (@TypeOf(value) == T) return value;
    }
    return null;
}

fn validateBundleTuple(comptime Registry: type, comptime BundleType: type) void {
    const fields = tupleFields(BundleType, "bundle values must be passed as a comptime tuple.");
    inline for (fields, 0..) |field_i, index_i| {
        const T = field_i.type;
        if (!Registry.contains(T)) {
            @compileError("bundle values must come from the component universe.");
        }

        inline for (fields[0..index_i]) |field_j| {
            if (field_j.type == T) {
                @compileError("bundle values must not repeat the same component type.");
            }
        }
    }
}

fn payloadSizeForId(comptime Registry: type, id: component_registry_mod.ComponentTypeId) ?u32 {
    const component_count: usize = comptime Registry.count();
    inline for (0..component_count) |index| {
        if (id.value == index) {
            return @intCast(@sizeOf(Registry.typeAt(index)));
        }
    }
    return null;
}

fn payloadAlignmentForId(comptime Registry: type, id: component_registry_mod.ComponentTypeId) ?usize {
    const component_count: usize = comptime Registry.count();
    inline for (0..component_count) |index| {
        if (id.value == index) {
            return @alignOf(Registry.typeAt(index));
        }
    }
    return null;
}

test "bundle reader preserves well-formed encoded entries" {
    const Position = struct { x: f32, y: f32 };
    const Tag = struct {};
    const encoded_len: comptime_int = comptime encodedBundleSize(.{ Position, Tag }, .{
        Position{ .x = 1, .y = 2 },
        Tag{},
    });

    var encoded_storage: [encoded_len + 1]u8 = undefined;
    const encoded = encoded_storage[1 .. 1 + encoded_len];
    const entry_count = encodeBundleTuple(.{ Position, Tag }, .{
        Position{ .x = 1, .y = 2 },
        Tag{},
    }, encoded);

    var reader = Reader(.{ Position, Tag }).init(encoded, entry_count);
    const first = (try reader.next()).?;
    try testing.expectEqual(@as(u32, 0), first.component_id.value);
    try testing.expectEqual(@as(usize, @sizeOf(Position)), first.payload.len);

    const second = (try reader.next()).?;
    try testing.expectEqual(@as(u32, 1), second.component_id.value);
    try testing.expectEqual(@as(usize, 0), second.payload.len);
    try testing.expect(try reader.next() == null);
}

test "bundle reader rejects malformed encoded entries" {
    const Position = struct { value: u32 };
    const Velocity = struct { value: u32 };
    const ReaderShape = Reader(.{ Position, Velocity });

    var valid: [encodedBundleSize(.{ Position, Velocity }, .{Position{ .value = 7 }})]u8 = undefined;
    const valid_count = encodeBundleTuple(.{ Position, Velocity }, .{Position{ .value = 7 }}, valid[0..]);

    var truncated_header_reader = ReaderShape.init(valid[0..4], valid_count);
    try testing.expectError(error.MalformedBundle, truncated_header_reader.next());

    var truncated_payload_reader = ReaderShape.init(valid[0 .. valid.len - 1], valid_count);
    try testing.expectError(error.MalformedBundle, truncated_payload_reader.next());

    var invalid_id = valid;
    var invalid_header = readHeader(invalid_id[0..], 0);
    invalid_header.component_id = .{ .value = 2 };
    writeHeader(invalid_id[0..], 0, invalid_header);
    var invalid_id_reader = ReaderShape.init(invalid_id[0..], valid_count);
    try testing.expectError(error.ComponentOutOfRange, invalid_id_reader.next());

    var invalid_size = valid;
    var invalid_size_header = readHeader(invalid_size[0..], 0);
    invalid_size_header.payload_size += 1;
    writeHeader(invalid_size[0..], 0, invalid_size_header);
    var invalid_size_reader = ReaderShape.init(invalid_size[0..], valid_count);
    try testing.expectError(error.MalformedBundle, invalid_size_reader.next());

    const first_payload = std.mem.asBytes(&Position{ .value = 11 });
    const second_payload = std.mem.asBytes(&Velocity{ .value = 22 });

    var duplicate_bytes: [24]u8 = undefined;
    var duplicate_len = writeTestEntry(duplicate_bytes[0..], 0, .{
        .component_id = .{ .value = 0 },
        .payload_size = @intCast(first_payload.len),
    }, first_payload, @alignOf(Position));
    duplicate_len = writeTestEntry(duplicate_bytes[0..], duplicate_len, .{
        .component_id = .{ .value = 0 },
        .payload_size = @intCast(first_payload.len),
    }, first_payload, @alignOf(Position));
    var duplicate_reader = ReaderShape.init(duplicate_bytes[0..duplicate_len], 2);
    _ = (try duplicate_reader.next()).?;
    try testing.expectError(error.DuplicateComponent, duplicate_reader.next());

    var unsorted_bytes: [24]u8 = undefined;
    var unsorted_len = writeTestEntry(unsorted_bytes[0..], 0, .{
        .component_id = .{ .value = 1 },
        .payload_size = @intCast(second_payload.len),
    }, second_payload, @alignOf(Velocity));
    unsorted_len = writeTestEntry(unsorted_bytes[0..], unsorted_len, .{
        .component_id = .{ .value = 0 },
        .payload_size = @intCast(first_payload.len),
    }, first_payload, @alignOf(Position));
    var unsorted_reader = ReaderShape.init(unsorted_bytes[0..unsorted_len], 2);
    _ = (try unsorted_reader.next()).?;
    try testing.expectError(error.UnsortedComponentIds, unsorted_reader.next());
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
