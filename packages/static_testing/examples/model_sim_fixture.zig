const std = @import("std");
const assert = std.debug.assert;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;
const sim = static_testing.testing.sim;
const trace = static_testing.testing.trace;

const ActionTag = enum(u32) {
    schedule_primary = 1,
    schedule_secondary = 2,
    deliver_next = 3,
    recv_expected = 4,
    assert_roundtrip = 99,
};

pub fn main() !void {
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
        }

        fn nextAction(
            _: *anyopaque,
            _: identity.RunIdentity,
            action_index: u32,
            _: seed.Seed,
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

            switch (@as(ActionTag, @enumFromInt(action.tag))) {
                .schedule_primary => {
                    _ = try context.sim_fixture.scheduleAfter(.{ .id = @intCast(action.value) }, .init(1));
                    return .{ .check_result = checker.CheckResult.pass(null) };
                },
                .schedule_secondary => {
                    _ = try context.sim_fixture.scheduleAfter(.{ .id = @intCast(action.value) }, .init(2));
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

        fn deliverNext(self: *@This()) TargetError!?u32 {
            var attempts: u32 = 0;
            while (attempts < 8) : (attempts += 1) {
                const step_result = try self.sim_fixture.step();
                if (step_result.decision) |decision| {
                    const trace_buffer = self.sim_fixture.traceBufferPtr().?;
                    const snapshot = trace_buffer.snapshot();
                    const cause_sequence_no = snapshot.items[snapshot.items.len - 1].sequence_no;
                    try trace_buffer.append(.{
                        .timestamp_ns = self.sim_fixture.sim_clock.now().tick,
                        .category = .info,
                        .label = "mailbox_send",
                        .value = decision.chosen_id,
                        .lineage = .{
                            .cause_sequence_no = cause_sequence_no,
                            .correlation_id = decision.chosen_id,
                            .surface_label = "model_sim_fixture",
                        },
                    });
                    try self.mailbox.send(decision.chosen_id);
                    self.delivery_count += 1;
                    return decision.chosen_id;
                }
            }
            return null;
        }

        fn recvExpected(self: *@This(), expected: u32) TargetError!void {
            const received = self.mailbox.recv() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (received != expected) return;

            const trace_buffer = self.sim_fixture.traceBufferPtr().?;
            const snapshot = trace_buffer.snapshot();
            const cause_sequence_no = snapshot.items[snapshot.items.len - 1].sequence_no;
            try trace_buffer.append(.{
                .timestamp_ns = self.sim_fixture.sim_clock.now().tick,
                .category = .info,
                .label = "mailbox_recv",
                .value = received,
                .lineage = .{
                    .cause_sequence_no = cause_sequence_no,
                    .correlation_id = received,
                    .surface_label = "model_sim_fixture",
                },
            });

            switch (received) {
                11 => self.saw_primary = true,
                22 => self.saw_secondary = true,
                else => {},
            }
        }

        fn roundtripComplete(self: *@This()) bool {
            const provenance = self.sim_fixture.traceProvenanceSummary() orelse return false;
            return self.delivery_count == 2 and
                self.saw_primary and
                self.saw_secondary and
                self.sim_fixture.recordedDecisions().len == 2 and
                provenance.has_provenance and
                provenance.surface_labeled_event_count >= 2;
        }
    };

    const Target = model.ModelTarget(TargetError);
    const Runner = model.ModelRunner(TargetError);
    var context = Context{
        .allocator = std.heap.page_allocator,
    };
    defer context.deinit();

    var action_storage: [8]model.RecordedAction = undefined;
    var reduction_scratch: [8]model.RecordedAction = undefined;
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
            .run_name = "model_sim_fixture_example",
            .base_seed = .init(73),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = 7,
        },
        .target = target,
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    assert(summary.failed_case != null);
    var summary_buffer: [768]u8 = undefined;
    const summary_text = try model.formatFailedCaseSummary(TargetError, &summary_buffer, target, summary.failed_case.?);
    std.debug.print("{s}", .{summary_text});
}
