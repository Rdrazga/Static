const std = @import("std");
const q = @import("static_queues");

pub fn main() !void {
    var io = try q.inbox_outbox.InboxOutbox(u8).init(std.heap.page_allocator, .{
        .inbox_capacity = 4,
        .outbox_capacity = 4,
    });
    defer io.deinit();

    try io.trySend(1);
    _ = io.publish();
    _ = try io.tryRecv();
}
