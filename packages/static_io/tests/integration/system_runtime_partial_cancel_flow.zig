const std = @import("std");
const static_io = @import("static_io");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const failure_bundle = static_testing.testing.failure_bundle;
const identity = static_testing.testing.identity;
const sim = static_testing.testing.sim;
const system = static_testing.testing.system;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;
const support = @import("support.zig");

const Fixture = sim.fixture.Fixture(4, 4, 4, 48);

const endpoint = static_io.Endpoint{
    .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9013,
    },
};

const partial_components = [_]system.ComponentSpec{
    .{ .name = "runtime" },
    .{ .name = "buffer_pool" },
    .{ .name = "read_policy" },
};

const cancel_components = [_]system.ComponentSpec{
    .{ .name = "runtime" },
    .{ .name = "buffer_pool" },
    .{ .name = "cancel_policy" },
};

const CancelMode = enum {
    recover_after_cancel,
    fail_before_followup,
};

const PartialReadRunner = struct {
    runtime: *static_io.Runtime,
    pool: *static_io.BufferPool,
    next_sequence_no: u32 = 0,

    fn run(
        self: *@This(),
        context: *system.SystemContext(Fixture),
    ) anyerror!checker.CheckResult {
        std.debug.assert(context.hasComponent("runtime"));
        std.debug.assert(context.hasComponent("buffer_pool"));
        std.debug.assert(context.hasComponent("read_policy"));
        std.debug.assert(context.traceBufferPtr() != null);
        std.debug.assert(self.pool.capacity() >= 2);

        const stream = try support.connectStream(self.runtime, endpoint, context, &self.next_sequence_no);
        defer self.runtime.closeHandle(stream.handle) catch |err| {
            std.debug.assert(err == error.Closed);
        };

        var write_buffer = try self.pool.acquire();
        @memcpy(write_buffer.bytes[0..2], "ok");
        try write_buffer.setUsedLen(2);

        const write_id = try self.runtime.submitStreamWrite(stream, write_buffer, null);
        _ = try self.runtime.pump(1);
        const write_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(write_id, write_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.success, write_completion.status);
        try std.testing.expectEqual(@as(u32, 2), write_completion.bytes_transferred);
        const write_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.write.seed.success",
            .check,
            "runtime",
            null,
            write_completion.bytes_transferred,
        );
        try self.pool.release(write_completion.buffer);

        const read_buffer = try self.pool.acquire();
        const read_id = try self.runtime.submitStreamRead(stream, read_buffer, null);
        _ = try self.runtime.pump(1);
        const read_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(read_id, read_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.success, read_completion.status);
        try std.testing.expectEqual(@as(u32, 2), read_completion.bytes_transferred);
        try std.testing.expect(read_completion.bytes_transferred < read_completion.buffer.capacity());
        try std.testing.expectEqualStrings("ok", read_completion.buffer.usedSlice());
        const read_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.partial",
            .check,
            "runtime",
            write_seq,
            read_completion.bytes_transferred,
        );
        try self.pool.release(read_completion.buffer);

        const drain_buffer = try self.pool.acquire();
        const timeout_id = try self.runtime.submitStreamRead(stream, drain_buffer, 0);
        _ = try self.runtime.pump(1);
        const timeout_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(timeout_id, timeout_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.timeout, timeout_completion.status);
        try std.testing.expectEqual(@as(u32, 0), timeout_completion.bytes_transferred);
        _ = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.drain.timeout",
            .check,
            "read_policy",
            read_seq,
            timeout_completion.bytes_transferred,
        );
        try self.pool.release(timeout_completion.buffer);

        const snapshot = context.traceSnapshot().?;
        const write_before_partial = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "io.write.seed.success", .surface_label = "runtime" },
            .{ .label = "io.read.partial", .surface_label = "runtime" },
        );
        if (!write_before_partial.check_result.passed) return write_before_partial.check_result;

        const partial_before_timeout = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "io.read.partial", .surface_label = "runtime" },
            .{ .label = "io.read.drain.timeout", .surface_label = "read_policy" },
        );
        if (!partial_before_timeout.check_result.passed) return partial_before_timeout.check_result;

        const partial_once = try temporal.checkExactlyOnce(
            snapshot,
            .{ .label = "io.read.partial", .surface_label = "runtime" },
        );
        if (!partial_once.check_result.passed) return partial_once.check_result;

        if (self.pool.available() != self.pool.capacity()) {
            return checker.CheckResult.fail(&[_]checker.Violation{
                .{
                    .code = "static_io.partial_flow",
                    .message = "buffer pool did not return to full availability after partial-read flow",
                },
            }, null);
        }

        return checker.CheckResult.pass(null);
    }
};

const CancelRunner = struct {
    runtime: *static_io.Runtime,
    pool: *static_io.BufferPool,
    mode: CancelMode = .recover_after_cancel,
    next_sequence_no: u32 = 0,

    fn run(
        self: *@This(),
        context: *system.SystemContext(Fixture),
    ) anyerror!checker.CheckResult {
        std.debug.assert(context.hasComponent("runtime"));
        std.debug.assert(context.hasComponent("buffer_pool"));
        std.debug.assert(context.hasComponent("cancel_policy"));
        std.debug.assert(context.traceBufferPtr() != null);
        std.debug.assert(self.pool.capacity() >= 3);

        const stream = try support.connectStream(self.runtime, endpoint, context, &self.next_sequence_no);
        defer self.runtime.closeHandle(stream.handle) catch |err| {
            std.debug.assert(err == error.Closed);
        };

        const pending_buffer = try self.pool.acquire();
        const pending_id = try self.runtime.submitStreamRead(stream, pending_buffer, null);
        const pending_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.pending",
            .input,
            "runtime",
            null,
            pending_id,
        );

        try self.runtime.cancel(pending_id);
        const cancel_requested_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.cancel.requested",
            .decision,
            "cancel_policy",
            pending_seq,
            pending_id,
        );

        _ = try self.runtime.pump(1);
        const cancelled_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(pending_id, cancelled_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.cancelled, cancelled_completion.status);
        try std.testing.expectEqual(@as(?static_io.types.CompletionErrorTag, .cancelled), cancelled_completion.err);
        try std.testing.expectEqual(@as(u32, 0), cancelled_completion.bytes_transferred);
        try std.testing.expectEqual(@as(usize, 0), cancelled_completion.buffer.usedSlice().len);
        const cancelled_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.cancelled",
            .check,
            "runtime",
            cancel_requested_seq,
            cancelled_completion.operation_id,
        );
        try self.pool.release(cancelled_completion.buffer);

        if (self.mode == .fail_before_followup) {
            const snapshot = context.traceSnapshot().?;
            const missing_followup = try temporal.checkEventually(
                snapshot,
                .{ .label = "io.read.followup.success", .surface_label = "runtime" },
            );
            return missing_followup.check_result;
        }

        var write_buffer = try self.pool.acquire();
        @memcpy(write_buffer.bytes[0..2], "go");
        try write_buffer.setUsedLen(2);
        const write_id = try self.runtime.submitStreamWrite(stream, write_buffer, null);
        _ = try self.runtime.pump(1);
        const write_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(write_id, write_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.success, write_completion.status);
        const write_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.write.followup.success",
            .check,
            "runtime",
            cancelled_seq,
            write_completion.bytes_transferred,
        );
        try self.pool.release(write_completion.buffer);

        const read_buffer = try self.pool.acquire();
        const read_id = try self.runtime.submitStreamRead(stream, read_buffer, null);
        _ = try self.runtime.pump(1);
        const read_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(read_id, read_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.success, read_completion.status);
        try std.testing.expectEqualStrings("go", read_completion.buffer.usedSlice());
        _ = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.followup.success",
            .check,
            "runtime",
            write_seq,
            read_completion.bytes_transferred,
        );
        try self.pool.release(read_completion.buffer);
        try std.testing.expect(self.runtime.poll() == null);

        const snapshot = context.traceSnapshot().?;
        const submit_before_cancel = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "io.read.pending", .surface_label = "runtime" },
            .{ .label = "io.read.cancel.requested", .surface_label = "cancel_policy" },
        );
        if (!submit_before_cancel.check_result.passed) return submit_before_cancel.check_result;

        const cancel_before_followup = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "io.read.cancelled", .surface_label = "runtime" },
            .{ .label = "io.read.followup.success", .surface_label = "runtime" },
        );
        if (!cancel_before_followup.check_result.passed) return cancel_before_followup.check_result;

        const cancelled_once = try temporal.checkExactlyOnce(
            snapshot,
            .{ .label = "io.read.cancelled", .surface_label = "runtime" },
        );
        if (!cancelled_once.check_result.passed) return cancelled_once.check_result;

        if (self.pool.available() != self.pool.capacity()) {
            return checker.CheckResult.fail(&[_]checker.Violation{
                .{
                    .code = "static_io.cancel_flow",
                    .message = "buffer pool did not return to full availability after cancellation flow",
                },
            }, null);
        }

        return checker.CheckResult.pass(null);
    }
};

fn initFixture(fixture: *Fixture) !void {
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(91),
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 48 },
    });
}

test "static_io runtime flow records partial completion under testing.system" {
    var fixture: Fixture = undefined;
    try initFixture(&fixture);
    defer fixture.deinit();

    var pool = try static_io.BufferPool.init(std.testing.allocator, .{
        .buffer_size = 16,
        .capacity = 3,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(
        std.testing.allocator,
        static_io.RuntimeConfig.initForTest(4),
    );
    defer runtime.deinit();

    var runner = PartialReadRunner{
        .runtime = &runtime,
        .pool = &pool,
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_runtime_partial_read_flow",
        .seed = .init(91),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, PartialReadRunner, anyerror, &fixture, run_identity, .{
        .components = &partial_components,
    }, &runner, PartialReadRunner.run);

    try std.testing.expect(execution.check_result.passed);
    try std.testing.expectEqual(@as(usize, partial_components.len), execution.component_count);
    try std.testing.expect(execution.trace_metadata.event_count >= 4);
    try std.testing.expect(execution.retained_bundle == null);
}

test "static_io runtime flow records cancellation and recovery under testing.system" {
    var fixture: Fixture = undefined;
    try initFixture(&fixture);
    defer fixture.deinit();

    var pool = try static_io.BufferPool.init(std.testing.allocator, .{
        .buffer_size = 16,
        .capacity = 4,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(
        std.testing.allocator,
        static_io.RuntimeConfig.initForTest(4),
    );
    defer runtime.deinit();

    var runner = CancelRunner{
        .runtime = &runtime,
        .pool = &pool,
        .mode = .recover_after_cancel,
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_runtime_cancel_flow",
        .seed = .init(92),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, CancelRunner, anyerror, &fixture, run_identity, .{
        .components = &cancel_components,
    }, &runner, CancelRunner.run);

    try std.testing.expect(execution.check_result.passed);
    try std.testing.expectEqual(@as(usize, cancel_components.len), execution.component_count);
    try std.testing.expect(execution.trace_metadata.event_count >= 5);
    try std.testing.expect(execution.retained_bundle == null);
}

test "static_io cancellation failure persists retained provenance through testing.system" {
    var fixture: Fixture = undefined;
    try initFixture(&fixture);
    defer fixture.deinit();

    var pool = try static_io.BufferPool.init(std.testing.allocator, .{
        .buffer_size = 16,
        .capacity = 4,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(
        std.testing.allocator,
        static_io.RuntimeConfig.initForTest(4),
    );
    defer runtime.deinit();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [2048]u8 = undefined;
    var trace_buffer_storage: [512]u8 = undefined;
    var retained_trace_file_buffer: [2048]u8 = undefined;
    var retained_trace_frame_buffer: [512]u8 = undefined;
    var violations_buffer: [1024]u8 = undefined;

    var runner = CancelRunner{
        .runtime = &runtime,
        .pool = &pool,
        .mode = .fail_before_followup,
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_runtime_cancel_flow_failure",
        .seed = .init(93),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, CancelRunner, anyerror, &fixture, run_identity, .{
        .components = &cancel_components,
        .failure_persistence = .{
            .bundle_persistence = .{
                .io = threaded_io.io(),
                .dir = tmp_dir.dir,
                .entry_name_buffer = &entry_name_buffer,
                .artifact_buffer = &artifact_buffer,
                .manifest_buffer = &manifest_buffer,
                .trace_buffer = &trace_buffer_storage,
                .retained_trace_file_buffer = &retained_trace_file_buffer,
                .retained_trace_frame_buffer = &retained_trace_frame_buffer,
                .violations_buffer = &violations_buffer,
            },
            .artifact_selection = .{ .trace_artifact = .summary_and_retained },
        },
    }, &runner, CancelRunner.run);

    try std.testing.expect(!execution.check_result.passed);
    try std.testing.expect(execution.retained_bundle != null);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [2048]u8 = undefined;
    var read_retained_events: [16]trace.TraceEvent = undefined;
    var read_retained_labels: [512]u8 = undefined;
    var read_violations_source: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [failure_bundle.recommended_violations_parse_len]u8 = undefined;

    const bundle = try failure_bundle.readFailureBundle(threaded_io.io(), tmp_dir.dir, execution.retained_bundle.?.entry_name, .{
        .selection = .{
            .trace_artifact = .summary_and_retained,
            .text_capture = .none,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .retained_trace_file_buffer = &read_retained_trace_file,
        .retained_trace_events_buffer = &read_retained_events,
        .retained_trace_label_buffer = &read_retained_labels,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try std.testing.expectEqualStrings("system_runtime_cancel_flow_failure", bundle.manifest_document.run_name);
    try std.testing.expect(bundle.trace_document != null);
    try std.testing.expect(bundle.trace_document.?.has_provenance);
    try std.testing.expect(bundle.trace_document.?.caused_event_count > 0);
    try std.testing.expect(bundle.retained_trace != null);
    try std.testing.expectEqualStrings("temporal_eventually", bundle.violations_document.violations[0].code);
}
