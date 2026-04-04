const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    const left_group = [_]u32{ 1, 2 };
    const right_group = [_]u32{ 3, 4 };

    var pending_storage: [6]testing.testing.sim.network_link.Delivery(u32) = undefined;
    var link = try testing.testing.sim.network_link.NetworkLink(u32).init(&pending_storage, .{
        .default_delay = .init(1),
        .partition_mode = .{
            .partition_groups = .{
                .from_nodes = &left_group,
                .to_nodes = &right_group,
            },
        },
    });

    var mailbox_1 = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_1.deinit();
    var mailbox_2 = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_2.deinit();
    var mailbox_3 = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_3.deinit();

    try link.send(.init(0), 1, 3, 10);
    try link.send(.init(0), 3, 1, 20);
    try link.send(.init(0), 1, 2, 30);

    const to_3 = try link.deliverDueToMailbox(.init(1), 3, &mailbox_3, null);
    std.debug.assert(to_3.delivered_count == 0);

    const to_1 = try link.deliverDueToMailbox(.init(1), 1, &mailbox_1, null);
    std.debug.assert(to_1.delivered_count == 1);
    std.debug.assert(try mailbox_1.recv() == 20);

    const to_2 = try link.deliverDueToMailbox(.init(1), 2, &mailbox_2, null);
    std.debug.assert(to_2.delivered_count == 1);
    std.debug.assert(try mailbox_2.recv() == 30);

    try link.setPartitionMode(.{
        .partition_groups = .{
            .from_nodes = &left_group,
            .to_nodes = &right_group,
            .bidirectional = true,
        },
    });
    try link.send(.init(1), 2, 4, 40);
    try link.send(.init(1), 4, 2, 50);
    std.debug.assert(link.pendingItems().len == 0);

    std.debug.print(
        "network link directed group partitions block left->right traffic, and bidirectional mode blocks both cross-group directions\n",
        .{},
    );
}
