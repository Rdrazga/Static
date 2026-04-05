const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const failure_bundle = static_testing.testing.failure_bundle;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const sim = static_testing.testing.sim;
const trace = static_testing.testing.trace;

const ActionTag = enum(u32) {
    schedule_primary = 1,
    schedule_secondary = 2,
    deliver_next = 3,
    recv_expected = 4,
    assert_roundtrip = 99,
};

test "model harness drives sim fixture, retains provenance, and replays recorded actions" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const Fixture = sim.fixture.Fixture(4, 4, 4, 32);
    const TargetError = sim.fixture.FixtureError || sim.mailbox.MailboxError;

    const roundtrip_complete_violations = [_]checker.Violation{
        .{
            .code = "sim_roundtrip_complete",
            .message = "sim-backed model roundtrip reached the retained-failure check",
        },
    };

    const Context = struct {
        allocator: std.mem.Allocator,
        sim_fixture: Fixture = undefined,
        mailbox: sim.mailbox.Mailbox(u32) = undefined,
        initialized: bool = false,
        saw_primary: bool = false,
        saw_secondary: bool = false,
        delivery_count: u32 = 0,

        fn deinit(self: *@This()) void {
            if (!self.initialized) return;
            self.mailbox.deinit();
            self.sim_fixture.deinit();
            self.initialized = false;
        }

        fn reset(context_ptr: *anyopaque, run_identity: identity.RunIdentity) TargetError!void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.deinit();

            try context.sim_fixture.init(.{
                .allocator = context.allocator,
                .timer_queue_config = .{
                    .buckets = 8,
                    .timers_max = 8,
                },
                .scheduler_seed = run_identity.seed,
                .scheduler_config = .{ .strategy = .first },
                .event_loop_config = .{ .step_budget_max = 8 },
                .trace_config = .{ .max_events = 32 },
            });
            context.mailbox = try sim.mailbox.Mailbox(u32).init(context.allocator, .{
                .capacity = 4,
            });
            context.initialized = true;
            context.saw_primary = false;
            context.saw_secondary = false;
            context.delivery_count = 0;

            assert(context.sim_fixture.traceBufferPtr() != null);
            assert(context.mailbox.len() == 0);
        }

        fn nextAction(
            _: *anyopaque,
            _: identity.RunIdentity,
            action_index: u32,
            _: static_testing.testing.seed.Seed,
        ) TargetError!model.RecordedAction {
            return switch (action_index) {
                0 => .{ .tag = @intFromEnum(ActionTag.schedule_primary), .value = 11 },
                1 => .{ .tag = @intFromEnum(ActionTag.schedule_secondary), .value = 22 },
                2 => .{ .tag = @intFromEnum(ActionTag.deliver_next) },
                3 => .{ .tag = @intFromEnum(ActionTag.recv_expected), .value = 11 },
                4 => .{ .tag = @intFromEnum(ActionTag.deliver_next) },
                5 => .{ .tag = @intFromEnum(ActionTag.recv_expected), .value = 22 },
                else => .{ .tag = @intFromEnum(ActionTag.assert_roundtrip) },
            };
        }

        fn step(
            context_ptr: *anyopaque,
            _: identity.RunIdentity,
            _: u32,
            action: model.RecordedAction,
        ) TargetError!model.ModelStep {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            assert(context.initialized);

            switch (@as(ActionTag, @enumFromInt(action.tag))) {
                .schedule_primary => {
                    try context.scheduleAfter(@intCast(action.value), 1);
                    return .{ .check_result = checker.CheckResult.pass(null) };
                },
                .schedule_secondary => {
                    try context.scheduleAfter(@intCast(action.value), 2);
                    return .{ .check_result = checker.CheckResult.pass(null) };
                },
                .deliver_next => {
                    _ = try context.deliverNext();
                    return .{ .check_result = checker.CheckResult.pass(null) };
                },
                .recv_expected => {
                    try context.recvExpected(@intCast(action.value));
                    return .{ .check_result = checker.CheckResult.pass(null) };
                },
                .assert_roundtrip => {
                    return .{
                        .check_result = if (context.roundtripComplete())
                            checker.CheckResult.fail(&roundtrip_complete_violations, null)
                        else
                            checker.CheckResult.pass(null),
                    };
                },
            }
        }

        fn finish(_: *anyopaque, _: identity.RunIdentity, _: u32) TargetError!checker.CheckResult {
            return checker.CheckResult.pass(null);
        }

        fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
            return .{
                .label = switch (@as(ActionTag, @enumFromInt(action.tag))) {
                    .schedule_primary => "schedule_primary",
                    .schedule_secondary => "schedule_secondary",
                    .deliver_next => "deliver_next",
                    .recv_expected => "recv_expected",
                    .assert_roundtrip => "assert_roundtrip",
                },
            };
        }

        fn traceSnapshot(context_ptr: *anyopaque) ?trace.TraceSnapshot {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            if (!context.initialized) return null;
            return context.sim_fixture.traceSnapshot();
        }

        fn scheduleAfter(self: *@This(), chosen_id: u32, delay_ticks: u64) TargetError!void {
            assert(self.initialized);
            _ = try self.sim_fixture.scheduleAfter(.{ .id = chosen_id }, .init(delay_ticks));
        }

        fn deliverNext(self: *@This()) TargetError!?u32 {
            assert(self.initialized);

            var attempts: u32 = 0;
            while (attempts < 8) : (attempts += 1) {
                const step_result = try self.sim_fixture.step();
                if (step_result.decision) |decision| {
                    try self.appendLinkedTraceEvent("mailbox_send", decision.chosen_id);
                    try self.mailbox.send(decision.chosen_id);
                    self.delivery_count += 1;
                    return decision.chosen_id;
                }
            }

            return null;
        }

        fn recvExpected(self: *@This(), expected: u32) TargetError!void {
            assert(self.initialized);

            const received = self.mailbox.recv() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (received != expected) return;

            try self.appendLinkedTraceEvent("mailbox_recv", received);
            switch (received) {
                11 => self.saw_primary = true,
                22 => self.saw_secondary = true,
                else => {},
            }
        }

        fn roundtripComplete(self: *@This()) bool {
            assert(self.initialized);

            const provenance = self.sim_fixture.traceProvenanceSummary() orelse return false;
            return self.delivery_count == 2 and
                self.saw_primary and
                self.saw_secondary and
                self.sim_fixture.recordedDecisions().len == 2 and
                provenance.has_provenance and
                provenance.surface_labeled_event_count >= 2;
        }

        fn appendLinkedTraceEvent(self: *@This(), label: []const u8, value: u32) TargetError!void {
            const trace_buffer = self.sim_fixture.traceBufferPtr().?;
            const snapshot = trace_buffer.snapshot();
            assert(snapshot.items.len != 0);
            const cause_sequence_no = snapshot.items[snapshot.items.len - 1].sequence_no;
            try trace_buffer.append(.{
                .timestamp_ns = self.sim_fixture.sim_clock.now().tick,
                .category = .info,
                .label = label,
                .value = value,
                .lineage = .{
                    .cause_sequence_no = cause_sequence_no,
                    .correlation_id = value,
                    .surface_label = "model_sim_fixture",
                },
            });
        }
    };

    const Target = model.ModelTarget(TargetError);
    const Runner = model.ModelRunner(TargetError);
    var context = Context{
        .allocator = testing.allocator,
    };
    defer context.deinit();

    var action_storage: [8]model.RecordedAction = undefined;
    var reduction_scratch: [8]model.RecordedAction = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [2048]u8 = undefined;
    var trace_buffer: [1024]u8 = undefined;
    var retained_trace_file_buffer: [2048]u8 = undefined;
    var retained_trace_frame_buffer: [512]u8 = undefined;
    var violations_buffer: [512]u8 = undefined;
    var action_bytes_buffer: [512]u8 = undefined;
    var action_document_buffer: [2048]u8 = undefined;
    var action_document_entries: [8]model.RecordedActionDocumentEntry = undefined;

    const target = Target{
        .context = &context,
        .reset_fn = Context.reset,
        .next_action_fn = Context.nextAction,
        .step_fn = Context.step,
        .finish_fn = Context.finish,
        .describe_action_fn = Context.describe,
        .trace_snapshot_fn = Context.traceSnapshot,
    };

    const summary = try model.runModelCases(TargetError, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "model_sim_fixture_roundtrip",
            .base_seed = .init(73),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = 7,
        },
        .target = target,
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

    try testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try testing.expectEqual(@as(usize, 7), failed_case.recorded_actions.len);
    try testing.expectEqual(@as(u32, 7), failed_case.original_action_count);
    try testing.expectEqual(@as(?u32, 6), failed_case.failing_action_index);
    try testing.expect(failed_case.trace_provenance_summary != null);
    try testing.expect(failed_case.trace_provenance_summary.?.has_provenance);
    try testing.expectEqual(@as(u32, 2), context.delivery_count);
    try testing.expect(failed_case.persisted_entry_name != null);

    var summary_buffer: [1024]u8 = undefined;
    const summary_text = try model.formatFailedCaseSummary(TargetError, &summary_buffer, target, failed_case);
    try testing.expect(std.mem.indexOf(u8, summary_text, "trace_events=") != null);
    try testing.expect(std.mem.indexOf(u8, summary_text, "first_bad_action=6") != null);
    try testing.expect(std.mem.indexOf(u8, summary_text, "assert_roundtrip") != null);

    var replay_actions: [8]model.RecordedAction = undefined;
    var replay_action_bytes: [512]u8 = undefined;
    var replay_action_document_source: [2048]u8 = undefined;
    var replay_action_document_parse: [8192]u8 = undefined;
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
    try testing.expect(recorded.action_document != null);
    try testing.expectEqual(@as(usize, 7), recorded.actions.len);
    try testing.expectEqualStrings("schedule_primary", recorded.action_document.?.actions[0].label);
    try testing.expectEqualStrings(
        "assert_roundtrip",
        recorded.action_document.?.actions[recorded.action_document.?.actions.len - 1].label,
    );

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [2048]u8 = undefined;
    var read_retained_events: [32]trace.TraceEvent = undefined;
    var read_retained_labels: [1024]u8 = undefined;
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
    try testing.expect(retained_bundle.trace_document != null);
    try testing.expect(retained_bundle.retained_trace != null);
    try testing.expect(retained_bundle.trace_document.?.has_provenance);

    var saw_mailbox_surface = false;
    var saw_mailbox_send = false;
    var saw_mailbox_recv = false;
    for (retained_bundle.retained_trace.?.items) |event| {
        if (event.lineage.surface_label) |surface_label| {
            if (std.mem.eql(u8, surface_label, "model_sim_fixture")) {
                saw_mailbox_surface = true;
            }
        }
        if (std.mem.eql(u8, event.label, "mailbox_send")) saw_mailbox_send = true;
        if (std.mem.eql(u8, event.label, "mailbox_recv")) saw_mailbox_recv = true;
    }
    try testing.expect(saw_mailbox_surface);
    try testing.expect(saw_mailbox_send);
    try testing.expect(saw_mailbox_recv);

    const replay_execution = try model.replayRecordedActions(
        TargetError,
        target,
        failed_case.run_identity,
        recorded.actions,
    );
    try testing.expect(!replay_execution.check_result.passed);
    try testing.expectEqual(@as(u32, 7), replay_execution.executed_action_count);
    try testing.expectEqual(@as(?u32, 6), replay_execution.failing_action_index);
    try testing.expect(replay_execution.trace_provenance_summary != null);
    try testing.expect(replay_execution.trace_provenance_summary.?.has_provenance);
    try testing.expect(replay_execution.retained_trace_snapshot != null);
    try testing.expectEqual(@as(usize, 2), context.sim_fixture.recordedDecisions().len);
}
