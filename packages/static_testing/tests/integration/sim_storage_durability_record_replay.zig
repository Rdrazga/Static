const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const durability = static_testing.testing.sim.storage_durability;
const temporal = static_testing.testing.temporal;

test "storage durability can snapshot pending operations and stored state for deterministic replay" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(656),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    var source_pending_storage: [6]durability.PendingOperation(u32) = undefined;
    var source_stored_storage: [4]durability.StoredValue(u32) = undefined;
    var source = try durability.StorageDurability(u32).init(&source_pending_storage, &source_stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 700 },
        .read_corruption = .{ .fixed_value = 900 },
    });
    var completions = try static_testing.testing.sim.mailbox.Mailbox(
        durability.OperationResult(u32),
    ).init(testing.allocator, .{ .capacity = 6 });
    defer completions.deinit();

    try source.submitWrite(sim_fixture.sim_clock.now(), 1, 4, 111);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try source.deliverDueToMailbox(sim_fixture.sim_clock.now(), &completions, sim_fixture.traceBufferPtr());
    const pre_replay_fault_write = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.corrupted, pre_replay_fault_write.status);
    try testing.expectEqual(@as(u32, 700), pre_replay_fault_write.value.?);

    _ = try source.crash(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());
    try source.recover(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());

    try source.submitWrite(sim_fixture.sim_clock.now(), 2, 8, 222);
    try source.submitRead(sim_fixture.sim_clock.now(), 3, 4);

    var recorded_pending: [6]durability.PendingOperation(u32) = undefined;
    var recorded_stored: [4]durability.StoredValue(u32) = undefined;
    const recorded = try source.recordState(&recorded_pending, &recorded_stored);
    try testing.expectEqual(@as(usize, 2), recorded.pending.len);
    try testing.expectEqual(@as(usize, 1), recorded.stored.len);
    try testing.expect(recorded.stabilized_after_recover);

    var replay_pending_storage: [6]durability.PendingOperation(u32) = undefined;
    var replay_stored_storage: [4]durability.StoredValue(u32) = undefined;
    var replay = try durability.StorageDurability(u32).init(&replay_pending_storage, &replay_stored_storage, .{
        .write_delay = .init(9),
        .read_delay = .init(9),
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 1_700 },
        .read_corruption = .{ .fixed_value = 1_900 },
    });
    try replay.replayRecordedState(recorded);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const replay_summary = try replay.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), replay_summary.write_success_count);
    try testing.expectEqual(@as(u32, 1), replay_summary.read_success_count);

    const replay_write = try completions.recv();
    try testing.expectEqual(durability.OperationKind.write, replay_write.kind);
    try testing.expectEqual(durability.CompletionStatus.success, replay_write.status);
    try testing.expectEqual(@as(u32, 222), replay_write.value.?);

    const replay_read = try completions.recv();
    try testing.expectEqual(durability.OperationKind.read, replay_read.kind);
    try testing.expectEqual(durability.CompletionStatus.success, replay_read.status);
    try testing.expectEqual(@as(u32, 700), replay_read.value.?);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const recover_before_replay_write = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.write.success", .surface_label = "storage_durability" },
    );
    try testing.expect(recover_before_replay_write.check_result.passed);

    const replay_write_before_replay_read = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.write.success", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.read.success", .surface_label = "storage_durability" },
    );
    try testing.expect(replay_write_before_replay_read.check_result.passed);
}
