const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_io = @import("static_io");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const liveness = static_testing.testing.liveness;
const sim = static_testing.testing.sim;
const system = static_testing.testing.system;
const temporal = static_testing.testing.temporal;
const support = @import("support.zig");

const Fixture = sim.fixture.Fixture(4, 4, 4, 32);

const components = [_]system.ComponentSpec{
    .{ .name = "runtime" },
    .{ .name = "buffer_pool" },
    .{ .name = "retry_policy" },
};

const endpoint = static_io.Endpoint{
    .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9007,
    },
};

const repair_liveness_violations = [_]checker.Violation{
    .{
        .code = "static_io.system_repair_liveness",
        .message = "runtime retry repair flow did not restore bounded ownership and ordering",
    },
};

const RepairRunner = struct {
    runtime: *static_io.Runtime,
    pool: *static_io.BufferPool,
    stream: ?static_io.types.Stream = null,
    next_sequence_no: u32 = 0,
    repaired: bool = false,
    timeout_complete: bool = false,
    retry_scheduled: bool = false,
    write_complete: bool = false,
    read_complete: bool = false,
    timeout_seq: ?u32 = null,
    retry_seq: ?u32 = null,
    write_seq: ?u32 = null,

    fn closeOpenStream(self: *@This()) void {
        if (self.stream) |stream| {
            self.runtime.closeHandle(stream.handle) catch |err| {
                assert(err == error.Closed);
            };
            self.stream = null;
        }
    }

    fn ensureConnected(
        self: *@This(),
        context: *system.SystemContext(Fixture),
    ) !void {
        if (self.stream == null) {
            self.stream = try support.connectStream(self.runtime, endpoint, context, &self.next_sequence_no);
        }
    }

    fn runFaultPhase(
        self: *@This(),
        context: *system.SystemContext(Fixture),
        steps_max: u32,
    ) anyerror!liveness.PhaseExecution {
        assert(context.hasComponent("runtime"));
        assert(context.hasComponent("buffer_pool"));
        assert(context.hasComponent("retry_policy"));
        assert(context.traceBufferPtr() != null);

        try self.ensureConnected(context);

        var steps: u32 = 0;
        if (!self.timeout_complete and steps < steps_max) {
            const timeout_buffer = try self.pool.acquire();
            const timeout_acquire_seq = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "buffer.acquire.timeout_read",
                .input,
                "buffer_pool",
                null,
                1,
            );

            const timeout_id = try self.runtime.submitStreamRead(self.stream.?, timeout_buffer, 0);
            _ = try self.runtime.pump(1);
            const timeout_completion = self.runtime.poll() orelse return error.MissingCompletion;
            try testing.expectEqual(timeout_id, timeout_completion.operation_id);
            try testing.expectEqual(static_io.types.CompletionStatus.timeout, timeout_completion.status);

            self.timeout_seq = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "io.read.timeout",
                .check,
                "runtime",
                timeout_acquire_seq,
                timeout_completion.bytes_transferred,
            );
            try self.pool.release(timeout_completion.buffer);
            _ = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "buffer.release.timeout_read",
                .info,
                "buffer_pool",
                self.timeout_seq,
                1,
            );
            self.timeout_complete = true;
            steps += 1;
        }

        if (self.timeout_complete and !self.retry_scheduled and steps < steps_max) {
            self.retry_seq = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "io.retry.scheduled",
                .decision,
                "retry_policy",
                self.timeout_seq,
                1,
            );
            self.retry_scheduled = true;
            steps += 1;
        }

        return .{
            .steps_executed = steps,
            .check_result = checker.CheckResult.pass(null),
        };
    }

    fn transitionToRepair(
        self: *@This(),
        context: *system.SystemContext(Fixture),
    ) void {
        assert(context.hasComponent("retry_policy"));
        self.repaired = true;
    }

    fn runRepairPhase(
        self: *@This(),
        context: *system.SystemContext(Fixture),
        steps_max: u32,
    ) anyerror!liveness.PhaseExecution {
        assert(self.repaired);
        assert(self.stream != null);

        var steps: u32 = 0;
        if (self.retry_scheduled and !self.write_complete and steps < steps_max) {
            var write_buffer = try self.pool.acquire();
            const write_acquire_seq = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "buffer.acquire.write_retry",
                .input,
                "buffer_pool",
                self.retry_seq,
                1,
            );
            @memcpy(write_buffer.bytes[0..2], "ok");
            try write_buffer.setUsedLen(2);

            const write_id = try self.runtime.submitStreamWrite(self.stream.?, write_buffer, null);
            _ = try self.runtime.pump(1);
            const write_completion = self.runtime.poll() orelse return error.MissingCompletion;
            try testing.expectEqual(write_id, write_completion.operation_id);
            try testing.expectEqual(static_io.types.CompletionStatus.success, write_completion.status);

            self.write_seq = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "io.write.success",
                .check,
                "runtime",
                write_acquire_seq,
                write_completion.bytes_transferred,
            );
            try self.pool.release(write_completion.buffer);
            _ = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "buffer.release.write_retry",
                .info,
                "buffer_pool",
                self.write_seq,
                1,
            );
            self.write_complete = true;
            steps += 1;
        }

        if (self.write_complete and !self.read_complete and steps < steps_max) {
            const read_buffer = try self.pool.acquire();
            const read_acquire_seq = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "buffer.acquire.read_retry",
                .input,
                "buffer_pool",
                self.write_seq,
                1,
            );

            const read_id = try self.runtime.submitStreamRead(self.stream.?, read_buffer, null);
            _ = try self.runtime.pump(1);
            const read_completion = self.runtime.poll() orelse return error.MissingCompletion;
            try testing.expectEqual(read_id, read_completion.operation_id);
            try testing.expectEqual(static_io.types.CompletionStatus.success, read_completion.status);
            try testing.expectEqualStrings("ok", read_completion.buffer.usedSlice());

            _ = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "io.read.success",
                .check,
                "runtime",
                read_acquire_seq,
                read_completion.bytes_transferred,
            );
            try self.pool.release(read_completion.buffer);
            _ = try support.appendEvent(
                context,
                &self.next_sequence_no,
                "buffer.release.read_retry",
                .info,
                "buffer_pool",
                null,
                1,
            );
            self.read_complete = true;
            self.closeOpenStream();
            steps += 1;
        }

        if (!self.read_complete) {
            return .{
                .steps_executed = steps,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        const snapshot = context.traceSnapshot().?;
        const timeout_before_retry = try temporal.checkHappensBefore(snapshot, .{
            .label = "io.read.timeout",
            .surface_label = "runtime",
        }, .{
            .label = "io.retry.scheduled",
            .surface_label = "retry_policy",
        });
        if (!timeout_before_retry.check_result.passed) {
            return .{
                .steps_executed = steps,
                .check_result = timeout_before_retry.check_result,
            };
        }

        const write_before_read = try temporal.checkHappensBefore(snapshot, .{
            .label = "io.write.success",
            .surface_label = "runtime",
        }, .{
            .label = "io.read.success",
            .surface_label = "runtime",
        });
        if (!write_before_read.check_result.passed) {
            return .{
                .steps_executed = steps,
                .check_result = write_before_read.check_result,
            };
        }

        const read_once = try temporal.checkExactlyOnce(snapshot, .{
            .label = "io.read.success",
            .surface_label = "runtime",
        });
        if (!read_once.check_result.passed) {
            return .{
                .steps_executed = steps,
                .check_result = read_once.check_result,
            };
        }

        if (self.pool.available() != self.pool.capacity()) {
            return .{
                .steps_executed = steps,
                .check_result = checker.CheckResult.fail(&repair_liveness_violations, null),
            };
        }

        return .{
            .steps_executed = steps,
            .check_result = checker.CheckResult.pass(null),
        };
    }

    fn pendingReason(
        self: *@This(),
        _: *system.SystemContext(Fixture),
    ) anyerror!?liveness.PendingReasonDetail {
        if (!self.retry_scheduled) {
            return .{
                .reason = .scheduled_timer_remaining,
                .count = 1,
                .label = "retry_schedule",
            };
        }
        if (!self.read_complete) {
            return .{
                .reason = .inflight_request,
                .count = 1,
                .label = "runtime_retry_read",
            };
        }
        return null;
    }
};

fn initFixture(fixture: *Fixture) !void {
    try fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(41),
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 32 },
    });
}

test "static_io runtime retry flow converges under testing.system repair liveness" {
    var fixture: Fixture = undefined;
    try initFixture(&fixture);
    defer fixture.deinit();

    var pool = try static_io.BufferPool.init(testing.allocator, .{
        .buffer_size = 16,
        .capacity = 3,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(
        testing.allocator,
        static_io.RuntimeConfig.initForTest(4),
    );
    defer runtime.deinit();

    var runner = RepairRunner{
        .runtime = &runtime,
        .pool = &pool,
    };
    defer runner.closeOpenStream();

    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_runtime_repair_liveness",
        .seed = .init(144),
        .build_mode = .debug,
    });

    const execution = try system.runRepairLivenessWithFixture(
        Fixture,
        RepairRunner,
        anyerror,
        &fixture,
        run_identity,
        .{
            .components = &components,
            .liveness_config = .{
                .fault_phase_steps_max = 2,
                .repair_phase_steps_max = 2,
            },
        },
        &runner,
        .{
            .run_fault_phase_fn = RepairRunner.runFaultPhase,
            .transition_to_repair_fn = RepairRunner.transitionToRepair,
            .run_repair_phase_fn = RepairRunner.runRepairPhase,
            .pending_reason_fn = RepairRunner.pendingReason,
        },
    );

    try testing.expect(execution.summary.converged);
    try testing.expect(execution.summary.pending_reason == null);
    try testing.expectEqual(@as(usize, components.len), execution.component_count);
    try testing.expect(execution.trace_metadata.event_count >= 8);
    try testing.expect(execution.retained_bundle == null);
}
