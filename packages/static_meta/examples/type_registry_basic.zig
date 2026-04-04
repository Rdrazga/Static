const std = @import("std");
const meta = @import("static_meta");

const Position = struct {
    pub const static_name: []const u8 = "demo/position";
    pub const static_version: u32 = 1;

    x: f32,
    y: f32,
};

const Velocity = struct {
    pub const static_name: []const u8 = "demo/velocity";
    pub const static_version: u32 = 1;

    x: f32,
    y: f32,
};

pub fn main() !void {
    var storage: [8]meta.Entry = undefined;
    var registry = try meta.TypeRegistry.init(storage[0..]);

    try registry.registerType(Position);
    try registry.registerType(Velocity);

    const entries = registry.list();
    std.debug.print("registry len: {d}\n", .{entries.len});
    for (entries) |entry| {
        std.debug.print("id={d} runtime={s}", .{
            entry.type_id,
            entry.runtime_name,
        });
        if (entry.stable_name) |stable_name| {
            std.debug.print(" stable={s}@{d}\n", .{
                stable_name,
                entry.stable_version.?,
            });
        } else {
            std.debug.print(" stable=<none>\n", .{});
        }
    }
}
