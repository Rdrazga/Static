const std = @import("std");
const assert = std.debug.assert;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const liveness = static_testing.testing.liveness;

pub fn main() !void {
    const Scenario = liveness.RepairLivenessScenario(error{});
    const Context = struct {
        queue_depth: u32 = 3,
        repaired: bool = false,

        fn runFault(_: *anyopaque, steps_max: u32) error{}!liveness.PhaseExecution {
            return .{
                .steps_executed = steps_max,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn transition(context_ptr: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.repaired = true;
        }

        fn runRepair(context_ptr: *anyopaque, steps_max: u32) error{}!liveness.PhaseExecution {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            var steps: u32 = 0;
            while (context.repaired and context.queue_depth != 0 and steps < steps_max) : (steps += 1) {
                context.queue_depth -= 1;
            }
            return .{
                .steps_executed = steps,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn pending(context_ptr: *anyopaque) error{}!?liveness.PendingReasonDetail {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            if (context.queue_depth == 0) return null;
            return .{
                .reason = .work_queue_not_empty,
                .count = context.queue_depth,
                .label = "queue_depth",
            };
        }
    };

    var context = Context{};
    const summary = try liveness.runRepairLiveness(error{}, .{
        .fault_phase_steps_max = 2,
        .repair_phase_steps_max = 4,
    }, Scenario{
        .context = &context,
        .run_fault_phase_fn = Context.runFault,
        .transition_to_repair_fn = Context.transition,
        .run_repair_phase_fn = Context.runRepair,
        .pending_reason_fn = Context.pending,
    });

    assert(summary.converged);
    var buffer: [256]u8 = undefined;
    const text = try liveness.formatSummary(&buffer, summary);
    std.debug.print("{s}\n", .{text});
}
