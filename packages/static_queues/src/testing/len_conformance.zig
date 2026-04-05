const std = @import("std");
const testing = std.testing;

pub fn runLenConformance(comptime Q: type, allocator: std.mem.Allocator, capacity: usize) !void {
    var queue = try Q.init(allocator, .{ .capacity = capacity });
    defer queue.deinit();

    try testing.expect(queue.len() <= queue.capacity());

    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        try queue.trySend(@as(Q.Element, @intCast(i)));
        const queue_len = queue.len();
        try testing.expect(queue_len <= queue.capacity());
    }

    while (true) {
        _ = queue.tryRecv() catch |err| switch (err) {
            error.WouldBlock => break,
        };
        const queue_len = queue.len();
        try testing.expect(queue_len <= queue.capacity());
    }
}
