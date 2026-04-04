const std = @import("std");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

pub fn main() !void {
    const violations = [_]checker.Violation{
        .{ .code = "bad_action", .message = "force-fail action reached the model" },
    };

    const Context = struct {
        fn reset(_: *anyopaque, _: identity.RunIdentity) error{}!void {}

        fn nextAction(_: *anyopaque, _: identity.RunIdentity, action_index: u32, _: seed.Seed) error{}!model.RecordedAction {
            return switch (action_index) {
                0 => .{ .tag = 1 },
                1 => .{ .tag = 2 },
                else => .{ .tag = 99 },
            };
        }

        fn step(_: *anyopaque, _: identity.RunIdentity, _: u32, action: model.RecordedAction) error{}!model.ModelStep {
            if (action.tag == 99) {
                return .{
                    .check_result = checker.CheckResult.fail(&violations, null),
                };
            }
            return .{
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn finish(_: *anyopaque, _: identity.RunIdentity, _: u32) error{}!checker.CheckResult {
            return checker.CheckResult.pass(null);
        }

        fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
            return .{
                .label = switch (action.tag) {
                    1 => "set",
                    2 => "reset",
                    99 => "force_fail",
                    else => "unknown",
                },
            };
        }
    };

    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});
    var action_storage: [8]model.RecordedAction = undefined;
    var reduction_scratch: [8]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "model_state_machine_example",
            .base_seed = .init(23),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = 3,
        },
        .target = Target{
            .context = undefined,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    if (summary.failed_case) |failed_case| {
        var summary_buffer: [512]u8 = undefined;
        const summary_text = try model.formatFailedCaseSummary(error{}, &summary_buffer, Target{
            .context = undefined,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
        }, failed_case);
        std.debug.print("{s}", .{summary_text});
        return;
    }

    std.debug.print("model example completed without failures\n", .{});
}
