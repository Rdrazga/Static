const std = @import("std");
const static_io = @import("static_io");
const static_testing = @import("static_testing");

const retry_mod = static_testing.testing.sim.retry_queue;
const sim = static_testing.testing.sim;
const storage_mod = static_testing.testing.sim.storage_lane;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;

const Fixture = sim.fixture.Fixture(16, 16, 16, 128);

test "static_io buffer lifecycle composes with simulation retry flow" {
    var sim_fixture: Fixture = undefined;
    try sim_fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(511),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 32 },
    });
    defer sim_fixture.deinit();

    var pool = try static_io.BufferPool.init(std.testing.allocator, .{
        .buffer_size = 16,
        .capacity = 1,
    });
    defer pool.deinit();

    var completion_storage: [4]storage_mod.PendingCompletion(u32) = undefined;
    var storage_lane = try storage_mod.StorageLane(u32).init(&completion_storage, .{
        .default_delay = .init(1),
    });
    var retry_storage: [4]retry_mod.PendingRetry(u32) = undefined;
    var retry_queue = try retry_mod.RetryQueue(u32).init(&retry_storage, .{
        .backoff = .init(1),
        .max_attempts = 2,
    });

    var completion_mailbox = try sim.mailbox.Mailbox(storage_mod.OperationResult(u32)).init(
        std.testing.allocator,
        .{ .capacity = 4 },
    );
    defer completion_mailbox.deinit();
    var retry_mailbox = try sim.mailbox.Mailbox(retry_mod.RetryEnvelope(u32)).init(
        std.testing.allocator,
        .{ .capacity = 4 },
    );
    defer retry_mailbox.deinit();

    const request_id: u32 = 41;
    const buffer = try pool.acquire();
    try appendBufferTrace(
        sim_fixture.traceBufferPtr().?,
        sim_fixture.sim_clock.now(),
        "buffer.acquire.initial",
        request_id,
    );
    try std.testing.expectEqual(@as(u32, 0), pool.available());

    try storage_lane.submitFailure(sim_fixture.sim_clock.now(), request_id, 500);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try storage_lane.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completion_mailbox,
        sim_fixture.traceBufferPtr(),
    );
    const failure = try completion_mailbox.recv();
    try std.testing.expectEqual(storage_mod.CompletionStatus.failed, failure.status);
    try std.testing.expectError(error.NoSpaceLeft, pool.acquire());

    try std.testing.expectEqual(
        retry_mod.RetryDecision.queued,
        try retry_queue.scheduleNext(sim_fixture.sim_clock.now(), 0, failure.request_id, failure.request_id),
    );
    _ = try sim_fixture.sim_clock.advance(.init(1));
    try std.testing.expectEqual(
        @as(u32, 1),
        try retry_queue.emitDueToMailbox(
            sim_fixture.sim_clock.now(),
            &retry_mailbox,
            sim_fixture.traceBufferPtr(),
        ),
    );
    const retry = try retry_mailbox.recv();
    try std.testing.expectEqual(@as(u32, 1), retry.attempt);

    try storage_lane.submitSuccess(sim_fixture.sim_clock.now(), retry.request_id, 200);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try storage_lane.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completion_mailbox,
        sim_fixture.traceBufferPtr(),
    );
    const success = try completion_mailbox.recv();
    try std.testing.expectEqual(storage_mod.CompletionStatus.success, success.status);
    try std.testing.expectEqual(@as(u32, 200), success.value);

    try pool.release(buffer);
    try appendBufferTrace(
        sim_fixture.traceBufferPtr().?,
        sim_fixture.sim_clock.now(),
        "buffer.release.success",
        request_id,
    );
    try std.testing.expectEqual(@as(u32, 1), pool.available());

    const reused = try pool.acquire();
    defer pool.release(reused) catch unreachable;
    try appendBufferTrace(
        sim_fixture.traceBufferPtr().?,
        sim_fixture.sim_clock.now(),
        "buffer.acquire.reuse",
        request_id,
    );

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const retry_before_release = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "retry_queue.emit", .surface_label = "retry_queue" },
        .{ .label = "buffer.release.success", .surface_label = "buffer_pool" },
    );
    try std.testing.expect(retry_before_release.check_result.passed);

    const release_before_reuse = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "buffer.release.success", .surface_label = "buffer_pool" },
        .{ .label = "buffer.acquire.reuse", .surface_label = "buffer_pool" },
    );
    try std.testing.expect(release_before_reuse.check_result.passed);
}

test "static_io buffer lifecycle holds across a larger multi-request retry simulation" {
    var sim_fixture: Fixture = undefined;
    try sim_fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{
            .buckets = 16,
            .timers_max = 16,
        },
        .scheduler_seed = .init(733),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 16 },
        .trace_config = .{ .max_events = 128 },
    });
    defer sim_fixture.deinit();

    var pool = try static_io.BufferPool.init(std.testing.allocator, .{
        .buffer_size = 32,
        .capacity = 4,
    });
    defer pool.deinit();

    var completion_storage: [16]storage_mod.PendingCompletion(u32) = undefined;
    var storage_lane = try storage_mod.StorageLane(u32).init(&completion_storage, .{
        .default_delay = .init(1),
    });
    var retry_storage: [16]retry_mod.PendingRetry(u32) = undefined;
    var retry_queue = try retry_mod.RetryQueue(u32).init(&retry_storage, .{
        .backoff = .init(1),
        .max_attempts = 3,
    });

    var completion_mailbox = try sim.mailbox.Mailbox(storage_mod.OperationResult(u32)).init(
        std.testing.allocator,
        .{ .capacity = 16 },
    );
    defer completion_mailbox.deinit();
    var retry_mailbox = try sim.mailbox.Mailbox(retry_mod.RetryEnvelope(u32)).init(
        std.testing.allocator,
        .{ .capacity = 16 },
    );
    defer retry_mailbox.deinit();

    const request_ids = [_]u32{ 41, 42, 43, 44 };
    var buffers: [request_ids.len]static_io.Buffer = undefined;
    var released: [request_ids.len]bool = [_]bool{false} ** request_ids.len;

    for (request_ids, 0..) |request_id, index| {
        buffers[index] = try pool.acquire();
        try appendBufferTrace(
            sim_fixture.traceBufferPtr().?,
            sim_fixture.sim_clock.now(),
            "buffer.acquire.batch",
            request_id,
        );
    }
    try std.testing.expectEqual(@as(u32, 0), pool.available());

    try storage_lane.submitFailure(sim_fixture.sim_clock.now(), request_ids[0], 501);
    try storage_lane.submitFailure(sim_fixture.sim_clock.now(), request_ids[1], 502);
    try storage_lane.submitSuccess(sim_fixture.sim_clock.now(), request_ids[2], 203);
    try storage_lane.submitSuccess(sim_fixture.sim_clock.now(), request_ids[3], 204);

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const initial_delivery = try storage_lane.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completion_mailbox,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 2), initial_delivery.success_count);
    try std.testing.expectEqual(@as(u32, 2), initial_delivery.failure_count);

    var retry_count: u32 = 0;
    var initial_success_count: u32 = 0;
    while (completion_mailbox.len() != 0) {
        const completion = try completion_mailbox.recv();
        const request_index = requestIndex(request_ids[0..], completion.request_id).?;
        if (completion.status == .failed) {
            retry_count += 1;
            try std.testing.expectEqual(
                retry_mod.RetryDecision.queued,
                try retry_queue.scheduleNext(
                    sim_fixture.sim_clock.now(),
                    0,
                    completion.request_id,
                    completion.request_id,
                ),
            );
            continue;
        }

        initial_success_count += 1;
        try pool.release(buffers[request_index]);
        released[request_index] = true;
        try appendBufferTrace(
            sim_fixture.traceBufferPtr().?,
            sim_fixture.sim_clock.now(),
            "buffer.release.initial_success",
            completion.request_id,
        );
    }

    try std.testing.expectEqual(@as(u32, 2), retry_count);
    try std.testing.expectEqual(@as(u32, 2), initial_success_count);
    try std.testing.expectEqual(@as(u32, 2), pool.available());

    _ = try sim_fixture.sim_clock.advance(.init(1));
    try std.testing.expectEqual(
        @as(u32, 2),
        try retry_queue.emitDueToMailbox(
            sim_fixture.sim_clock.now(),
            &retry_mailbox,
            sim_fixture.traceBufferPtr(),
        ),
    );

    while (retry_mailbox.len() != 0) {
        const retry = try retry_mailbox.recv();
        try std.testing.expectEqual(@as(u32, 1), retry.attempt);
        try storage_lane.submitSuccess(sim_fixture.sim_clock.now(), retry.request_id, 300 + retry.request_id);
    }

    _ = try sim_fixture.sim_clock.advance(.init(1));
    const retry_delivery = try storage_lane.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completion_mailbox,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 2), retry_delivery.success_count);
    try std.testing.expectEqual(@as(u32, 0), retry_delivery.failure_count);

    var retried_success_count: u32 = 0;
    while (completion_mailbox.len() != 0) {
        const completion = try completion_mailbox.recv();
        try std.testing.expectEqual(storage_mod.CompletionStatus.success, completion.status);
        const request_index = requestIndex(request_ids[0..], completion.request_id).?;
        try std.testing.expect(!released[request_index]);
        try pool.release(buffers[request_index]);
        released[request_index] = true;
        retried_success_count += 1;
        try appendBufferTrace(
            sim_fixture.traceBufferPtr().?,
            sim_fixture.sim_clock.now(),
            "buffer.release.retried_success",
            completion.request_id,
        );
    }

    try std.testing.expectEqual(@as(u32, 2), retried_success_count);
    try std.testing.expectEqual(pool.capacity(), pool.available());

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const retry_before_release = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "retry_queue.emit", .surface_label = "retry_queue" },
        .{ .label = "buffer.release.retried_success", .surface_label = "buffer_pool" },
    );
    try std.testing.expect(retry_before_release.check_result.passed);

    var retried_release_count: usize = 0;
    for (snapshot.items) |event| {
        if (std.mem.eql(u8, event.label, "buffer.release.retried_success") and
            event.lineage.surface_label != null and
            std.mem.eql(u8, event.lineage.surface_label.?, "buffer_pool"))
        {
            retried_release_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), retried_release_count);
}

fn requestIndex(request_ids: []const u32, request_id: u32) ?usize {
    std.debug.assert(request_ids.len != 0);
    std.debug.assert(request_id != 0);

    for (request_ids, 0..) |candidate, index| {
        if (candidate == request_id) return index;
    }
    return null;
}

fn appendBufferTrace(
    buffer: *trace.TraceBuffer,
    now: sim.clock.LogicalTime,
    label: []const u8,
    request_id: u32,
) !void {
    std.debug.assert(label.len != 0);
    std.debug.assert(request_id != 0);

    try buffer.append(.{
        .timestamp_ns = now.tick,
        .category = .info,
        .label = label,
        .value = request_id,
        .lineage = .{
            .correlation_id = request_id,
            .surface_label = "buffer_pool",
        },
    });
    std.debug.assert(buffer.snapshot().items.len != 0);
}

fn countTraceEvents(snapshot: trace.TraceSnapshot, label: []const u8, surface_label: []const u8) usize {
    std.debug.assert(label.len != 0);
    std.debug.assert(surface_label.len != 0);

    var count: usize = 0;
    for (snapshot.items) |event| {
        if (std.mem.eql(u8, event.label, label) and
            event.lineage.surface_label != null and
            std.mem.eql(u8, event.lineage.surface_label.?, surface_label))
        {
            count += 1;
        }
    }

    std.debug.assert(count <= snapshot.items.len);
    return count;
}
