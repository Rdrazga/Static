const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_io = @import("static_io");
const static_testing = @import("static_testing");
const integration_options = @import("static_io_integration_options");

const checker = static_testing.testing.checker;
const failure_bundle = static_testing.testing.failure_bundle;
const identity = static_testing.testing.identity;
const driver_protocol = static_testing.testing.driver_protocol;
const process_driver = static_testing.testing.process_driver;
const sim = static_testing.testing.sim;
const system = static_testing.testing.system;
const temporal = static_testing.testing.temporal;
const trace = static_testing.testing.trace;
const support = @import("support.zig");

const Fixture = sim.fixture.Fixture(4, 4, 4, 64);
const driver_path: []const u8 = integration_options.driver_runtime_echo_path;

const components = [_]system.ComponentSpec{
    .{ .name = "process_driver" },
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

const violations = [_]checker.Violation{
    .{
        .code = "static_io.system_process_driver_runtime_retry",
        .message = "process-driver and runtime retry composition diverged from the bounded invariant",
    },
};

const Mode = enum {
    pass,
    fail_with_driver_stderr,
};

const Runner = struct {
    io: std.Io,
    runtime: *static_io.Runtime,
    pool: *static_io.BufferPool,
    mode: Mode,
    next_sequence_no: u32 = 0,

    fn run(self: *@This(), context: *system.SystemContext(Fixture)) anyerror!checker.CheckResult {
        assert(context.hasComponent("process_driver"));
        assert(context.hasComponent("runtime"));
        assert(context.hasComponent("buffer_pool"));
        assert(context.hasComponent("retry_policy"));
        assert(context.traceBufferPtr() != null);
        assert(self.pool.capacity() >= 2);

        const stream = try support.connectStream(self.runtime, endpoint, context, &self.next_sequence_no);
        defer self.runtime.closeHandle(stream.handle) catch |err| {
            assert(err == error.Closed);
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
        try testing.expectEqual(timeout_id, timeout_completion.operation_id);
        try testing.expectEqual(static_io.types.CompletionStatus.timeout, timeout_completion.status);

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

        var retry_buffer = try self.pool.acquire();
        const retry_acquire_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.acquire.retry_read",
            .input,
            "buffer_pool",
            retry_seq,
            1,
        );
        @memcpy(retry_buffer.bytes[0..2], "ok");
        try retry_buffer.setUsedLen(2);

        const write_id = try self.runtime.submitStreamWrite(stream, retry_buffer, null);
        _ = try self.runtime.pump(1);
        const write_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try testing.expectEqual(write_id, write_completion.operation_id);
        try testing.expectEqual(static_io.types.CompletionStatus.success, write_completion.status);

        const write_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.write.success",
            .check,
            "runtime",
            retry_acquire_seq,
            write_completion.bytes_transferred,
        );
        try self.pool.release(write_completion.buffer);
        _ = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.release.retry_read",
            .info,
            "buffer_pool",
            write_seq,
            1,
        );

        const read_buffer = try self.pool.acquire();
        const read_acquire_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "buffer.acquire.final_read",
            .input,
            "buffer_pool",
            write_seq,
            1,
        );

        const read_id = try self.runtime.submitStreamRead(stream, read_buffer, null);
        _ = try self.runtime.pump(1);
        const read_completion = self.runtime.poll() orelse return error.MissingCompletion;
        try testing.expectEqual(read_id, read_completion.operation_id);
        try testing.expectEqual(static_io.types.CompletionStatus.success, read_completion.status);
        try testing.expectEqualStrings("ok", read_completion.buffer.usedSlice());

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
            "buffer.release.final_read",
            .info,
            "buffer_pool",
            read_seq,
            1,
        );

        const driver_roundtrip = try self.runEchoDriver(context, read_seq);
        if (self.mode == .fail_with_driver_stderr) {
            _ = try self.runMalformedDriver(context, driver_roundtrip);
            const snapshot = context.traceSnapshot().?;
            const retry_before_read = try temporal.checkHappensBefore(snapshot, .{
                .label = "io.read.timeout",
                .surface_label = "runtime",
            }, .{
                .label = "io.retry.scheduled",
                .surface_label = "retry_policy",
            });
            if (!retry_before_read.check_result.passed) return retry_before_read.check_result;

            const write_before_read = try temporal.checkHappensBefore(snapshot, .{
                .label = "io.write.success",
                .surface_label = "runtime",
            }, .{
                .label = "io.read.success",
                .surface_label = "runtime",
            });
            if (!write_before_read.check_result.passed) return write_before_read.check_result;

            const process_request_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "process.request",
                .surface_label = "process_driver",
            });
            if (!process_request_once.check_result.passed) return process_request_once.check_result;

            const process_response_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "process.response",
                .surface_label = "process_driver",
            });
            if (!process_response_once.check_result.passed) return process_response_once.check_result;
            const process_request_before_response = try temporal.checkHappensBefore(snapshot, .{
                .label = "process.request",
                .surface_label = "process_driver",
            }, .{
                .label = "process.response",
                .surface_label = "process_driver",
            });
            if (!process_request_before_response.check_result.passed) return process_request_before_response.check_result;

            const driver_stderr_once = try temporal.checkExactlyOnce(snapshot, .{
                .label = "process.stderr",
                .surface_label = "process_driver",
            });
            if (!driver_stderr_once.check_result.passed) return driver_stderr_once.check_result;

            try testing.expect(self.pool.available() == self.pool.capacity());
            return checker.CheckResult.fail(&violations, null);
        }

        const snapshot = context.traceSnapshot().?;
        const retry_before_read = try temporal.checkHappensBefore(snapshot, .{
            .label = "io.read.timeout",
            .surface_label = "runtime",
        }, .{
            .label = "io.retry.scheduled",
            .surface_label = "retry_policy",
        });
        if (!retry_before_read.check_result.passed) return retry_before_read.check_result;

        const write_before_read = try temporal.checkHappensBefore(snapshot, .{
            .label = "io.write.success",
            .surface_label = "runtime",
        }, .{
            .label = "io.read.success",
            .surface_label = "runtime",
        });
        if (!write_before_read.check_result.passed) return write_before_read.check_result;

        const process_request_once = try temporal.checkExactlyOnce(snapshot, .{
            .label = "process.request",
            .surface_label = "process_driver",
        });
        if (!process_request_once.check_result.passed) return process_request_once.check_result;

        const process_response_once = try temporal.checkExactlyOnce(snapshot, .{
            .label = "process.response",
            .surface_label = "process_driver",
        });
        if (!process_response_once.check_result.passed) return process_response_once.check_result;
        const process_request_before_response = try temporal.checkHappensBefore(snapshot, .{
            .label = "process.request",
            .surface_label = "process_driver",
        }, .{
            .label = "process.response",
            .surface_label = "process_driver",
        });
        if (!process_request_before_response.check_result.passed) return process_request_before_response.check_result;

        try testing.expect(self.pool.available() == self.pool.capacity());
        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, snapshot.items.len) << 64) |
                (@as(u128, self.pool.available()) << 32) |
                @as(u128, driver_roundtrip),
        ));
    }

    fn runEchoDriver(
        self: *@This(),
        context: *system.SystemContext(Fixture),
        cause_sequence_no: u32,
    ) !u32 {
        const argv = [_][]const u8{ driver_path, "runtime_retry_echo" };
        var driver = try process_driver.ProcessDriver.start(self.io, .{
            .argv = &argv,
            .timeout_ns_max = 500 * std.time.ns_per_ms,
        });
        defer driver.deinit();

        const request_id = try driver.sendRequest(.echo, "hello");
        const request_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "process.request",
            .input,
            "process_driver",
            cause_sequence_no,
            request_id,
        );

        var payload_buffer: [16]u8 = undefined;
        const response = try driver.recvResponse(&payload_buffer);
        try testing.expectEqual(request_id, response.header.request_id);
        try testing.expectEqual(driver_protocol.DriverMessageKind.ok, response.header.kind);
        try testing.expectEqualStrings("hello", response.payload);

        _ = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "process.response",
            .check,
            "process_driver",
            request_seq,
            response.payload.len,
        );
        try driver.shutdown();
        return request_id;
    }

    fn runMalformedDriver(
        self: *@This(),
        context: *system.SystemContext(Fixture),
        cause_sequence_no: u32,
    ) !u32 {
        var stderr_capture_buffer: [128]u8 = undefined;
        const argv = [_][]const u8{ driver_path, "runtime_malformed_stderr" };
        var driver = try process_driver.ProcessDriver.start(self.io, .{
            .argv = &argv,
            .timeout_ns_max = 500 * std.time.ns_per_ms,
            .stderr_capture_buffer = &stderr_capture_buffer,
        });
        defer driver.deinit();

        const request_id = try driver.sendRequest(.ping, &.{});
        _ = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "process.failure.request",
            .input,
            "process_driver",
            cause_sequence_no,
            request_id,
        );

        var payload_buffer: [1]u8 = undefined;
        try testing.expectError(error.Unsupported, driver.recvResponse(&payload_buffer));

        const captured_stderr = driver.capturedStderr().?;
        try testing.expectEqualStrings("runtime child emitted malformed response\n", captured_stderr.bytes);

        return try support.appendEvent(
            context,
            &self.next_sequence_no,
            "process.stderr",
            .info,
            "process_driver",
            cause_sequence_no,
            @intCast(captured_stderr.bytes.len),
        );
    }
};

fn initFixture(fixture: *Fixture) !void {
    try fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(41),
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 64 },
    });
}

test "static_io system composes process_driver and runtime retry flow" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

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

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var runner = Runner{
        .io = threaded_io.io(),
        .runtime = &runtime,
        .pool = &pool,
        .mode = .pass,
    };

    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_process_driver_runtime_retry",
        .seed = .init(101),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, Runner, anyerror, &fixture, run_identity, .{
        .components = &components,
    }, &runner, Runner.run);

    try testing.expect(execution.check_result.passed);
    try testing.expectEqual(@as(usize, components.len), execution.component_count);
    try testing.expect(execution.trace_metadata.event_count >= 10);
    try testing.expect(execution.retained_bundle == null);
}

test "static_io system retains provenance and stderr through process_driver failure" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

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

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [2048]u8 = undefined;
    var trace_buffer_storage: [512]u8 = undefined;
    var retained_trace_file_buffer: [2048]u8 = undefined;
    var retained_trace_frame_buffer: [512]u8 = undefined;
    var violations_buffer: [1024]u8 = undefined;
    const expected_stderr = "runtime child emitted malformed response\n";

    var runner = Runner{
        .io = threaded_io.io(),
        .runtime = &runtime,
        .pool = &pool,
        .mode = .fail_with_driver_stderr,
    };

    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "system_process_driver_runtime_retry_failure",
        .seed = .init(202),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, Runner, anyerror, &fixture, run_identity, .{
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
            .stderr_capture = .{ .bytes = expected_stderr, .truncated = false },
        },
    }, &runner, Runner.run);

    try testing.expect(!execution.check_result.passed);
    try testing.expect(execution.retained_bundle != null);

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
    var read_stderr_buffer: [128]u8 = undefined;

    const bundle = try failure_bundle.readFailureBundle(threaded_io.io(), tmp_dir.dir, execution.retained_bundle.?.entry_name, .{
        .selection = .{
            .trace_artifact = .summary_and_retained,
            .text_capture = .stderr_only,
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
        .stderr_buffer = &read_stderr_buffer,
    });

    try testing.expectEqualStrings("system_process_driver_runtime_retry_failure", bundle.manifest_document.run_name);
    try testing.expect(bundle.trace_document != null);
    try testing.expect(bundle.trace_document.?.has_provenance);
    try testing.expect(bundle.trace_document.?.caused_event_count > 0);
    try testing.expect(bundle.retained_trace != null);
    try testing.expectEqualStrings(expected_stderr, bundle.stderr_capture.?);
    try testing.expectEqualStrings("static_io.system_process_driver_runtime_retry", bundle.violations_document.violations[0].code);
}
