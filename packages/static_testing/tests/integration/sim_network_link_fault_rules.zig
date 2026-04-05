const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const network = static_testing.testing.sim.network_link;
const temporal = static_testing.testing.temporal;

test "network link fault rules support asymmetric drops and targeted delay under fixture tracing" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 16) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(901),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 16 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [4]network.Delivery(u32) = undefined;
    const fault_rules = [_]network.FaultRule{
        .{
            .route = .{
                .source_id = 7,
                .destination_id = 11,
            },
            .effect = .{ .drop = {} },
        },
        .{
            .route = .{
                .destination_id = 13,
            },
            .effect = .{ .add_delay = .init(2) },
        },
    };
    var link = try network.NetworkLink(u32).init(&pending_storage, .{
        .default_delay = .init(1),
        .fault_rules = &fault_rules,
    });

    var mailbox_7 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_7.deinit();
    var mailbox_11 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_11.deinit();
    var mailbox_13 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_13.deinit();

    try link.send(sim_fixture.sim_clock.now(), 7, 11, 99);
    try link.send(sim_fixture.sim_clock.now(), 11, 7, 42);
    try link.send(sim_fixture.sim_clock.now(), 1, 13, 77);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 11, &mailbox_11, sim_fixture.traceBufferPtr());
    const delivered_7 = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 7, &mailbox_7, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 1), delivered_7.delivered_count);
    try testing.expectEqual(@as(u32, 42), try mailbox_7.recv());

    const delayed_early = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 13, &mailbox_13, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 0), delayed_early.delivered_count);

    _ = try sim_fixture.sim_clock.advance(.init(2));
    const delivered_13 = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 13, &mailbox_13, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 1), delivered_13.delivered_count);
    try testing.expectEqual(@as(u32, 77), try mailbox_13.recv());

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const delivered_to_7 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 7,
        .surface_label = "network_link",
    });
    try testing.expect(delivered_to_7.check_result.passed);

    const delivered_to_13 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 13,
        .surface_label = "network_link",
    });
    try testing.expect(delivered_to_13.check_result.passed);

    const never_to_11 = try temporal.checkNever(snapshot, .{
        .label = "network_link.deliver",
        .value = 11,
        .surface_label = "network_link",
    });
    try testing.expect(never_to_11.check_result.passed);
}

test "network link isolate-node partitions block both inbound and outbound traffic while preserving other routes" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 16) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(902),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 16 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [4]network.Delivery(u32) = undefined;
    var link = try network.NetworkLink(u32).init(&pending_storage, .{
        .default_delay = .init(1),
        .partition_mode = .{ .isolate_node = 11 },
    });

    var mailbox_5 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_5.deinit();
    var mailbox_11 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_11.deinit();
    var mailbox_13 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_13.deinit();

    try link.send(sim_fixture.sim_clock.now(), 7, 11, 99);
    try link.send(sim_fixture.sim_clock.now(), 11, 5, 42);
    try link.send(sim_fixture.sim_clock.now(), 5, 13, 77);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const delivered_11 = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 11, &mailbox_11, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 0), delivered_11.delivered_count);
    const delivered_5 = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 5, &mailbox_5, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 0), delivered_5.delivered_count);
    const delivered_13 = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 13, &mailbox_13, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 1), delivered_13.delivered_count);
    try testing.expectEqual(@as(u32, 77), try mailbox_13.recv());

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const never_to_11 = try temporal.checkNever(snapshot, .{
        .label = "network_link.deliver",
        .value = 11,
        .surface_label = "network_link",
    });
    try testing.expect(never_to_11.check_result.passed);

    const never_to_5 = try temporal.checkNever(snapshot, .{
        .label = "network_link.deliver",
        .value = 5,
        .surface_label = "network_link",
    });
    try testing.expect(never_to_5.check_result.passed);

    const once_to_13 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 13,
        .surface_label = "network_link",
    });
    try testing.expect(once_to_13.check_result.passed);
}

test "network link group partitions support directed and bidirectional topology faults" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
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

    const left_group = [_]u32{ 1, 2 };
    const right_group = [_]u32{ 3, 4 };
    var pending_storage: [6]network.Delivery(u32) = undefined;
    var link = try network.NetworkLink(u32).init(&pending_storage, .{
        .default_delay = .init(1),
        .partition_mode = .{
            .partition_groups = .{
                .from_nodes = &left_group,
                .to_nodes = &right_group,
            },
        },
    });

    var mailbox_1 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_1.deinit();
    var mailbox_2 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_2.deinit();
    var mailbox_3 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_3.deinit();

    try link.send(sim_fixture.sim_clock.now(), 1, 3, 10);
    try link.send(sim_fixture.sim_clock.now(), 3, 1, 20);
    try link.send(sim_fixture.sim_clock.now(), 1, 2, 30);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const delivered_to_3_directed = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 3, &mailbox_3, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 0), delivered_to_3_directed.delivered_count);

    const delivered_to_1_directed = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 1, &mailbox_1, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 1), delivered_to_1_directed.delivered_count);
    try testing.expectEqual(@as(u32, 20), try mailbox_1.recv());

    const delivered_to_2_directed = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 2, &mailbox_2, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 1), delivered_to_2_directed.delivered_count);
    try testing.expectEqual(@as(u32, 30), try mailbox_2.recv());

    try link.setPartitionMode(.{
        .partition_groups = .{
            .from_nodes = &left_group,
            .to_nodes = &right_group,
            .bidirectional = true,
        },
    });
    try link.send(sim_fixture.sim_clock.now(), 2, 4, 40);
    try link.send(sim_fixture.sim_clock.now(), 4, 2, 50);
    try testing.expectEqual(@as(usize, 0), link.pendingItems().len);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const delivered_once_to_1 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 1,
        .surface_label = "network_link",
    });
    try testing.expect(delivered_once_to_1.check_result.passed);

    const delivered_once_to_2 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 2,
        .surface_label = "network_link",
    });
    try testing.expect(delivered_once_to_2.check_result.passed);

    const never_to_3 = try temporal.checkNever(snapshot, .{
        .label = "network_link.deliver",
        .value = 3,
        .surface_label = "network_link",
    });
    try testing.expect(never_to_3.check_result.passed);

    const never_to_4 = try temporal.checkNever(snapshot, .{
        .label = "network_link.deliver",
        .value = 4,
        .surface_label = "network_link",
    });
    try testing.expect(never_to_4.check_result.passed);
}

test "network link congestion windows hold matching deliveries until the route reopens" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 16) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(903),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 16 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [4]network.Delivery(u32) = undefined;
    const congestion_windows = [_]network.CongestionWindow{
        .{
            .route = .{ .destination_id = 13 },
            .active_from = .init(1),
            .active_until = .init(4),
        },
    };
    var link = try network.NetworkLink(u32).init(&pending_storage, .{
        .default_delay = .init(1),
        .congestion_windows = &congestion_windows,
    });

    var mailbox_13 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_13.deinit();

    try link.send(sim_fixture.sim_clock.now(), 1, 13, 77);

    _ = try sim_fixture.sim_clock.advance(.init(3));
    const still_blocked = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 13, &mailbox_13, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 0), still_blocked.delivered_count);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const delivered = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 13, &mailbox_13, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 1), delivered.delivered_count);
    try testing.expectEqual(@as(u32, 77), try mailbox_13.recv());

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const once_to_13 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 13,
        .surface_label = "network_link",
    });
    try testing.expect(once_to_13.check_result.passed);
}

test "network link backlog pressure can evict the oldest matching pending delivery" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(905),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    const backlog_policies = [_]network.BacklogPolicy{
        .{
            .route = .{ .destination_id = 13 },
            .max_pending = 1,
            .overflow = .drop_oldest,
        },
    };
    var pending_storage: [4]network.Delivery(u32) = undefined;
    var link = try network.NetworkLink(u32).init(&pending_storage, .{
        .default_delay = .init(1),
        .backlog_policies = &backlog_policies,
    });

    var mailbox_13 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_13.deinit();
    var mailbox_17 = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 2 },
    );
    defer mailbox_17.deinit();

    try link.send(sim_fixture.sim_clock.now(), 1, 13, 70);
    try link.send(sim_fixture.sim_clock.now(), 2, 13, 80);
    try link.send(sim_fixture.sim_clock.now(), 3, 17, 90);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const delivered_to_13 = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 13, &mailbox_13, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 1), delivered_to_13.delivered_count);
    try testing.expectEqual(@as(u32, 80), try mailbox_13.recv());

    const delivered_to_17 = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 17, &mailbox_17, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 1), delivered_to_17.delivered_count);
    try testing.expectEqual(@as(u32, 90), try mailbox_17.recv());

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const once_to_13 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 13,
        .surface_label = "network_link",
    });
    try testing.expect(once_to_13.check_result.passed);

    const once_to_17 = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 17,
        .surface_label = "network_link",
    });
    try testing.expect(once_to_17.check_result.passed);
}
