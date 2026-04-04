const std = @import("std");
const testing = @import("static_testing");

const temporal = testing.testing.temporal;

pub fn main() !void {
    var sim_fixture: testing.testing.sim.fixture.Fixture(4, 4, 4, 16) = undefined;
    try sim_fixture.init(.{
        .allocator = std.heap.page_allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(123),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 16 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [4]testing.testing.sim.network_link.Delivery(u32) = undefined;
    const fault_rules = [_]testing.testing.sim.network_link.FaultRule{
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
    const congestion_windows = [_]testing.testing.sim.network_link.CongestionWindow{
        .{
            .route = .{
                .destination_id = 17,
            },
            .active_from = .init(1),
            .active_until = .init(4),
        },
    };
    var link = try testing.testing.sim.network_link.NetworkLink(u32).init(&pending_storage, .{
        .default_delay = .init(1),
        .fault_rules = &fault_rules,
        .congestion_windows = &congestion_windows,
    });
    var receiver = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 4 },
    );
    defer receiver.deinit();

    try link.send(sim_fixture.sim_clock.now(), 7, 11, 99);
    try link.send(sim_fixture.sim_clock.now(), 11, 7, 42);
    try link.send(sim_fixture.sim_clock.now(), 1, 13, 77);
    try link.send(sim_fixture.sim_clock.now(), 2, 17, 123);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const delivered = try link.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        7,
        &receiver,
        sim_fixture.traceBufferPtr(),
    );
    std.debug.assert(delivered.delivered_count == 1);
    std.debug.assert(try receiver.recv() == 42);

    const delayed_early = try link.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        13,
        &receiver,
        sim_fixture.traceBufferPtr(),
    );
    std.debug.assert(delayed_early.delivered_count == 0);

    _ = try sim_fixture.sim_clock.advance(.init(2));
    const delayed = try link.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        13,
        &receiver,
        sim_fixture.traceBufferPtr(),
    );
    std.debug.assert(delayed.delivered_count == 1);
    std.debug.assert(try receiver.recv() == 77);

    const congested_early = try link.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        17,
        &receiver,
        sim_fixture.traceBufferPtr(),
    );
    std.debug.assert(congested_early.delivered_count == 0);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const congested_released = try link.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        17,
        &receiver,
        sim_fixture.traceBufferPtr(),
    );
    std.debug.assert(congested_released.delivered_count == 1);
    std.debug.assert(try receiver.recv() == 123);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const delivered_once = try temporal.checkExactlyOnce(snapshot, .{
        .label = "network_link.deliver",
        .value = 7,
        .surface_label = "network_link",
    });
    std.debug.assert(delivered_once.check_result.passed);

    std.debug.print(
        "network link kept 7->11 partitioned, delivered 11->7 immediately, delayed destination=13, and held destination=17 behind a congestion window\n",
        .{},
    );
}
