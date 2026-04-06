const std = @import("std");
const assert = std.debug.assert;
const component_registry_mod = @import("component_registry.zig");

pub const EncodedBundleEntryHeader = extern struct {
    component_id: component_registry_mod.ComponentTypeId,
    payload_size: u32,
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
            const header_ptr: *EncodedBundleEntryHeader = @ptrCast(@alignCast(&out[offset]));
            header_ptr.* = .{
                .component_id = .{ .value = @intCast(index) },
                .payload_size = @intCast(@sizeOf(T)),
            };
            offset += @sizeOf(EncodedBundleEntryHeader);

            if (@sizeOf(T) != 0) {
                offset = std.mem.alignForward(usize, offset, @alignOf(T));
                const payload_ptr: *T = @ptrCast(@alignCast(&out[offset]));
                payload_ptr.* = value;
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

        pub const Entry = struct {
            component_id: component_registry_mod.ComponentTypeId,
            payload: []const u8,
        };

        bytes: []const u8,
        next_offset: usize = 0,
        remaining: u32,

        pub fn init(bytes: []const u8, entry_count: u32) Self {
            return .{
                .bytes = bytes,
                .remaining = entry_count,
            };
        }

        pub fn next(self: *Self) ?Entry {
            if (self.remaining == 0) return null;

            var offset = std.mem.alignForward(usize, self.next_offset, @alignOf(EncodedBundleEntryHeader));
            assert(offset + @sizeOf(EncodedBundleEntryHeader) <= self.bytes.len);
            const header_ptr: *const EncodedBundleEntryHeader = @ptrCast(@alignCast(&self.bytes[offset]));
            const header = header_ptr.*;
            offset += @sizeOf(EncodedBundleEntryHeader);

            const payload_size = payloadSizeForId(Registry, header.component_id);
            assert(payload_size == header.payload_size);

            var payload: []const u8 = &.{};
            if (payload_size != 0) {
                const payload_alignment = payloadAlignmentForId(Registry, header.component_id);
                offset = std.mem.alignForward(usize, offset, payload_alignment);
                assert(offset + payload_size <= self.bytes.len);
                payload = self.bytes[offset .. offset + payload_size];
                offset += payload_size;
            }

            self.next_offset = offset;
            self.remaining -= 1;
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

fn payloadSizeForId(comptime Registry: type, id: component_registry_mod.ComponentTypeId) u32 {
    const component_count: usize = comptime Registry.count();
    inline for (0..component_count) |index| {
        if (id.value == index) {
            return @intCast(@sizeOf(Registry.typeAt(index)));
        }
    }
    unreachable;
}

fn payloadAlignmentForId(comptime Registry: type, id: component_registry_mod.ComponentTypeId) usize {
    const component_count: usize = comptime Registry.count();
    inline for (0..component_count) |index| {
        if (id.value == index) {
            return @alignOf(Registry.typeAt(index));
        }
    }
    unreachable;
}
