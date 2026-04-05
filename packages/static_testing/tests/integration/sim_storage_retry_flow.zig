const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const network = static_testing.testing.sim.network_link;
const retry_mod = static_testing.testing.sim.retry_queue;
const storage_mod = static_testing.testing.sim.storage_lane;
const temporal = static_testing.testing.temporal;

test "simulated network storage and retry flow composes deterministically" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 32) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(888),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 32 },
    });
    defer sim_fixture.deinit();

    var network_storage: [4]network.Delivery(u32) = undefined;
    var link = try network.NetworkLink(u32).init(&network_storage, .{
        .default_delay = .init(1),
    });
    var storage_pending: [4]storage_mod.PendingCompletion(u32) = undefined;
    var storage_lane = try storage_mod.StorageLane(u32).init(&storage_pending, .{
        .default_delay = .init(1),
    });
    var retry_pending: [4]retry_mod.PendingRetry(u32) = undefined;
    var retry_queue = try retry_mod.RetryQueue(u32).init(&retry_pending, .{
        .backoff = .init(1),
        .max_attempts = 2,
    });

    var request_mailbox = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 4 },
    );
    defer request_mailbox.deinit();
    var completion_mailbox = try static_testing.testing.sim.mailbox.Mailbox(
        storage_mod.OperationResult(u32),
    ).init(testing.allocator, .{ .capacity = 4 });
    defer completion_mailbox.deinit();
    var retry_mailbox = try static_testing.testing.sim.mailbox.Mailbox(
        retry_mod.RetryEnvelope(u32),
    ).init(testing.allocator, .{ .capacity = 4 });
    defer retry_mailbox.deinit();

    try link.send(sim_fixture.sim_clock.now(), 1, 11, 41);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 11, &request_mailbox, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 41), try request_mailbox.recv());

    try storage_lane.submitFailure(sim_fixture.sim_clock.now(), 41, 500);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try storage_lane.deliverDueToMailbox(sim_fixture.sim_clock.now(), &completion_mailbox, sim_fixture.traceBufferPtr());
    const failure = try completion_mailbox.recv();
    try testing.expectEqual(storage_mod.CompletionStatus.failed, failure.status);

    try testing.expectEqual(
        retry_mod.RetryDecision.queued,
        try retry_queue.scheduleNext(sim_fixture.sim_clock.now(), 0, failure.request_id, failure.request_id),
    );
    _ = try sim_fixture.sim_clock.advance(.init(1));
    try testing.expectEqual(@as(u32, 1), try retry_queue.emitDueToMailbox(
        sim_fixture.sim_clock.now(),
        &retry_mailbox,
        sim_fixture.traceBufferPtr(),
    ));
    const retry = try retry_mailbox.recv();
    try testing.expectEqual(@as(u32, 1), retry.attempt);

    try link.send(sim_fixture.sim_clock.now(), 1, 11, retry.payload);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 11, &request_mailbox, sim_fixture.traceBufferPtr());
    try testing.expectEqual(@as(u32, 41), try request_mailbox.recv());

    try storage_lane.submitSuccess(sim_fixture.sim_clock.now(), 41, 200);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try storage_lane.deliverDueToMailbox(sim_fixture.sim_clock.now(), &completion_mailbox, sim_fixture.traceBufferPtr());
    const success = try completion_mailbox.recv();
    try testing.expectEqual(storage_mod.CompletionStatus.success, success.status);
    try testing.expectEqual(@as(u32, 200), success.value);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const retry_before_success = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "retry_queue.emit", .surface_label = "retry_queue" },
        .{ .label = "storage_lane.success", .surface_label = "storage_lane" },
    );
    try testing.expect(retry_before_success.check_result.passed);
}
