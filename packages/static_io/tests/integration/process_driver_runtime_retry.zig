const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");
const integration_options = @import("static_io_integration_options");

const driver_path: []const u8 = integration_options.driver_runtime_echo_path;
const checker = static_testing.testing.checker;
const failure_bundle = static_testing.testing.failure_bundle;
const identity = static_testing.testing.identity;
const process_driver = static_testing.testing.process_driver;
const trace = static_testing.testing.trace;

test "static_io runtime child roundtrips through process_driver after bounded retry" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const argv = [_][]const u8{ driver_path, "runtime_retry_echo" };
    var driver = try process_driver.ProcessDriver.start(threaded_io.io(), .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
    });
    defer driver.deinit();

    const request_id = try driver.sendRequest(.echo, "hello");
    var payload_buffer: [16]u8 = undefined;
    const response = try driver.recvResponse(&payload_buffer);
    try testing.expectEqual(request_id, response.header.request_id);
    try testing.expectEqual(static_testing.testing.driver_protocol.DriverMessageKind.ok, response.header.kind);
    try testing.expectEqualStrings("hello", response.payload);

    try driver.shutdown();
}

test "static_io process-driver failure bundle retains malformed child stderr" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var stderr_capture_buffer: [128]u8 = undefined;
    const argv = [_][]const u8{ driver_path, "runtime_malformed_stderr" };
    var driver = try process_driver.ProcessDriver.start(io, .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
        .stderr_capture_buffer = &stderr_capture_buffer,
    });
    defer driver.deinit();

    _ = try driver.sendRequest(.ping, &.{});
    var payload_buffer: [1]u8 = undefined;
    try testing.expectError(error.Unsupported, driver.recvResponse(&payload_buffer));

    const captured_stderr = driver.capturedStderr();
    try testing.expect(captured_stderr != null);
    try testing.expect(std.mem.indexOf(u8, captured_stderr.?.bytes, "runtime child emitted malformed response") != null);

    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_io",
        .run_name = "process_driver_runtime_malformed",
        .seed = .init(313),
        .build_mode = .debug,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 1,
        .last_sequence_no = 1,
        .first_timestamp_ns = 1,
        .last_timestamp_ns = 1,
    };
    const violations = [_]checker.Violation{
        .{ .code = "static_io.process_driver_protocol", .message = "runtime child returned malformed protocol bytes" },
    };
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    const written = try failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "static_io_process_driver", .extension = ".bundle" },
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, checker.CheckResult.fail(
        &violations,
        null,
    ), .{
        .stderr_capture = .{
            .bytes = captured_stderr.?.bytes,
            .truncated = captured_stderr.?.truncated,
        },
    });

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse_buffer: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    var read_stdout_buffer: [32]u8 = undefined;
    var read_stderr_buffer: [128]u8 = undefined;
    const bundle = try failure_bundle.readFailureBundle(io, tmp_dir.dir, written.entry_name, .{
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

    try testing.expectEqualStrings("process_driver_runtime_malformed", bundle.manifest_document.run_name);
    try testing.expect(bundle.stdout_capture == null);
    try testing.expect(bundle.stderr_capture != null);
    try testing.expect(std.mem.indexOf(u8, bundle.stderr_capture.?, "runtime child emitted malformed response") != null);
}
