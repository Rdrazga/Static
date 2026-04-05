const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_io = @import("static_io");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const sim = static_testing.testing.sim;
const system = static_testing.testing.system;
const temporal = static_testing.testing.temporal;
const support = @import("support.zig");

const Fixture = sim.fixture.Fixture(4, 4, 4, 40);

const endpoint = static_io.Endpoint{
    .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9015,
    },
};

const components = [_]system.ComponentSpec{
    .{ .name = "runtime" },
    .{ .name = "buffer_pool" },
    .{ .name = "resource_policy" },
};

const exhaustion_violations = [_]checker.Violation{
    .{
        .code = "static_io.buffer_exhaustion",
        .message = "buffer pool did not recover correctly from an in-flight exhaustion path",
    },
};

const ExhaustionRunner = struct {
    runtime: *static_io.Runtime,
    pool: *static_io.BufferPool,
    next_sequence_no: u32 = 0,

    fn run(
        self: *@This(),
        context: *system.SystemContext(Fixture),
    ) anyerror!checker.CheckResult {
        assert(context.hasComponent("runtime"));
        assert(context.hasComponent("buffer_pool"));
        assert(context.hasComponent("resource_policy"));
        assert(context.traceBufferPtr() != null);
        assert(self.pool.capacity() == 2);

        const stream = try support.connectStream(self.runtime, endpoint, context, &self.next_sequence_no);
        defer self.runtime.closeHandle(stream.handle) catch |err| {
            assert(err == error.Closed);
        };

        const held_buffer = try self.pool.acquire();
        const held_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.acquire.held",
            .input,
            "buffer_pool",
            null,
            1,
        );

        const pending_buffer = try self.pool.acquire();
        const pending_id = try self.runtime.submitStreamRead(stream, pending_buffer, null);
        const pending_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.pending",
            .input,
            "runtime",
            held_seq,
            pending_id,
        );

        try testing.expectError(error.NoSpaceLeft, self.pool.acquire());
        const exhausted_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.acquire.exhausted",
            .check,
            "resource_policy",
            pending_seq,
            self.pool.available(),
        );

        try self.runtime.cancel(pending_id);
        _ = try self.runtime.pump(1);
        const cancelled_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try testing.expectEqual(pending_id, cancelled_completion.operation_id);
        try testing.expectEqual(static_io.types.CompletionStatus.cancelled, cancelled_completion.status);
        try testing.expectEqual(@as(?static_io.types.CompletionErrorTag, .cancelled), cancelled_completion.err);
        const cancelled_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.cancelled",
            .check,
            "runtime",
            exhausted_seq,
            cancelled_completion.operation_id,
        );
        try self.pool.release(cancelled_completion.buffer);
        const cancelled_release_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.release.cancelled",
            .info,
            "buffer_pool",
            cancelled_seq,
            1,
        );

        try self.pool.release(held_buffer);
        const held_release_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.release.held",
            .info,
            "buffer_pool",
            cancelled_release_seq,
            1,
        );

        const recovered_buffer = try self.pool.acquire();
        _ = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.acquire.recovered",
            .check,
            "resource_policy",
            held_release_seq,
            1,
        );
        try self.pool.release(recovered_buffer);

        const snapshot = context.traceSnapshot().?;
        const exhaust_before_recovery = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "buffer.acquire.exhausted", .surface_label = "resource_policy" },
            .{ .label = "buffer.acquire.recovered", .surface_label = "resource_policy" },
        );
        if (!exhaust_before_recovery.check_result.passed) return exhaust_before_recovery.check_result;

        const cancel_before_recovery = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "io.read.cancelled", .surface_label = "runtime" },
            .{ .label = "buffer.acquire.recovered", .surface_label = "resource_policy" },
        );
        if (!cancel_before_recovery.check_result.passed) return cancel_before_recovery.check_result;

        const exhausted_once = try temporal.checkExactlyOnce(
            snapshot,
            .{ .label = "buffer.acquire.exhausted", .surface_label = "resource_policy" },
        );
        if (!exhausted_once.check_result.passed) return exhausted_once.check_result;

        if (self.pool.available() != self.pool.capacity()) {
            return checker.CheckResult.fail(&exhaustion_violations, null);
        }

        return checker.CheckResult.pass(null);
    }
};

fn initFixture(fixture: *Fixture) !void {
    try fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(95),
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 40 },
    });
}

test "static_io buffer exhaustion and recovery run under testing.system" {
    var fixture: Fixture = undefined;
    try initFixture(&fixture);
    defer fixture.deinit();

    var pool = try static_io.BufferPool.init(testing.allocator, .{
        .buffer_size = 16,
        .capacity = 2,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(
        testing.allocator,
        static_io.RuntimeConfig.initForTest(4),
    );
    defer runtime.deinit();

    var runner = ExhaustionRunner{
        .runtime = &runtime,
        .pool = &pool,
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_buffer_exhaustion_flow",
        .seed = .init(95),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, ExhaustionRunner, anyerror, &fixture, run_identity, .{
        .components = &components,
    }, &runner, ExhaustionRunner.run);

    try testing.expect(execution.check_result.passed);
    try testing.expectEqual(@as(usize, components.len), execution.component_count);
    try testing.expect(execution.trace_metadata.event_count >= 6);
    try testing.expect(execution.retained_bundle == null);
}
