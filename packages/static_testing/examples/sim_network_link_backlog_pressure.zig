const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    const backlog_policies = [_]testing.testing.sim.network_link.BacklogPolicy{
        .{
            .route = .{ .destination_id = 13 },
            .max_pending = 1,
            .overflow = .drop_oldest,
        },
    };

    var pending_storage: [4]testing.testing.sim.network_link.Delivery(u32) = undefined;
    var link = try testing.testing.sim.network_link.NetworkLink(u32).init(&pending_storage, .{
        .default_delay = .init(1),
        .backlog_policies = &backlog_policies,
    });

    var mailbox_13 = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_13.deinit();
    var mailbox_17 = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_17.deinit();

    try link.send(.init(0), 1, 13, 70);
    try link.send(.init(0), 2, 13, 80);
    try link.send(.init(0), 3, 17, 90);

    const to_13 = try link.deliverDueToMailbox(.init(1), 13, &mailbox_13, null);
    std.debug.assert(to_13.delivered_count == 1);
    std.debug.assert(try mailbox_13.recv() == 80);

    const to_17 = try link.deliverDueToMailbox(.init(1), 17, &mailbox_17, null);
    std.debug.assert(to_17.delivered_count == 1);
    std.debug.assert(try mailbox_17.recv() == 90);

    std.debug.print(
        "network link backlog pressure evicted the oldest destination=13 delivery and preserved the unrelated route\n",
        .{},
    );
}
