const std = @import("std");
const assert = std.debug.assert;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const ProtocolState = enum {
    idle,
    syn_sent,
    established,
    closed,
};

const ActionTag = enum(u32) {
    connect = 1,
    send_payload = 2,
    ack = 3,
    close = 4,
};

pub fn main() !void {
    const violations = [_]checker.Violation{
        .{
            .code = "protocol_transition",
            .message = "action was not valid for the current protocol state",
        },
    };

    const Context = struct {
        state: ProtocolState = .idle,

        fn reset(context_ptr: *anyopaque, _: identity.RunIdentity) error{}!void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.state = .idle;
        }

        fn nextAction(
            _: *anyopaque,
            _: identity.RunIdentity,
            action_index: u32,
            _: seed.Seed,
        ) error{}!model.RecordedAction {
            return switch (action_index) {
                0 => .{ .tag = @intFromEnum(ActionTag.connect) },
                1 => .{ .tag = @intFromEnum(ActionTag.send_payload), .value = 64 },
                2 => .{ .tag = @intFromEnum(ActionTag.ack) },
                else => .{ .tag = @intFromEnum(ActionTag.close) },
            };
        }

        fn step(
            context_ptr: *anyopaque,
            _: identity.RunIdentity,
            _: u32,
            action: model.RecordedAction,
        ) error{}!model.ModelStep {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            const tag: ActionTag = @enumFromInt(action.tag);

            switch (context.state) {
                .idle => switch (tag) {
                    .connect => {
                        context.state = .syn_sent;
                        return .{ .check_result = checker.CheckResult.pass(null) };
                    },
                    else => return .{ .check_result = checker.CheckResult.fail(&violations, null) },
                },
                .syn_sent => switch (tag) {
                    .ack => {
                        context.state = .established;
                        return .{ .check_result = checker.CheckResult.pass(null) };
                    },
                    else => return .{ .check_result = checker.CheckResult.fail(&violations, null) },
                },
                .established => switch (tag) {
                    .send_payload => return .{ .check_result = checker.CheckResult.pass(null) },
                    .close => {
                        context.state = .closed;
                        return .{
                            .check_result = checker.CheckResult.pass(null),
                            .stop_after_step = true,
                        };
                    },
                    else => return .{ .check_result = checker.CheckResult.fail(&violations, null) },
                },
                .closed => return .{ .check_result = checker.CheckResult.fail(&violations, null) },
            }
        }

        fn finish(context_ptr: *anyopaque, _: identity.RunIdentity, _: u32) error{}!checker.CheckResult {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            return if (context.state == .closed)
                checker.CheckResult.pass(null)
            else
                checker.CheckResult.fail(&violations, null);
        }

        fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
            return .{
                .label = switch (@as(ActionTag, @enumFromInt(action.tag))) {
                    .connect => "connect",
                    .send_payload => "send_payload",
                    .ack => "ack",
                    .close => "close",
                },
            };
        }
    };

    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});
    var context = Context{};
    var action_storage: [8]model.RecordedAction = undefined;
    var reduction_scratch: [8]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "model_protocol_state_example",
            .base_seed = .init(41),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = 4,
        },
        .target = Target{
            .context = &context,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    assert(summary.failed_case != null);
    var summary_buffer: [512]u8 = undefined;
    const summary_text = try model.formatFailedCaseSummary(error{}, &summary_buffer, Target{
        .context = &context,
        .reset_fn = Context.reset,
        .next_action_fn = Context.nextAction,
        .step_fn = Context.step,
        .finish_fn = Context.finish,
        .describe_action_fn = Context.describe,
    }, summary.failed_case.?);
    std.debug.print("{s}", .{summary_text});
}
