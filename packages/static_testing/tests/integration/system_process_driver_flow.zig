const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");
const integration_options = @import("static_testing_integration_options");

const process_driver = static_testing.testing.process_driver;
const system = static_testing.testing.system;
const temporal = static_testing.testing.temporal;

test "system harness composes process drivers with deterministic retention" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 16) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(808),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 16 },
    });
    defer sim_fixture.deinit();

    var response_mailbox = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 4 },
    );
    defer response_mailbox.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const components = [_]system.ComponentSpec{
        .{ .name = "echo_driver" },
        .{ .name = "response_mailbox" },
    };
    const run_identity = static_testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_process_driver_flow",
        .seed = .init(808),
        .build_mode = .debug,
        .case_index = 2,
        .run_index = 1,
    });
    const violations = [_]static_testing.testing.checker.Violation{
        .{ .code = "system_process_boundary_failure", .message = "intentionally retained process-boundary failure" },
    };
    const argv = [_][]const u8{ integration_options.driver_echo_path, "echo" };

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [2048]u8 = undefined;
    var trace_buffer: [512]u8 = undefined;
    var retained_trace_file_buffer: [2048]u8 = undefined;
    var retained_trace_frame_buffer: [512]u8 = undefined;
    var violations_buffer: [1024]u8 = undefined;

    const Runner = struct {
        io: std.Io,
        argv: []const []const u8,
        mailbox: *static_testing.testing.sim.mailbox.Mailbox(u32),
        stderr_capture: [128]u8 = undefined,
        next_sequence_no: u32 = 0,

        fn run(
            self: *@This(),
            context: *system.SystemContext(@TypeOf(sim_fixture)),
        ) anyerror!static_testing.testing.checker.CheckResult {
            try testing.expect(context.hasComponent("echo_driver"));
            try testing.expect(context.hasComponent("response_mailbox"));

            _ = try context.appendTraceEvent(
                &self.next_sequence_no,
                "system.start",
                .decision,
                "system",
                null,
                1,
            );

            var driver = try process_driver.ProcessDriver.start(self.io, .{
                .argv = self.argv,
                .timeout_ns_max = 500 * std.time.ns_per_ms,
                .stderr_capture_buffer = &self.stderr_capture,
            });
            defer driver.deinit();

            const request_id = try driver.sendRequest(.echo, "hello");
            const request_seq = try context.appendTraceEvent(
                &self.next_sequence_no,
                "process.request",
                .input,
                "echo_driver",
                null,
                request_id,
            );

            var payload_buffer: [16]u8 = undefined;
            const response = try driver.recvResponse(&payload_buffer);
            try testing.expectEqual(request_id, response.header.request_id);
            try testing.expectEqual(static_testing.testing.driver_protocol.DriverMessageKind.ok, response.header.kind);
            try testing.expectEqualStrings("hello", response.payload);

            try self.mailbox.send(@intCast(response.payload.len));
            try testing.expectEqual(@as(u32, 5), try self.mailbox.recv());

            _ = try context.fixture.sim_clock.advance(.init(1));
            const response_seq = try context.appendTraceEvent(
                &self.next_sequence_no,
                "process.response",
                .info,
                "echo_driver",
                request_seq,
                response.payload.len,
            );
            _ = try context.appendTraceEvent(
                &self.next_sequence_no,
                "system.failed",
                .check,
                "system",
                response_seq,
                1,
            );

            try driver.shutdown();

            const snapshot = context.traceSnapshot().?;
            const ordering = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "process.request", .surface_label = "echo_driver" },
                .{ .label = "process.response", .surface_label = "echo_driver" },
            );
            try testing.expect(ordering.check_result.passed);

            const response_once = try temporal.checkExactlyOnce(
                snapshot,
                .{ .label = "process.response", .surface_label = "echo_driver" },
            );
            try testing.expect(response_once.check_result.passed);

            return static_testing.testing.checker.CheckResult.fail(&violations, null);
        }
    };
    var runner = Runner{
        .io = io,
        .argv = &argv,
        .mailbox = &response_mailbox,
    };

    const execution = try system.runWithFixture(@TypeOf(sim_fixture), Runner, anyerror, &sim_fixture, run_identity, .{
        .components = &components,
        .failure_persistence = .{
            .bundle_persistence = .{
                .io = io,
                .dir = tmp_dir.dir,
                .entry_name_buffer = &entry_name_buffer,
                .artifact_buffer = &artifact_buffer,
                .manifest_buffer = &manifest_buffer,
                .trace_buffer = &trace_buffer,
                .retained_trace_file_buffer = &retained_trace_file_buffer,
                .retained_trace_frame_buffer = &retained_trace_frame_buffer,
                .violations_buffer = &violations_buffer,
            },
            .artifact_selection = .{ .trace_artifact = .summary_and_retained },
        },
    }, &runner, Runner.run);

    try testing.expect(!execution.check_result.passed);
    try testing.expect(execution.retained_bundle != null);
    try testing.expectEqual(@as(u32, 4), execution.trace_metadata.event_count);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [static_testing.testing.failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [static_testing.testing.failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [static_testing.testing.failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [static_testing.testing.failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [2048]u8 = undefined;
    var read_retained_events: [16]static_testing.testing.trace.TraceEvent = undefined;
    var read_retained_labels: [512]u8 = undefined;
    var read_violations_source: [static_testing.testing.failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [static_testing.testing.failure_bundle.recommended_violations_parse_len]u8 = undefined;

    const bundle = try static_testing.testing.failure_bundle.readFailureBundle(
        io,
        tmp_dir.dir,
        execution.retained_bundle.?.entry_name,
        .{
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
        },
    );

    try testing.expectEqualStrings("system_process_driver_flow", bundle.manifest_document.run_name);
    try testing.expect(bundle.trace_document != null);
    try testing.expect(bundle.trace_document.?.has_provenance);
    try testing.expect(bundle.retained_trace != null);
    try testing.expectEqual(@as(usize, 4), bundle.retained_trace.?.items.len);
    try testing.expectEqualStrings("system_process_boundary_failure", bundle.violations_document.violations[0].code);
}
