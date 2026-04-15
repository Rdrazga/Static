const std = @import("std");
const static_io = @import("static_io");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try static_io.BufferPool.init(allocator, .{
        .buffer_size = 32,
        .capacity = 1,
    });
    defer pool.deinit();

    const first = try pool.acquire();
    defer pool.release(first) catch unreachable;

    _ = pool.acquire() catch |err| switch (err) {
        error.NoSpaceLeft => {
            std.debug.print("pool exhaustion path observed: NoSpaceLeft\n", .{});
            return;
        },
    };
    return error.UnexpectedAcquireSuccess;
}
