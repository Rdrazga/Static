const std = @import("std");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const failure_bundle = static_testing.testing.failure_bundle;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;
const trace = static_testing.testing.trace;

test "model harness persists recorded actions and replays them" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const TargetError = error{} || trace.TraceAppendError;

    const Context = struct {
        const violations = [_]checker.Violation{
            .{ .code = "force_fail", .message = "recorded action failed" },
        };

        trace_buffer: trace.TraceBuffer,
        primed: bool = false,
        confirmed: bool = false,

        fn reset(context_ptr: *anyopaque, _: identity.RunIdentity) TargetError!void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.trace_buffer.reset();
            context.primed = false;
            context.confirmed = false;
        }

        fn nextAction(_: *anyopaque, _: identity.RunIdentity, action_index: u32, _: seed.Seed) TargetError!model.RecordedAction {
            return switch (action_index) {
                0 => .{ .tag = 7 },
                1 => .{ .tag = 8 },
                else => .{ .tag = 999 },
            };
        }

        fn step(context_ptr: *anyopaque, _: identity.RunIdentity, action_index: u32, action: model.RecordedAction) TargetError!model.ModelStep {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            try context.trace_buffer.append(.{
                .timestamp_ns = action_index,
                .category = .info,
                .label = switch (action.tag) {
                    7 => "prime",
                    8 => "confirm",
                    999 => "force_fail",
                    else => "unknown",
                },
                .value = action.value,
                .lineage = if (action_index == 0)
                    .{}
                else
                    .{
                        .cause_sequence_no = action_index - 1,
                        .correlation_id = 51,
                        .surface_label = "model_roundtrip",
                    },
            });
            switch (action.tag) {
                7 => context.primed = true,
                8 => {
                    if (context.primed) context.confirmed = true;
                },
                999 => {},
                else => {},
            }
            if (action.tag == 999) {
                return .{
                    .check_result = if (context.primed and context.confirmed)
                        checker.CheckResult.fail(&violations, null)
                    else
                        checker.CheckResult.pass(null),
                };
            }
            return .{
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn finish(_: *anyopaque, _: identity.RunIdentity, _: u32) TargetError!checker.CheckResult {
            return checker.CheckResult.pass(null);
        }

        fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
            return .{
                .label = switch (action.tag) {
                    7 => "prime",
                    8 => "confirm",
                    999 => "force_fail",
                    else => "unknown",
                },
            };
        }

        fn traceSnapshot(context_ptr: *anyopaque) ?trace.TraceSnapshot {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            return context.trace_buffer.snapshot();
        }
    };

    const Target = model.ModelTarget(TargetError);
    const Runner = model.ModelRunner(TargetError);
    var trace_storage: [8]trace.TraceEvent = undefined;
    var context = Context{
        .trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{
            .max_events = trace_storage.len,
        }),
    };
    var action_storage: [8]model.RecordedAction = undefined;
    var reduction_scratch: [8]model.RecordedAction = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var retained_trace_file_buffer: [1024]u8 = undefined;
    var retained_trace_frame_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    var action_bytes_buffer: [256]u8 = undefined;
    var action_document_buffer: [1024]u8 = undefined;
    var action_document_entries: [8]model.RecordedActionDocumentEntry = undefined;

    const summary = try model.runModelCases(TargetError, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "model_roundtrip",
            .base_seed = .init(51),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = 3,
        },
        .target = Target{
            .context = &context,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
            .trace_snapshot_fn = Context.traceSnapshot,
        },
        .persistence = .{
            .failure_bundle = .{
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
            .failure_bundle_context = .{
                .artifact_selection = .{ .trace_artifact = .summary_and_retained },
            },
            .action_bytes_buffer = &action_bytes_buffer,
            .action_document_buffer = &action_document_buffer,
            .action_document_entries = &action_document_entries,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    try std.testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try std.testing.expect(failed_case.persisted_entry_name != null);

    var replay_actions: [8]model.RecordedAction = undefined;
    var replay_action_bytes: [256]u8 = undefined;
    var replay_action_document_source: [1024]u8 = undefined;
    var replay_action_document_parse: [4096]u8 = undefined;
    const recorded = try model.readRecordedActions(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        .{
            .actions_buffer = &replay_actions,
            .action_bytes_buffer = &replay_action_bytes,
            .action_document_source_buffer = &replay_action_document_source,
            .action_document_parse_buffer = &replay_action_document_parse,
        },
    );
    try std.testing.expect(recorded.action_document != null);
    try std.testing.expectEqualStrings(
        "force_fail",
        recorded.action_document.?.actions[recorded.action_document.?.actions.len - 1].label,
    );

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [1024]u8 = undefined;
    var read_retained_events: [8]trace.TraceEvent = undefined;
    var read_retained_labels: [256]u8 = undefined;
    var read_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse_buffer: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const retained_bundle = try failure_bundle.readFailureBundle(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        .{
            .selection = .{
                .trace_artifact = .summary_and_retained,
            },
            .artifact_buffer = &read_artifact_buffer,
            .manifest_buffer = &read_manifest_buffer,
            .manifest_parse_buffer = &read_manifest_parse_buffer,
            .trace_buffer = &read_trace_buffer,
            .trace_parse_buffer = &read_trace_parse_buffer,
            .retained_trace_file_buffer = &read_retained_trace_file,
            .retained_trace_events_buffer = &read_retained_events,
            .retained_trace_label_buffer = &read_retained_labels,
            .violations_buffer = &read_violations_buffer,
            .violations_parse_buffer = &read_violations_parse_buffer,
        },
    );
    try std.testing.expect(retained_bundle.trace_document != null);
    try std.testing.expect(retained_bundle.retained_trace != null);
    try std.testing.expect(retained_bundle.trace_document.?.has_provenance);
    try std.testing.expectEqual(@as(usize, 3), retained_bundle.retained_trace.?.items.len);
    try std.testing.expectEqualStrings(
        "model_roundtrip",
        retained_bundle.retained_trace.?.items[1].lineage.surface_label.?,
    );

    const replay_execution = try model.replayRecordedActions(
        TargetError,
        Target{
            .context = &context,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
            .trace_snapshot_fn = Context.traceSnapshot,
        },
        failed_case.run_identity,
        recorded.actions,
    );
    try std.testing.expect(!replay_execution.check_result.passed);
    try std.testing.expectEqual(failed_case.recorded_actions.len, recorded.actions.len);
    try std.testing.expect(replay_execution.trace_provenance_summary != null);
    try std.testing.expect(replay_execution.retained_trace_snapshot != null);
}
