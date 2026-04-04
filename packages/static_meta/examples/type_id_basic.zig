const std = @import("std");
const meta = @import("static_meta");

const Position = struct {
    x: f32,
    y: f32,
};

pub fn main() !void {
    const id = meta.type_id.fromType(Position);
    const runtime_fp = meta.type_fingerprint.runtime64(Position);

    std.debug.print("type: {s}\n", .{@typeName(Position)});
    std.debug.print("type_id: {d}\n", .{id});
    std.debug.print("runtime_fingerprint64: {d}\n", .{runtime_fp});
}
