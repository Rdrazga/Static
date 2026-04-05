const std = @import("std");
const testing = std.testing;
const component_registry_mod = @import("component_registry.zig");
const archetype_key_mod = @import("archetype_key.zig");

pub const AccessMode = enum(u8) {
    read,
    write,
    optional_read,
    optional_write,
    with,
    exclude,
};

pub fn Read(comptime T: type) type {
    return AccessDescriptor(T, .read);
}

pub fn Write(comptime T: type) type {
    return AccessDescriptor(T, .write);
}

pub fn OptionalRead(comptime T: type) type {
    return AccessDescriptor(T, .optional_read);
}

pub fn OptionalWrite(comptime T: type) type {
    return AccessDescriptor(T, .optional_write);
}

pub fn With(comptime T: type) type {
    return AccessDescriptor(T, .with);
}

pub fn Exclude(comptime T: type) type {
    return AccessDescriptor(T, .exclude);
}

fn AccessDescriptor(comptime T: type, comptime mode: AccessMode) type {
    return struct {
        pub const Component = T;
        pub const access_mode = mode;
    };
}

pub fn Query(comptime Components: anytype, comptime Accesses: anytype) type {
    const Registry = component_registry_mod.ComponentRegistry(Components);
    const Key = archetype_key_mod.ArchetypeKey(Components);

    comptime validateAccesses(Registry, Accesses);

    return struct {
        pub fn matches(key: Key) bool {
            return queryMatches(Registry, key, Accesses);
        }

        pub fn modeOf(comptime T: type) ?AccessMode {
            return accessModeOf(Accesses, T);
        }

        pub fn allowsRead(comptime T: type) bool {
            return switch (modeOf(T) orelse return false) {
                .read, .write => true,
                else => false,
            };
        }

        pub fn allowsWrite(comptime T: type) bool {
            return switch (modeOf(T) orelse return false) {
                .write => true,
                else => false,
            };
        }

        pub fn allowsOptionalRead(comptime T: type) bool {
            return switch (modeOf(T) orelse return false) {
                .optional_read, .optional_write => true,
                else => false,
            };
        }

        pub fn allowsOptionalWrite(comptime T: type) bool {
            return switch (modeOf(T) orelse return false) {
                .optional_write => true,
                else => false,
            };
        }

        pub fn requiresPresence(comptime T: type) bool {
            return switch (modeOf(T) orelse return false) {
                .read, .write, .with => true,
                else => false,
            };
        }

        pub fn excludes(comptime T: type) bool {
            return switch (modeOf(T) orelse return false) {
                .exclude => true,
                else => false,
            };
        }
    };
}

fn accessFields(comptime Accesses: anytype) []const std.builtin.Type.StructField {
    const info = @typeInfo(@TypeOf(Accesses));
    switch (info) {
        .@"struct" => |struct_info| {
            if (!struct_info.is_tuple) {
                @compileError("Query access descriptors must be passed as a comptime tuple.");
            }
            return struct_info.fields;
        },
        else => @compileError("Query access descriptors must be passed as a comptime tuple."),
    }
}

fn validateAccesses(comptime Registry: type, comptime Accesses: anytype) void {
    const fields = accessFields(Accesses);

    inline for (fields, 0..) |field_i, index_i| {
        const descriptor = @field(Accesses, field_i.name);
        if (@TypeOf(descriptor) != type) {
            @compileError("Query access descriptors must be descriptor types.");
        }
        validateDescriptorShape(descriptor);

        const component = descriptor.Component;
        const mode = descriptor.access_mode;
        if (!Registry.contains(component)) {
            @compileError("Query access descriptors must come from the component universe.");
        }
        if (@sizeOf(component) == 0) {
            switch (mode) {
                .read, .write, .optional_read, .optional_write => {
                    @compileError("Zero-sized tag components must use With/Exclude instead of column access.");
                },
                else => {},
            }
        }

        inline for (fields[0..index_i]) |field_j| {
            const other_descriptor = @field(Accesses, field_j.name);
            validateDescriptorShape(other_descriptor);
            if (other_descriptor.Component == component) {
                @compileError("Query access descriptors must not repeat the same component.");
            }
        }
    }
}

fn validateDescriptorShape(comptime Descriptor: type) void {
    if (!@hasDecl(Descriptor, "Component")) {
        @compileError("Query access descriptor is missing Component.");
    }
    if (!@hasDecl(Descriptor, "access_mode")) {
        @compileError("Query access descriptor is missing access_mode.");
    }
    if (@TypeOf(Descriptor.Component) != type) {
        @compileError("Query access descriptor Component must be a type.");
    }
    if (@TypeOf(Descriptor.access_mode) != AccessMode) {
        @compileError("Query access descriptor access_mode must be an AccessMode.");
    }
}

fn queryMatches(comptime Registry: type, key: anytype, comptime Accesses: anytype) bool {
    const fields = accessFields(Accesses);
    inline for (fields) |field| {
        const descriptor = @field(Accesses, field.name);
        const component_id = Registry.typeId(descriptor.Component).?;
        const contains = key.containsId(component_id);
        switch (descriptor.access_mode) {
            .read, .write, .with => if (!contains) return false,
            .optional_read, .optional_write => {},
            .exclude => if (contains) return false,
        }
    }
    return true;
}

fn accessModeOf(comptime Accesses: anytype, comptime T: type) ?AccessMode {
    const fields = accessFields(Accesses);
    inline for (fields) |field| {
        const descriptor = @field(Accesses, field.name);
        if (descriptor.Component == T) return descriptor.access_mode;
    }
    return null;
}

test "query matches required optional with and exclude semantics" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Health = struct { value: i32 };
    const Tag = struct {};
    const Sleeping = struct {};
    const Key = archetype_key_mod.ArchetypeKey(.{ Position, Velocity, Health, Tag, Sleeping });
    const TestQuery = Query(
        .{ Position, Velocity, Health, Tag, Sleeping },
        .{
            Write(Position),
            Read(Velocity),
            OptionalRead(Health),
            With(Tag),
            Exclude(Sleeping),
        },
    );

    const matching = Key.fromTypes(.{ Position, Velocity, Health, Tag });
    const missing_tag = Key.fromTypes(.{ Position, Velocity, Health });
    const excluded = Key.fromTypes(.{ Position, Velocity, Tag, Sleeping });

    try testing.expect(TestQuery.matches(matching));
    try testing.expect(!TestQuery.matches(missing_tag));
    try testing.expect(!TestQuery.matches(excluded));
    try testing.expect(TestQuery.allowsWrite(Position));
    try testing.expect(TestQuery.allowsRead(Velocity));
    try testing.expect(TestQuery.allowsOptionalRead(Health));
    try testing.expect(TestQuery.requiresPresence(Tag));
    try testing.expect(TestQuery.excludes(Sleeping));
}
