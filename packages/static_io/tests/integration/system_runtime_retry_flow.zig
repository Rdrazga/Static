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

const io_runtime_flow_violations = [_]checker.Violation{
    .{
        .code = "static_io.system_flow",
        .message = "runtime flow did not complete after bounded retry",
    },
};

const FlowMode = enum {
    complete_after_retry,
    fail_before_success,
};

const FlowRunner = struct {
    runtime: *static_io.Runtime,
    pool: *static_io.BufferPool,
    mode: FlowMode,
    next_sequence_no: u32 = 0,

    fn run(
        self: *@This(),
        context: *system.SystemContext(Fixture),
    ) anyerror!checker.CheckResult {
        std.debug.assert(context.hasComponent("runtime"));
        std.debug.assert(context.hasComponent("buffer_pool"));
        std.debug.assert(context.hasComponent("retry_policy"));
        std.debug.assert(context.traceBufferPtr() != null);
        std.debug.assert(self.pool.capacity() >= 2);

        const stream = try support.connectStream(self.runtime, endpoint, context, &self.next_sequence_no);
        defer self.runtime.closeHandle(stream.handle) catch |err| {
            std.debug.assert(err == error.Closed);
        };

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

        const timeout_id = try self.runtime.submitStreamRead(stream, timeout_buffer, 0);
        _ = try self.runtime.pump(1);
        const timeout_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(timeout_id, timeout_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.timeout, timeout_completion.status);

        const timeout_seq = try support.appendEvent(
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
            timeout_seq,
            1,
        );

        const retry_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.retry.scheduled",
            .decision,
            "retry_policy",
            timeout_seq,
            1,
        );

        if (self.mode == .fail_before_success) {
            const snapshot = context.traceSnapshot().?;
            const missing_success = try temporal.checkEventually(snapshot, .{
                .label = "io.read.success",
                .surface_label = "runtime",
            });
            return missing_success.check_result;
        }

        var write_buffer = try self.pool.acquire();
        const write_acquire_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.acquire.write_retry",
            .input,
            "buffer_pool",
            retry_seq,
            1,
        );
        @memcpy(write_buffer.bytes[0..2], "ok");
        try write_buffer.setUsedLen(2);

        const write_id = try self.runtime.submitStreamWrite(stream, write_buffer, null);
        _ = try self.runtime.pump(1);
        const write_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(write_id, write_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.success, write_completion.status);

        const write_seq = try support.appendEvent(
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
            write_seq,
            1,
        );

        const read_buffer = try self.pool.acquire();
        const read_acquire_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.acquire.read_retry",
            .input,
            "buffer_pool",
            write_seq,
            1,
        );

        const read_id = try self.runtime.submitStreamRead(stream, read_buffer, null);
        _ = try self.runtime.pump(1);
        const read_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try std.testing.expectEqual(read_id, read_completion.operation_id);
        try std.testing.expectEqual(static_io.types.CompletionStatus.success, read_completion.status);
        try std.testing.expectEqualStrings("ok", read_completion.buffer.usedSlice());

        const read_seq = try support.appendEvent(
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
            read_seq,
            1,
        );

        const snapshot = context.traceSnapshot().?;
        const timeout_before_retry = try temporal.checkHappensBefore(snapshot, .{
            .label = "io.read.timeout",
            .surface_label = "runtime",
        }, .{
            .label = "io.retry.scheduled",
            .surface_label = "retry_policy",
        });
        if (!timeout_before_retry.check_result.passed) return timeout_before_retry.check_result;

        const write_before_read = try temporal.checkHappensBefore(snapshot, .{
            .label = "io.write.success",
            .surface_label = "runtime",
        }, .{
            .label = "io.read.success",
            .surface_label = "runtime",
        });
        if (!write_before_read.check_result.passed) return write_before_read.check_result;

        const read_once = try temporal.checkExactlyOnce(snapshot, .{
            .label = "io.read.success",
            .surface_label = "runtime",
        });
        if (!read_once.check_result.passed) return read_once.check_result;

        if (self.pool.available() != self.pool.capacity()) {
            return checker.CheckResult.fail(&io_runtime_flow_violations, null);
        }

        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, snapshot.items.len) << 64) | @as(u128, self.pool.available()),
        ));
    }
};

fn initFixture(fixture: *Fixture) !void {
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(41),
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 32 },
    });
}

test "static_io runtime flow runs under testing.system with bounded retry and temporal checks" {
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

    var runner = FlowRunner{
        .runtime = &runtime,
        .pool = &pool,
        .mode = .complete_after_retry,
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_runtime_retry_flow",
        .seed = .init(77),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, FlowRunner, anyerror, &fixture, run_identity, .{
        .components = &components,
    }, &runner, FlowRunner.run);

    try std.testing.expect(execution.check_result.passed);
    try std.testing.expectEqual(@as(usize, components.len), execution.component_count);
    try std.testing.expect(execution.trace_metadata.event_count >= 8);
    try std.testing.expect(execution.retained_bundle == null);
}

test "static_io system flow persists failure bundles with retained provenance" {
    var fixture: Fixture = undefined;
    try initFixture(&fixture);
    defer fixture.deinit();

    var pool = try static_io.BufferPool.init(std.testing.allocator, .{
        .buffer_size = 16,
        .capacity = 2,
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

    var runner = FlowRunner{
        .runtime = &runtime,
        .pool = &pool,
        .mode = .fail_before_success,
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_runtime_retry_flow_failure",
        .seed = .init(88),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, FlowRunner, anyerror, &fixture, run_identity, .{
        .components = &components,
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
    }, &runner, FlowRunner.run);

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

    try std.testing.expectEqualStrings("system_runtime_retry_flow_failure", bundle.manifest_document.run_name);
    try std.testing.expect(bundle.trace_document != null);
    try std.testing.expect(bundle.trace_document.?.has_provenance);
    try std.testing.expect(bundle.trace_document.?.caused_event_count > 0);
    try std.testing.expect(bundle.retained_trace != null);
    try std.testing.expectEqualStrings("temporal_eventually", bundle.violations_document.violations[0].code);
}
