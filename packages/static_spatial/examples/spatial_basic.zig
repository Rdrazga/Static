const std = @import("std");
const spatial = @import("static_spatial");

pub fn main() !void {
    // AABB intersection test.
    const a = spatial.AABB3.init(0, 0, 0, 2, 2, 2);
    const b = spatial.AABB3.init(1, 1, 1, 3, 3, 3);
    const c = spatial.AABB3.init(5, 5, 5, 6, 6, 6);

    std.debug.print("a intersects b: {}\n", .{a.intersects(b)});
    std.debug.print("a intersects c: {}\n", .{a.intersects(c)});

    // Ray-AABB intersection.
    const ray = spatial.Ray3.init(-1.0, 1.0, 1.0, 1.0, 0.0, 0.0);
    if (ray.intersectsAABB(a)) |hit| {
        std.debug.print("ray hits a at t_min={d:.4}\n", .{hit.t_min});
    } else {
        std.debug.print("ray misses a\n", .{});
    }

    // Morton encoding.
    const code = spatial.encode2d(3, 5);
    const decoded = spatial.decode2d(code);
    std.debug.print("morton encode(3,5)={d}, decode back=({d},{d})\n", .{
        code, decoded.x, decoded.y,
    });
}
