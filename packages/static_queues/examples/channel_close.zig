const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var channel = try q.channel.Channel(u8).init(std.heap.page_allocator, .{ .capacity = 1 });
    defer channel.deinit();

    channel.close();
    _ = channel.trySend(1) catch |err| switch (err) {
        error.Closed => return,
        else => return err,
    };
    return error.UnexpectedSuccess;
}
