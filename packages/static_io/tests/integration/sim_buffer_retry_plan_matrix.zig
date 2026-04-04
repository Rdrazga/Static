const std = @import("std");
const static_io = @import("static_io");
const static_testing = @import("static_testing");

const retry_mod = static_testing.testing.sim.retry_queue;
const sim = static_testing.testing.sim;
const storage_mod = static_testing.testing.sim.storage_lane;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;

const Fixture = sim.fixture.Fixture(16, 16, 16, 128);

const PlanKind = enum {
    immediate_success,
    fail_once_then_success,
    fail_until_exhausted,
};

const PlanCase = struct {
    kind: PlanKind,
    scheduler_seed: u64,
    request_id: u32,
};

const plan_cases = [_]PlanCase{
    .{
        .kind = .immediate_success,
        .scheduler_seed = 101,
        .request_id = 11,
    },
    .{
        .kind = .fail_once_then_success,
        .scheduler_seed = 202,
        .request_id = 22,
    },
    .{
        .kind = .fail_until_exhausted,
        .scheduler_seed = 303,
        .request_id = 33,
    },
};

test "static_io buffer retry matrix follows explicit failure plans" {
    for (plan_cases) |plan| {
        try runPlanCase(plan);
    }
}

fn runPlanCase(plan: PlanCase) !void {
    var sim_fixture: Fixture = undefined;
    try sim_fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(plan.scheduler_seed),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 96 },
    });
    defer sim_fixture.deinit();

    var pool = try static_io.BufferPool.init(std.testing.allocator, .{
        .buffer_size = 16,
        .capacity = 1,
    });
    defer pool.deinit();

    var completion_storage: [8]storage_mod.PendingCompletion(u32) = undefined;
    var storage_lane = try storage_mod.StorageLane(u32).init(&completion_storage, .{
        .default_delay = .init(1),
    });

    var retry_storage: [8]retry_mod.PendingRetry(u32) = undefined;
    var retry_queue = try retry_mod.RetryQueue(u32).init(&retry_storage, .{
        .backoff = .init(1),
        .max_attempts = 2,
    });

    var completion_mailbox = try sim.mailbox.Mailbox(storage_mod.OperationResult(u32)).init(
        std.testing.allocator,
        .{ .capacity = 8 },
    );
    defer completion_mailbox.deinit();

    var retry_mailbox = try sim.mailbox.Mailbox(retry_mod.RetryEnvelope(u32)).init(
        std.testing.allocator,
        .{ .capacity = 8 },
    );
    defer retry_mailbox.deinit();

    const buffer = try pool.acquire();
    try appendBufferTrace(
        sim_fixture.traceBufferPtr().?,
        sim_fixture.sim_clock.now(),
        "buffer.acquire.initial",
        plan.request_id,
    );
    try std.testing.expectEqual(@as(u32, 0), pool.available());

    switch (plan.kind) {
        .immediate_success => try runImmediateSuccess(
            &sim_fixture,
            &pool,
            &storage_lane,
            &retry_queue,
            &completion_mailbox,
            &retry_mailbox,
            buffer,
            plan.request_id,
        ),
        .fail_once_then_success => try runFailOnceThenSuccess(
            &sim_fixture,
            &pool,
            &storage_lane,
            &retry_queue,
            &completion_mailbox,
            &retry_mailbox,
            buffer,
            plan.request_id,
        ),
        .fail_until_exhausted => try runFailUntilExhausted(
            &sim_fixture,
            &pool,
            &storage_lane,
            &retry_queue,
            &completion_mailbox,
            &retry_mailbox,
            buffer,
            plan.request_id,
        ),
    }

    try std.testing.expectEqual(@as(u32, 1), pool.available());
    try std.testing.expectEqual(pool.capacity(), pool.available());
}

fn runImmediateSuccess(
    sim_fixture: *Fixture,
    pool: *static_io.BufferPool,
    storage_lane: *storage_mod.StorageLane(u32),
    retry_queue: *retry_mod.RetryQueue(u32),
    completion_mailbox: *sim.mailbox.Mailbox(storage_mod.OperationResult(u32)),
    retry_mailbox: *sim.mailbox.Mailbox(retry_mod.RetryEnvelope(u32)),
    buffer: static_io.Buffer,
    request_id: u32,
) !void {
    try storage_lane.submitSuccess(sim_fixture.sim_clock.now(), request_id, 201);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const delivery = try storage_lane.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        completion_mailbox,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 1), delivery.success_count);
    try std.testing.expectEqual(@as(u32, 0), delivery.failure_count);

    const completion = try completion_mailbox.recv();
    try std.testing.expectEqual(storage_mod.CompletionStatus.success, completion.status);
    try std.testing.expectEqual(@as(u32, 201), completion.value);
    try std.testing.expectEqual(@as(u32, request_id), completion.request_id);

    try pool.release(buffer);
    try appendBufferTrace(
        sim_fixture.traceBufferPtr().?,
        sim_fixture.sim_clock.now(),
        "buffer.release.final",
        request_id,
    );

    _ = try sim_fixture.sim_clock.advance(.init(1));
    try std.testing.expectEqual(
        @as(u32, 0),
        try retry_queue.emitDueToMailbox(
            sim_fixture.sim_clock.now(),
            retry_mailbox,
            sim_fixture.traceBufferPtr(),
        ),
    );

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    try std.testing.expect((try temporal.checkNever(snapshot, .{
        .label = "retry_queue.emit",
        .surface_label = "retry_queue",
    })).check_result.passed);
    try std.testing.expect((try temporal.checkExactlyOnce(snapshot, .{
        .label = "storage_lane.success",
        .surface_label = "storage_lane",
    })).check_result.passed);
    try std.testing.expect((try temporal.checkExactlyOnce(snapshot, .{
        .label = "buffer.release.final",
        .surface_label = "buffer_pool",
    })).check_result.passed);
}

fn runFailOnceThenSuccess(
    sim_fixture: *Fixture,
    pool: *static_io.BufferPool,
    storage_lane: *storage_mod.StorageLane(u32),
    retry_queue: *retry_mod.RetryQueue(u32),
    completion_mailbox: *sim.mailbox.Mailbox(storage_mod.OperationResult(u32)),
    retry_mailbox: *sim.mailbox.Mailbox(retry_mod.RetryEnvelope(u32)),
    buffer: static_io.Buffer,
    request_id: u32,
) !void {
    var current_attempt: u32 = 0;

    try storage_lane.submitFailure(sim_fixture.sim_clock.now(), request_id, 501);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const first_delivery = try storage_lane.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        completion_mailbox,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 0), first_delivery.success_count);
    try std.testing.expectEqual(@as(u32, 1), first_delivery.failure_count);

    const first_completion = try completion_mailbox.recv();
    try std.testing.expectEqual(storage_mod.CompletionStatus.failed, first_completion.status);
    try std.testing.expectEqual(@as(u32, 501), first_completion.value);

    try std.testing.expectEqual(
        retry_mod.RetryDecision.queued,
        try retry_queue.scheduleNext(
            sim_fixture.sim_clock.now(),
            current_attempt,
            first_completion.request_id,
            first_completion.request_id,
        ),
    );
    current_attempt += 1;

    _ = try sim_fixture.sim_clock.advance(.init(1));
    try std.testing.expectEqual(
        @as(u32, 1),
        try retry_queue.emitDueToMailbox(
            sim_fixture.sim_clock.now(),
            retry_mailbox,
            sim_fixture.traceBufferPtr(),
        ),
    );

    const retry = try retry_mailbox.recv();
    try std.testing.expectEqual(@as(u32, request_id), retry.request_id);
    try std.testing.expectEqual(@as(u32, 1), retry.attempt);

    try storage_lane.submitSuccess(sim_fixture.sim_clock.now(), retry.request_id, 202);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const second_delivery = try storage_lane.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        completion_mailbox,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 1), second_delivery.success_count);
    try std.testing.expectEqual(@as(u32, 0), second_delivery.failure_count);

    const success = try completion_mailbox.recv();
    try std.testing.expectEqual(storage_mod.CompletionStatus.success, success.status);
    try std.testing.expectEqual(@as(u32, 202), success.value);
    try std.testing.expectEqual(@as(u32, request_id), success.request_id);

    try pool.release(buffer);
    try appendBufferTrace(
        sim_fixture.traceBufferPtr().?,
        sim_fixture.sim_clock.now(),
        "buffer.release.final",
        request_id,
    );

    _ = try sim_fixture.sim_clock.advance(.init(1));
    try std.testing.expectEqual(
        @as(u32, 0),
        try retry_queue.emitDueToMailbox(
            sim_fixture.sim_clock.now(),
            retry_mailbox,
            sim_fixture.traceBufferPtr(),
        ),
    );

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    try std.testing.expect((try temporal.checkExactlyOnce(snapshot, .{
        .label = "retry_queue.emit",
        .surface_label = "retry_queue",
    })).check_result.passed);
    try std.testing.expect((try temporal.checkHappensBefore(snapshot, .{
        .label = "storage_lane.failed",
        .surface_label = "storage_lane",
    }, .{
        .label = "retry_queue.emit",
        .surface_label = "retry_queue",
    })).check_result.passed);
    try std.testing.expect((try temporal.checkHappensBefore(snapshot, .{
        .label = "retry_queue.emit",
        .surface_label = "retry_queue",
    }, .{
        .label = "storage_lane.success",
        .surface_label = "storage_lane",
    })).check_result.passed);
    try std.testing.expect((try temporal.checkExactlyOnce(snapshot, .{
        .label = "buffer.release.final",
        .surface_label = "buffer_pool",
    })).check_result.passed);
}

fn runFailUntilExhausted(
    sim_fixture: *Fixture,
    pool: *static_io.BufferPool,
    storage_lane: *storage_mod.StorageLane(u32),
    retry_queue: *retry_mod.RetryQueue(u32),
    completion_mailbox: *sim.mailbox.Mailbox(storage_mod.OperationResult(u32)),
    retry_mailbox: *sim.mailbox.Mailbox(retry_mod.RetryEnvelope(u32)),
    buffer: static_io.Buffer,
    request_id: u32,
) !void {
    const failure_values = [_]u32{ 601, 602, 603 };
    var current_attempt: u32 = 0;

    for (failure_values[0..2]) |failure_value| {
        try storage_lane.submitFailure(sim_fixture.sim_clock.now(), request_id, failure_value);
        _ = try sim_fixture.sim_clock.advance(.init(1));
        const delivery = try storage_lane.deliverDueToMailbox(
            sim_fixture.sim_clock.now(),
            completion_mailbox,
            sim_fixture.traceBufferPtr(),
        );
        try std.testing.expectEqual(@as(u32, 0), delivery.success_count);
        try std.testing.expectEqual(@as(u32, 1), delivery.failure_count);

        const completion = try completion_mailbox.recv();
        try std.testing.expectEqual(storage_mod.CompletionStatus.failed, completion.status);
        try std.testing.expectEqual(failure_value, completion.value);

        try std.testing.expectEqual(
            retry_mod.RetryDecision.queued,
            try retry_queue.scheduleNext(
                sim_fixture.sim_clock.now(),
                current_attempt,
                completion.request_id,
                completion.request_id,
            ),
        );
        current_attempt += 1;

        _ = try sim_fixture.sim_clock.advance(.init(1));
        try std.testing.expectEqual(
            @as(u32, 1),
            try retry_queue.emitDueToMailbox(
                sim_fixture.sim_clock.now(),
                retry_mailbox,
                sim_fixture.traceBufferPtr(),
            ),
        );

        const retry = try retry_mailbox.recv();
        try std.testing.expectEqual(@as(u32, request_id), retry.request_id);
        try std.testing.expectEqual(current_attempt, retry.attempt);
    }

    try storage_lane.submitFailure(sim_fixture.sim_clock.now(), request_id, failure_values[2]);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const terminal_delivery = try storage_lane.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        completion_mailbox,
        sim_fixture.traceBufferPtr(),
    );
    try std.testing.expectEqual(@as(u32, 0), terminal_delivery.success_count);
    try std.testing.expectEqual(@as(u32, 1), terminal_delivery.failure_count);

    const terminal_completion = try completion_mailbox.recv();
    try std.testing.expectEqual(storage_mod.CompletionStatus.failed, terminal_completion.status);
    try std.testing.expectEqual(failure_values[2], terminal_completion.value);

    try std.testing.expectEqual(
        retry_mod.RetryDecision.exhausted,
        try retry_queue.scheduleNext(
            sim_fixture.sim_clock.now(),
            current_attempt,
            terminal_completion.request_id,
            terminal_completion.request_id,
        ),
    );

    _ = try sim_fixture.sim_clock.advance(.init(1));
    try std.testing.expectEqual(
        @as(u32, 0),
        try retry_queue.emitDueToMailbox(
            sim_fixture.sim_clock.now(),
            retry_mailbox,
            sim_fixture.traceBufferPtr(),
        ),
    );

    try pool.release(buffer);
    try appendBufferTrace(
        sim_fixture.traceBufferPtr().?,
        sim_fixture.sim_clock.now(),
        "buffer.release.final",
        request_id,
    );

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    try std.testing.expectEqual(@as(usize, 2), countTraceEvents(snapshot, "retry_queue.emit", "retry_queue"));
    try std.testing.expectEqual(@as(usize, 3), countTraceEvents(snapshot, "storage_lane.failed", "storage_lane"));
    try std.testing.expect((try temporal.checkNever(snapshot, .{
        .label = "storage_lane.success",
        .surface_label = "storage_lane",
    })).check_result.passed);
    try std.testing.expect((try temporal.checkExactlyOnce(snapshot, .{
        .label = "buffer.release.final",
        .surface_label = "buffer_pool",
    })).check_result.passed);
    try std.testing.expect((try temporal.checkHappensBefore(snapshot, .{
        .label = "retry_queue.emit",
        .surface_label = "retry_queue",
    }, .{
        .label = "buffer.release.final",
        .surface_label = "buffer_pool",
    })).check_result.passed);
    try std.testing.expectEqual(@as(u32, 0), retry_mailbox.len());
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
