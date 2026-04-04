const std = @import("std");
const testing = @import("static_testing");

const network = testing.testing.sim.network_link;
const retry_mod = testing.testing.sim.retry_queue;
const storage_mod = testing.testing.sim.storage_lane;
const temporal = testing.testing.temporal;

pub fn main() !void {
    var sim_fixture: testing.testing.sim.fixture.Fixture(4, 4, 4, 32) = undefined;
    try sim_fixture.init(.{
        .allocator = std.heap.page_allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(777),
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

    var request_mailbox = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 4 },
    );
    defer request_mailbox.deinit();
    var completion_mailbox = try testing.testing.sim.mailbox.Mailbox(
        storage_mod.OperationResult(u32),
    ).init(std.heap.page_allocator, .{ .capacity = 4 });
    defer completion_mailbox.deinit();
    var retry_mailbox = try testing.testing.sim.mailbox.Mailbox(
        retry_mod.RetryEnvelope(u32),
    ).init(std.heap.page_allocator, .{ .capacity = 4 });
    defer retry_mailbox.deinit();

    try link.send(sim_fixture.sim_clock.now(), 1, 11, 41);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 11, &request_mailbox, sim_fixture.traceBufferPtr());
    std.debug.assert(try request_mailbox.recv() == 41);

    try storage_lane.submitFailure(sim_fixture.sim_clock.now(), 41, 500);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try storage_lane.deliverDueToMailbox(sim_fixture.sim_clock.now(), &completion_mailbox, sim_fixture.traceBufferPtr());
    const failed = try completion_mailbox.recv();
    std.debug.assert(failed.status == .failed);

    const retry_decision = try retry_queue.scheduleNext(sim_fixture.sim_clock.now(), 0, failed.request_id, failed.request_id);
    std.debug.assert(retry_decision == .queued);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    std.debug.assert(try retry_queue.emitDueToMailbox(sim_fixture.sim_clock.now(), &retry_mailbox, sim_fixture.traceBufferPtr()) == 1);
    const retry = try retry_mailbox.recv();
    std.debug.assert(retry.attempt == 1);

    try link.send(sim_fixture.sim_clock.now(), 1, 11, retry.payload);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try link.deliverDueToMailbox(sim_fixture.sim_clock.now(), 11, &request_mailbox, sim_fixture.traceBufferPtr());
    std.debug.assert(try request_mailbox.recv() == 41);

    try storage_lane.submitSuccess(sim_fixture.sim_clock.now(), 41, 200);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try storage_lane.deliverDueToMailbox(sim_fixture.sim_clock.now(), &completion_mailbox, sim_fixture.traceBufferPtr());
    const success = try completion_mailbox.recv();
    std.debug.assert(success.status == .success);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const retry_before_success = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "retry_queue.emit", .surface_label = "retry_queue" },
        .{ .label = "storage_lane.success", .surface_label = "storage_lane" },
    );
    std.debug.assert(retry_before_success.check_result.passed);

    std.debug.print("composed flow reached storage success after one retry\n", .{});
}
