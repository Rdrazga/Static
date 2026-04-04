const std = @import("std");
const testing = @import("static_testing");

const network = testing.testing.sim.network_link;

pub fn main() !void {
    var source_storage: [4]network.Delivery(u32) = undefined;
    const fault_rules = [_]network.FaultRule{
        .{
            .route = .{ .destination_id = 13 },
            .effect = .{ .add_delay = .init(2) },
        },
    };
    const congestion_windows = [_]network.CongestionWindow{
        .{
            .route = .{ .destination_id = 19 },
            .active_from = .init(1),
            .active_until = .init(4),
        },
    };
    var source_link = try network.NetworkLink(u32).init(&source_storage, .{
        .default_delay = .init(1),
        .fault_rules = &fault_rules,
        .congestion_windows = &congestion_windows,
    });

    try source_link.send(.init(0), 1, 13, 130);
    try source_link.send(.init(0), 2, 19, 190);

    var recorded_storage: [4]network.Delivery(u32) = undefined;
    const recorded = try source_link.recordPending(&recorded_storage);

    var replay_storage: [4]network.Delivery(u32) = undefined;
    var replay_link = try network.NetworkLink(u32).init(&replay_storage, .{
        .default_delay = .init(9),
        .partition_mode = .drop_all,
    });
    try replay_link.replayRecordedPending(recorded);

    var mailbox_13 = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_13.deinit();
    var mailbox_19 = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_19.deinit();

    std.debug.assert((try replay_link.deliverDueToMailbox(.init(3), 13, &mailbox_13, null)).delivered_count == 1);
    std.debug.assert(try mailbox_13.recv() == 130);
    std.debug.assert((try replay_link.deliverDueToMailbox(.init(3), 19, &mailbox_19, null)).delivered_count == 0);
    std.debug.assert((try replay_link.deliverDueToMailbox(.init(4), 19, &mailbox_19, null)).delivered_count == 1);
    std.debug.assert(try mailbox_19.recv() == 190);

    std.debug.print(
        "network link replay restored {d} retained deliveries with due ticks {d} and {d}\n",
        .{ recorded.len, recorded[0].due_time.tick, recorded[1].due_time.tick },
    );
}
