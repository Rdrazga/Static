const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const durability = static_testing.testing.sim.storage_durability;
const temporal = static_testing.testing.temporal;

test "storage durability traces crash recovery and bounded corruption outcomes under fixture tracing" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(654),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [6]durability.PendingOperation(u32) = undefined;
    var stored_storage: [4]durability.StoredValue(u32) = undefined;
    var simulator = try durability.StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(2),
        .read_delay = .init(1),
        .crash_behavior = .drop_pending_writes,
        .write_corruption = .{ .fixed_value = 700 },
        .read_corruption = .{ .fixed_value = 900 },
    });

    var completions = try static_testing.testing.sim.mailbox.Mailbox(
        durability.OperationResult(u32),
    ).init(testing.allocator, .{ .capacity = 6 });
    defer completions.deinit();

    try simulator.submitWrite(sim_fixture.sim_clock.now(), 1, 4, 111);
    try testing.expectEqual(@as(u32, 1), try simulator.crash(
        sim_fixture.sim_clock.now(),
        sim_fixture.traceBufferPtr(),
    ));
    try testing.expect(simulator.isCrashed());
    try testing.expectEqual(@as(usize, 0), simulator.pendingItems().len);

    try simulator.recover(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());
    try testing.expect(!simulator.isCrashed());

    try simulator.submitRead(sim_fixture.sim_clock.now(), 2, 4);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const missing_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), missing_summary.missing_count);
    const missing = try completions.recv();
    try testing.expectEqual(durability.OperationKind.read, missing.kind);
    try testing.expectEqual(durability.CompletionStatus.missing, missing.status);
    try testing.expect(missing.value == null);

    try simulator.submitWrite(sim_fixture.sim_clock.now(), 3, 4, 222);
    _ = try sim_fixture.sim_clock.advance(.init(2));
    const write_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), write_summary.corrupted_count);
    const write = try completions.recv();
    try testing.expectEqual(durability.OperationKind.write, write.kind);
    try testing.expectEqual(durability.CompletionStatus.corrupted, write.status);
    try testing.expectEqual(@as(u32, 700), write.value.?);
    try testing.expectEqual(@as(usize, 1), simulator.storedItems().len);
    try testing.expectEqual(@as(u32, 700), simulator.storedItems()[0].value);

    try simulator.submitRead(sim_fixture.sim_clock.now(), 4, 4);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const read_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), read_summary.corrupted_count);
    const read = try completions.recv();
    try testing.expectEqual(durability.OperationKind.read, read.kind);
    try testing.expectEqual(durability.CompletionStatus.corrupted, read.status);
    try testing.expectEqual(@as(u32, 900), read.value.?);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const crash_before_recover = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.crash", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
    );
    try testing.expect(crash_before_recover.check_result.passed);

    const recover_before_missing = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.read.missing", .surface_label = "storage_durability" },
    );
    try testing.expect(recover_before_missing.check_result.passed);

    const missing_before_write = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.read.missing", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.write.corrupted", .surface_label = "storage_durability" },
    );
    try testing.expect(missing_before_write.check_result.passed);

    const write_before_read = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.write.corrupted", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.read.corrupted", .surface_label = "storage_durability" },
    );
    try testing.expect(write_before_read.check_result.passed);
}

test "storage durability can stabilize post-recover repair reads and writes under fixture tracing" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(655),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [6]durability.PendingOperation(u32) = undefined;
    var stored_storage: [4]durability.StoredValue(u32) = undefined;
    var simulator = try durability.StorageDurability(u32).init(&pending_storage, &stored_storage, .{
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

    try simulator.submitWrite(sim_fixture.sim_clock.now(), 1, 4, 111);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    const pre_crash = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.corrupted, pre_crash.status);
    try testing.expectEqual(@as(u32, 700), pre_crash.value.?);

    _ = try simulator.crash(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());
    try simulator.recover(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());

    try simulator.submitWrite(sim_fixture.sim_clock.now(), 2, 4, 222);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    const repair_write = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.success, repair_write.status);
    try testing.expectEqual(@as(u32, 222), repair_write.value.?);

    try simulator.submitRead(sim_fixture.sim_clock.now(), 3, 4);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    const repair_read = try completions.recv();
    try testing.expectEqual(durability.OperationKind.read, repair_read.kind);
    try testing.expectEqual(durability.CompletionStatus.success, repair_read.status);
    try testing.expectEqual(@as(u32, 222), repair_read.value.?);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const corrupted_before_recover = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.write.corrupted", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
    );
    try testing.expect(corrupted_before_recover.check_result.passed);

    const recover_before_repair_write = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.write.success", .surface_label = "storage_durability" },
    );
    try testing.expect(recover_before_repair_write.check_result.passed);

    const repair_write_before_read = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.write.success", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.read.success", .surface_label = "storage_durability" },
    );
    try testing.expect(repair_write_before_read.check_result.passed);
}

test "storage durability misdirected writes stay bounded and repair writes restabilize after recover" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(657),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [8]durability.PendingOperation(u32) = undefined;
    var stored_storage: [4]durability.StoredValue(u32) = undefined;
    var simulator = try durability.StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_placement = .{ .fixed_slot = 9 },
    });
    var completions = try static_testing.testing.sim.mailbox.Mailbox(
        durability.OperationResult(u32),
    ).init(testing.allocator, .{ .capacity = 8 });
    defer completions.deinit();

    try simulator.submitWrite(sim_fixture.sim_clock.now(), 1, 4, 111);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const fault_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), fault_summary.corrupted_count);
    const fault_write = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.corrupted, fault_write.status);
    try testing.expectEqual(@as(u32, 111), fault_write.value.?);
    try testing.expectEqual(@as(usize, 1), simulator.storedItems().len);
    try testing.expectEqual(@as(u32, 9), simulator.storedItems()[0].slot_id);

    try simulator.submitRead(sim_fixture.sim_clock.now(), 2, 4);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const missing_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), missing_summary.missing_count);
    try testing.expectEqual(durability.CompletionStatus.missing, (try completions.recv()).status);

    try simulator.submitRead(sim_fixture.sim_clock.now(), 3, 9);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const redirected_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), redirected_summary.read_success_count);
    const redirected_read = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.success, redirected_read.status);
    try testing.expectEqual(@as(u32, 111), redirected_read.value.?);

    _ = try simulator.crash(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());
    try simulator.recover(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());
    try simulator.submitWrite(sim_fixture.sim_clock.now(), 4, 4, 222);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const repair_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), repair_summary.write_success_count);
    const repair_write = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.success, repair_write.status);
    try testing.expectEqual(@as(u32, 222), repair_write.value.?);

    try simulator.submitRead(sim_fixture.sim_clock.now(), 5, 4);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const repair_read_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), repair_read_summary.read_success_count);
    const repair_read = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.success, repair_read.status);
    try testing.expectEqual(@as(u32, 222), repair_read.value.?);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const missing_before_redirected = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.read.missing", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.read.success", .surface_label = "storage_durability", .value = 9 },
    );
    try testing.expect(missing_before_redirected.check_result.passed);

    const recover_before_repair_write = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.write.success", .surface_label = "storage_durability", .value = 4 },
    );
    try testing.expect(recover_before_repair_write.check_result.passed);
}

test "storage durability can acknowledge non-durable writes before recovery and restabilize after recover" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(658),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [8]durability.PendingOperation(u32) = undefined;
    var stored_storage: [4]durability.StoredValue(u32) = undefined;
    var simulator = try durability.StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_persistence = .acknowledge_without_store,
    });
    var completions = try static_testing.testing.sim.mailbox.Mailbox(
        durability.OperationResult(u32),
    ).init(testing.allocator, .{ .capacity = 8 });
    defer completions.deinit();

    try simulator.submitWrite(sim_fixture.sim_clock.now(), 1, 4, 111);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const omission_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), omission_summary.write_success_count);
    const omitted_write = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.success, omitted_write.status);
    try testing.expectEqual(@as(usize, 0), simulator.storedItems().len);

    try simulator.submitRead(sim_fixture.sim_clock.now(), 2, 4);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const missing_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), missing_summary.missing_count);
    try testing.expectEqual(durability.CompletionStatus.missing, (try completions.recv()).status);

    _ = try simulator.crash(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());
    try simulator.recover(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());
    try simulator.submitWrite(sim_fixture.sim_clock.now(), 3, 8, 222);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const repair_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), repair_summary.write_success_count);
    const repair_write = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.success, repair_write.status);
    try testing.expectEqual(@as(u32, 222), repair_write.value.?);

    try simulator.submitRead(sim_fixture.sim_clock.now(), 4, 8);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const repair_read_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    try testing.expectEqual(@as(u32, 1), repair_read_summary.read_success_count);
    const repair_read = try completions.recv();
    try testing.expectEqual(durability.CompletionStatus.success, repair_read.status);
    try testing.expectEqual(@as(u32, 222), repair_read.value.?);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const write_before_missing = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.write.success", .surface_label = "storage_durability", .value = 4 },
        .{ .label = "storage_durability.read.missing", .surface_label = "storage_durability", .value = 4 },
    );
    try testing.expect(write_before_missing.check_result.passed);

    const recover_before_repair_write = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.write.success", .surface_label = "storage_durability", .value = 8 },
    );
    try testing.expect(recover_before_repair_write.check_result.passed);
}
