const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const ComponentTypeId = packed struct {
    value: u32,

    comptime {
        assert(@sizeOf(ComponentTypeId) == 4);
        assert(@bitSizeOf(ComponentTypeId) == 32);
    }
};

pub fn ComponentRegistry(comptime Components: anytype) type {
    comptime validateComponentUniverse(Components);

    return struct {
        pub fn count() u32 {
            comptime assert(componentCount(Components) <= std.math.maxInt(u32));
            return @intCast(componentCount(Components));
        }

        pub fn contains(comptime T: type) bool {
            return indexOf(T) != null;
        }

        pub fn typeId(comptime T: type) ?ComponentTypeId {
            if (indexOf(T)) |index| {
                assert(index <= std.math.maxInt(u32));
                return .{ .value = @intCast(index) };
            }
            return null;
        }

        pub fn typeAt(comptime index: usize) type {
            const component = componentAt(Components, index);
            comptime assert(@TypeOf(component) == type);
            return component;
        }

        fn indexOf(comptime T: type) ?usize {
            inline for (universeFields(Components), 0..) |field, index| {
                const component = @field(Components, field.name);
                if (component == T) return index;
            }
            return null;
        }
    };
}

fn validateComponentUniverse(comptime Components: anytype) void {
    const fields = universeFields(Components);

    inline for (fields, 0..) |field_i, index_i| {
        const component_i = @field(Components, field_i.name);
        if (@TypeOf(component_i) != type) {
            @compileError("Component universe entries must be types.");
        }

        inline for (fields[0..index_i]) |field_j| {
            const component_j = @field(Components, field_j.name);
            if (component_i == component_j) {
                @compileError("Component universe must not contain duplicate component types.");
            }
        }
    }
}

fn componentCount(comptime Components: anytype) usize {
    return universeFields(Components).len;
}

fn componentAt(comptime Components: anytype, comptime index: usize) type {
    const fields = universeFields(Components);
    comptime assert(index < fields.len);

    const component = @field(Components, fields[index].name);
    if (@TypeOf(component) != type) {
        @compileError("Component universe entries must be types.");
    }
    return component;
}

fn universeFields(comptime Components: anytype) []const std.builtin.Type.StructField {
    const info = @typeInfo(@TypeOf(Components));
    switch (info) {
        .@"struct" => |struct_info| {
            if (!struct_info.is_tuple) {
                @compileError("Component universe must be passed as a comptime tuple of types.");
            }
            return struct_info.fields;
        },
        else => @compileError("Component universe must be passed as a comptime tuple of types."),
    }
}

test "component registry counts and ids are deterministic" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Registry = ComponentRegistry(.{ Position, Velocity });

    try testing.expectEqual(@as(u32, 2), Registry.count());
    try testing.expect(Registry.contains(Position));
    try testing.expect(!Registry.contains(u32));
    try testing.expectEqual(@as(u32, 0), Registry.typeId(Position).?.value);
    try testing.expectEqual(@as(u32, 1), Registry.typeId(Velocity).?.value);
}

test "component registry can return comptime component types by index" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Registry = ComponentRegistry(.{ Position, Velocity });

    try testing.expect(Registry.typeAt(0) == Position);
    try testing.expect(Registry.typeAt(1) == Velocity);
}
