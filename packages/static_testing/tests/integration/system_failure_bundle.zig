const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const system = static_testing.testing.system;

test "system harness persists a retained failure bundle with provenance" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 16) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(404),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 16 },
    });
    defer sim_fixture.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const components = [_]system.ComponentSpec{
        .{ .name = "network_link" },
        .{ .name = "storage_lane" },
        .{ .name = "retry_queue" },
    };
    const run_identity = static_testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_failure_bundle_integration",
        .seed = .init(404),
        .build_mode = .debug,
        .case_index = 4,
        .run_index = 1,
    });
    const violations = [_]static_testing.testing.checker.Violation{
        .{ .code = "system_temporal_failure", .message = "intentionally failed composed flow" },
    };

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [2048]u8 = undefined;
    var trace_buffer: [512]u8 = undefined;
    var retained_trace_file_buffer: [2048]u8 = undefined;
    var retained_trace_frame_buffer: [512]u8 = undefined;
    var violations_buffer: [1024]u8 = undefined;

    const Context = struct {
        fn run(_: *void, context: *system.SystemContext(@TypeOf(sim_fixture))) anyerror!static_testing.testing.checker.CheckResult {
            try testing.expect(context.hasComponent("network_link"));
            try testing.expect(context.hasComponent("storage_lane"));
            try testing.expect(context.hasComponent("retry_queue"));

            var next_sequence_no: u32 = 0;
            const start_seq = try context.appendTraceEvent(
                &next_sequence_no,
                "system.start",
                .decision,
                "system",
                null,
                11,
            );
            _ = try context.fixture.sim_clock.advance(.init(1));
            _ = try context.appendTraceEvent(
                &next_sequence_no,
                "system.failed",
                .check,
                "system",
                start_seq,
                11,
            );

            return static_testing.testing.checker.CheckResult.fail(&violations, null);
        }
    };
    var user_context = {};

    const execution = try system.runWithFixture(@TypeOf(sim_fixture), void, anyerror, &sim_fixture, run_identity, .{
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
    }, &user_context, Context.run);

    try testing.expect(!execution.check_result.passed);
    try testing.expect(execution.retained_bundle != null);

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

    try testing.expectEqualStrings("system_failure_bundle_integration", bundle.manifest_document.run_name);
    try testing.expect(bundle.trace_document != null);
    try testing.expect(bundle.trace_document.?.has_provenance);
    try testing.expect(bundle.retained_trace != null);
    try testing.expectEqual(@as(usize, 2), bundle.retained_trace.?.items.len);
    try testing.expectEqualStrings("system_temporal_failure", bundle.violations_document.violations[0].code);
}
