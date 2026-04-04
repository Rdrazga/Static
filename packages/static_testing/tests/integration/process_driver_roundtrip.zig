const builtin = @import("builtin");
const std = @import("std");
const testing = @import("static_testing");
const integration_options = @import("static_testing_integration_options");

const driver_path: []const u8 = integration_options.driver_echo_path;

test "process driver exchanges requests and shuts down cleanly" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const argv = [_][]const u8{ driver_path, "echo" };
    var driver = try testing.testing.process_driver.ProcessDriver.start(threaded_io.io(), .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
    });
    defer driver.deinit();

    const request_id = try driver.sendRequest(.echo, "hello");
    var payload_buffer: [16]u8 = undefined;
    const response = try driver.recvResponse(&payload_buffer);
    try std.testing.expectEqual(request_id, response.header.request_id);
    try std.testing.expectEqual(testing.testing.driver_protocol.DriverMessageKind.ok, response.header.kind);
    try std.testing.expectEqualStrings("hello", response.payload);

    try driver.shutdown();
}

test "process driver rejects malformed responses" {
    // Method: Use the support driver's malformed mode so the parent exercises
    // protocol decode failure rather than child-process startup failure.
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const argv = [_][]const u8{ driver_path, "malformed" };
    var driver = try testing.testing.process_driver.ProcessDriver.start(threaded_io.io(), .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
    });
    defer driver.deinit();

    _ = try driver.sendRequest(.ping, &.{});
    var payload_buffer: [1]u8 = undefined;
    try std.testing.expectError(error.Unsupported, driver.recvResponse(&payload_buffer));
    try std.testing.expectError(error.ProcessFailed, driver.sendRequest(.ping, &.{}));
}

test "process driver shutdown times out when the child does not exit" {
    // Method: Keep the child responsive enough to acknowledge shutdown, then
    // hang after the reply so timeout handling reaches the wait/kill path.
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const argv = [_][]const u8{ driver_path, "hang_on_shutdown" };
    var driver = try testing.testing.process_driver.ProcessDriver.start(threaded_io.io(), .{
        .argv = &argv,
        .timeout_ns_max = 100 * std.time.ns_per_ms,
    });
    defer driver.deinit();

    try std.testing.expectError(error.Timeout, driver.shutdown());
}

test "process driver rejects payloads above the configured maximum" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const argv = [_][]const u8{ driver_path, "echo" };
    var driver = try testing.testing.process_driver.ProcessDriver.start(threaded_io.io(), .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
        .max_payload_bytes = 4,
    });
    defer driver.deinit();

    try std.testing.expectError(error.NoSpaceLeft, driver.sendRequest(.echo, "hello"));
    try driver.shutdown();
}

test "process driver rejects a second request while one is still pending" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const argv = [_][]const u8{ driver_path, "echo" };
    var driver = try testing.testing.process_driver.ProcessDriver.start(threaded_io.io(), .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
    });
    defer driver.deinit();

    const request_id = try driver.sendRequest(.echo, "hi");
    try std.testing.expectError(error.InvalidInput, driver.sendRequest(.ping, &.{}));

    var payload_buffer: [8]u8 = undefined;
    const response = try driver.recvResponse(&payload_buffer);
    try std.testing.expectEqual(request_id, response.header.request_id);
    try std.testing.expectEqualStrings("hi", response.payload);
    try driver.shutdown();
}

test "process driver drains oversized responses and keeps the session usable" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const argv = [_][]const u8{ driver_path, "echo" };
    var driver = try testing.testing.process_driver.ProcessDriver.start(threaded_io.io(), .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
        .max_payload_bytes = 16,
    });
    defer driver.deinit();

    _ = try driver.sendRequest(.echo, "hello");
    var tiny_payload_buffer: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, driver.recvResponse(&tiny_payload_buffer));

    const request_id = try driver.sendRequest(.echo, "ok");
    var payload_buffer: [8]u8 = undefined;
    const response = try driver.recvResponse(&payload_buffer);
    try std.testing.expectEqual(request_id, response.header.request_id);
    try std.testing.expectEqualStrings("ok", response.payload);
    try driver.shutdown();
}

test "process driver failure bundle retains bounded stderr capture" {
    // Goal: Preserve child-process diagnostics when protocol handling fails.
    //
    // Method: Run the support driver in a malformed-response mode that emits a
    // bounded `stderr` line before returning invalid protocol bytes, then
    // persist the resulting failure bundle and assert the sidecar survives
    // readback. `stdout` is intentionally absent because this driver reserves
    // it for protocol framing.
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var stderr_capture_buffer: [128]u8 = undefined;
    const argv = [_][]const u8{ driver_path, "malformed_stderr" };
    var driver = try testing.testing.process_driver.ProcessDriver.start(io, .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
        .stderr_capture_buffer = &stderr_capture_buffer,
    });
    defer driver.deinit();

    _ = try driver.sendRequest(.ping, &.{});
    var payload_buffer: [1]u8 = undefined;
    try std.testing.expectError(error.Unsupported, driver.recvResponse(&payload_buffer));

    const captured_stderr = driver.capturedStderr();
    try std.testing.expect(captured_stderr != null);
    try std.testing.expect(std.mem.indexOf(u8, captured_stderr.?.bytes, "driver emitted stderr") != null);

    const run_identity = testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "process_driver_failure_bundle",
        .seed = .{ .value = 212 },
        .build_mode = .debug,
        .case_index = 0,
        .run_index = 0,
    });
    const trace_metadata: testing.testing.trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 1,
        .last_sequence_no = 1,
        .first_timestamp_ns = 1,
        .last_timestamp_ns = 1,
    };
    const violations = [_]testing.testing.checker.Violation{
        .{ .code = "driver_protocol", .message = "child returned malformed response bytes" },
    };
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    const written = try testing.testing.failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "process_driver_failure", .extension = ".bundle" },
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, testing.testing.checker.CheckResult.fail(
        &violations,
        null,
    ), .{
        .stderr_capture = .{
            .bytes = captured_stderr.?.bytes,
            .truncated = captured_stderr.?.truncated,
        },
    });

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [testing.testing.failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [testing.testing.failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [testing.testing.failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [testing.testing.failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_buffer: [testing.testing.failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse_buffer: [testing.testing.failure_bundle.recommended_violations_parse_len]u8 = undefined;
    var read_stdout_buffer: [64]u8 = undefined;
    var read_stderr_buffer: [128]u8 = undefined;
    const bundle = try testing.testing.failure_bundle.readFailureBundle(io, tmp_dir.dir, written.entry_name, .{
        .selection = .{
            .trace_artifact = .summary,
            .text_capture = .stderr_only,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_buffer,
        .manifest_parse_buffer = &read_manifest_parse_buffer,
        .trace_buffer = &read_trace_buffer,
        .trace_parse_buffer = &read_trace_parse_buffer,
        .violations_buffer = &read_violations_buffer,
        .violations_parse_buffer = &read_violations_parse_buffer,
        .stdout_buffer = &read_stdout_buffer,
        .stderr_buffer = &read_stderr_buffer,
    });

    try std.testing.expect(bundle.stdout_capture == null);
    try std.testing.expect(bundle.stderr_capture != null);
    try std.testing.expectEqualStrings("stderr.txt", bundle.manifest_document.stderr_file.?);
    try std.testing.expect(std.mem.indexOf(u8, bundle.stderr_capture.?, "driver emitted stderr") != null);
}
