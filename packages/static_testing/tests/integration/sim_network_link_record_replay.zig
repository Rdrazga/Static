const std = @import("std");
const static_testing = @import("static_testing");

const network = static_testing.testing.sim.network_link;
const temporal = static_testing.testing.temporal;

test "network link can snapshot effective pending deliveries and replay them deterministically" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(904),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    var source_storage: [4]network.Delivery(u32) = undefined;
    const fault_rules = [_]network.FaultRule{
        .{
            .route = .{ .destination_id = 13 },
            .effect = .{ .add_delay = .init(2) },
        },
        .{
            .route = .{
                .source_id = 5,
                .destination_id = 17,
            },
            .effect = .{ .drop = {} },
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

    try source_link.send(sim_fixture.sim_clock.now(), 1, 13, 130);
    try source_link.send(sim_fixture.sim_clock.now(), 2, 19, 190);
    try source_link.send(sim_fixture.sim_clock.now(), 5, 17, 170);

    var recorded_storage: [4]network.Delivery(u32) = undefined;
    const recorded = try source_link.recordPending(&recorded_storage);
    try std.testing.expectEqual(@as(usize, 2), recorded.len);
    try std.testing.expectEqual(@as(u64, 3), recorded[0].due_time.tick);
    try std.testing.expectEqual(@as(u64, 4), recorded[1].due_time.tick);

    var replay_storage: [4]network.Delivery(u32) = undefined;
    var replay_link = try network.NetworkLink(u32).init(&replay_storage, .{
        .default_delay = .init(9),
    });
    try replay_link.replayRecordedPending(recorded);

    var mailbox_13 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        std.testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_13.deinit();
    var mailbox_19 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        std.testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_19.deinit();

    _ = try sim_fixture.sim_clock.advance(.init(3));
    const delivered_13 = try replay_link.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        13,
        &mailbox_13,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 1), delivered_13.delivered_count);
    try std.testing.expectEqual(@as(u32, 130), try mailbox_13.recv());

    const early_19 = try replay_link.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        19,
        &mailbox_19,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 0), early_19.delivered_count);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const delivered_19 = try replay_link.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        19,
        &mailbox_19,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 1), delivered_19.delivered_count);
    try std.testing.expectEqual(@as(u32, 190), try mailbox_19.recv());

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const once_to_13 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 13,
        .surface_label = "network_link",
    });
    try std.testing.expect(once_to_13.check_result.passed);

    const once_to_19 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 19,
        .surface_label = "network_link",
    });
    try std.testing.expect(once_to_19.check_result.passed);
}
