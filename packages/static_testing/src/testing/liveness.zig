//! Deterministic repair/liveness execution helpers over caller-owned scenarios.
//!
//! The first slice is intentionally narrow:
//! - one callback drives the fault phase;
//! - one transition hook switches the scenario into repair mode;
//! - one callback drives the repair phase;
//! - one callback reports the current pending reason, if any; and
//! - the helper returns one bounded summary with stable text formatting.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const checker = @import("checker.zig");

pub const RepairLivenessError = error{
    InvalidInput,
    NoSpaceLeft,
};

pub const ExecutionPhase = enum(u8) {
    fault = 1,
    repair = 2,
};

pub const PendingReason = enum(u8) {
    inflight_request = 1,
    scheduled_timer_remaining = 2,
    mailbox_not_empty = 3,
    work_queue_not_empty = 4,
    node_unrecovered = 5,
    reply_sequence_gap = 6,
    custom = 7,
};

pub const PendingReasonDetail = struct {
    reason: PendingReason,
    count: u32 = 0,
    value: u64 = 0,
    label: ?[]const u8 = null,
};

pub const PhaseExecution = struct {
    steps_executed: u32,
    check_result: checker.CheckResult,
};

pub const RepairLivenessConfig = struct {
    fault_phase_steps_max: u32,
    repair_phase_steps_max: u32,
    stop_on_safety_failure: bool = true,
    record_pending_reason: bool = true,
};

pub const RepairLivenessSummary = struct {
    fault_phase: PhaseExecution,
    repair_phase: ?PhaseExecution = null,
    converged: bool,
    pending_reason: ?PendingReasonDetail = null,
};

pub fn RepairLivenessScenario(comptime ScenarioError: type) type {
    return struct {
        context: *anyopaque,
        run_fault_phase_fn: *const fn (context: *anyopaque, steps_max: u32) ScenarioError!PhaseExecution,
        transition_to_repair_fn: *const fn (context: *anyopaque) void,
        run_repair_phase_fn: *const fn (context: *anyopaque, steps_max: u32) ScenarioError!PhaseExecution,
        pending_reason_fn: *const fn (context: *anyopaque) ScenarioError!?PendingReasonDetail,

        pub fn runFaultPhase(
            self: @This(),
            steps_max: u32,
        ) ScenarioError!PhaseExecution {
            return self.run_fault_phase_fn(self.context, steps_max);
        }

        pub fn transitionToRepair(self: @This()) void {
            self.transition_to_repair_fn(self.context);
        }

        pub fn runRepairPhase(
            self: @This(),
            steps_max: u32,
        ) ScenarioError!PhaseExecution {
            return self.run_repair_phase_fn(self.context, steps_max);
        }

        pub fn pendingReason(self: @This()) ScenarioError!?PendingReasonDetail {
            return self.pending_reason_fn(self.context);
        }
    };
}

pub fn runRepairLiveness(
    comptime ScenarioError: type,
    config: RepairLivenessConfig,
    scenario: RepairLivenessScenario(ScenarioError),
) (ScenarioError || RepairLivenessError)!RepairLivenessSummary {
    try validateConfig(config);

    const fault_phase = try scenario.runFaultPhase(config.fault_phase_steps_max);
    assertPhaseExecution(fault_phase);
    if (!fault_phase.check_result.passed and config.stop_on_safety_failure) {
        return .{
            .fault_phase = fault_phase,
            .converged = false,
        };
    }

    scenario.transitionToRepair();
    const repair_phase = try scenario.runRepairPhase(config.repair_phase_steps_max);
    assertPhaseExecution(repair_phase);

    const pending_reason = if (config.record_pending_reason)
        try scenario.pendingReason()
    else
        null;
    validatePendingReason(pending_reason) catch return error.InvalidInput;

    return .{
        .fault_phase = fault_phase,
        .repair_phase = repair_phase,
        .converged = fault_phase.check_result.passed and
            repair_phase.check_result.passed and
            pending_reason == null,
        .pending_reason = pending_reason,
    };
}

pub fn formatSummary(
    buffer: []u8,
    summary: RepairLivenessSummary,
) RepairLivenessError![]const u8 {
    if (buffer.len == 0) return error.NoSpaceLeft;
    assertPhaseExecution(summary.fault_phase);
    if (summary.repair_phase) |repair_phase| {
        assertPhaseExecution(repair_phase);
    }
    try validatePendingReason(summary.pending_reason);

    var writer = SummaryWriter.init(buffer);
    try writer.print(
        "repair_liveness fault_passed={s} fault_steps={d}",
        .{
            boolText(summary.fault_phase.check_result.passed),
            summary.fault_phase.steps_executed,
        },
    );
    if (summary.repair_phase) |repair_phase| {
        try writer.print(
            " repair_passed={s} repair_steps={d}",
            .{
                boolText(repair_phase.check_result.passed),
                repair_phase.steps_executed,
            },
        );
    } else {
        try writer.writeAll(" repair_skipped=true");
    }
    try writer.print(" converged={s}", .{boolText(summary.converged)});
    if (summary.pending_reason) |pending_reason| {
        try writer.print(
            " pending_reason={s} count={d} value={d}",
            .{
                @tagName(pending_reason.reason),
                pending_reason.count,
                pending_reason.value,
            },
        );
        if (pending_reason.label) |label| {
            try writer.print(" label={s}", .{label});
        }
    }
    return writer.written();
}

comptime {
    core.errors.assertVocabularySubset(RepairLivenessError);
}

fn validateConfig(config: RepairLivenessConfig) RepairLivenessError!void {
    if (config.fault_phase_steps_max == 0) return error.InvalidInput;
    if (config.repair_phase_steps_max == 0) return error.InvalidInput;
}

fn validatePendingReason(pending_reason: ?PendingReasonDetail) RepairLivenessError!void {
    if (pending_reason) |detail| {
        if (detail.label) |label| {
            if (label.len == 0) return error.InvalidInput;
        }
    }
}

fn assertPhaseExecution(execution: PhaseExecution) void {
    if (execution.check_result.passed) {
        assert(execution.check_result.violations.len == 0);
    } else {
        assert(execution.check_result.violations.len > 0);
    }
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

const SummaryWriter = struct {
    buffer: []u8,
    used: usize = 0,

    fn init(buffer: []u8) SummaryWriter {
        assert(buffer.len > 0);
        return .{ .buffer = buffer };
    }

    fn print(self: *SummaryWriter, comptime format: []const u8, args: anytype) RepairLivenessError!void {
        const text = std.fmt.bufPrint(self.buffer[self.used..], format, args) catch return error.NoSpaceLeft;
        self.used += text.len;
    }

    fn writeAll(self: *SummaryWriter, bytes: []const u8) RepairLivenessError!void {
        if (bytes.len > self.buffer.len - self.used) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }

    fn written(self: *const SummaryWriter) []const u8 {
        return self.buffer[0..self.used];
    }
};

test "runRepairLiveness rejects zero phase budgets" {
    const Scenario = RepairLivenessScenario(error{});
    const Context = struct {
        fn runFault(_: *anyopaque, _: u32) error{}!PhaseExecution {
            unreachable;
        }

        fn transition(_: *anyopaque) void {}

        fn runRepair(_: *anyopaque, _: u32) error{}!PhaseExecution {
            unreachable;
        }

        fn pending(_: *anyopaque) error{}!?PendingReasonDetail {
            return null;
        }
    };

    var dummy: u8 = 0;
    try testing.expectError(error.InvalidInput, runRepairLiveness(error{}, .{
        .fault_phase_steps_max = 0,
        .repair_phase_steps_max = 1,
    }, Scenario{
        .context = &dummy,
        .run_fault_phase_fn = Context.runFault,
        .transition_to_repair_fn = Context.transition,
        .run_repair_phase_fn = Context.runRepair,
        .pending_reason_fn = Context.pending,
    }));
    try testing.expectError(error.InvalidInput, runRepairLiveness(error{}, .{
        .fault_phase_steps_max = 1,
        .repair_phase_steps_max = 0,
    }, Scenario{
        .context = &dummy,
        .run_fault_phase_fn = Context.runFault,
        .transition_to_repair_fn = Context.transition,
        .run_repair_phase_fn = Context.runRepair,
        .pending_reason_fn = Context.pending,
    }));
}

test "runRepairLiveness converges after repair transition" {
    const Scenario = RepairLivenessScenario(error{});
    const Context = struct {
        queue_depth: u32 = 2,
        repaired: bool = false,

        fn runFault(context_ptr: *anyopaque, steps_max: u32) error{}!PhaseExecution {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            assert(!context.repaired);
            return .{
                .steps_executed = steps_max,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn transition(context_ptr: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.repaired = true;
        }

        fn runRepair(context_ptr: *anyopaque, steps_max: u32) error{}!PhaseExecution {
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

        fn pending(context_ptr: *anyopaque) error{}!?PendingReasonDetail {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            if (context.queue_depth == 0) return null;
            return .{
                .reason = .work_queue_not_empty,
                .count = context.queue_depth,
            };
        }
    };

    var context = Context{};
    const summary = try runRepairLiveness(error{}, .{
        .fault_phase_steps_max = 2,
        .repair_phase_steps_max = 2,
    }, Scenario{
        .context = &context,
        .run_fault_phase_fn = Context.runFault,
        .transition_to_repair_fn = Context.transition,
        .run_repair_phase_fn = Context.runRepair,
        .pending_reason_fn = Context.pending,
    });

    try testing.expect(summary.fault_phase.check_result.passed);
    try testing.expect(summary.repair_phase != null);
    try testing.expect(summary.repair_phase.?.check_result.passed);
    try testing.expect(summary.converged);
    try testing.expect(summary.pending_reason == null);
    try testing.expectEqual(@as(u32, 0), context.queue_depth);
}

test "runRepairLiveness reports pending reason when repair phase does not settle" {
    const Scenario = RepairLivenessScenario(error{});
    const Context = struct {
        queue_depth: u32 = 3,
        repaired: bool = false,

        fn runFault(_: *anyopaque, steps_max: u32) error{}!PhaseExecution {
            return .{
                .steps_executed = steps_max,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn transition(context_ptr: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.repaired = true;
        }

        fn runRepair(context_ptr: *anyopaque, steps_max: u32) error{}!PhaseExecution {
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

        fn pending(context_ptr: *anyopaque) error{}!?PendingReasonDetail {
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
    const summary = try runRepairLiveness(error{}, .{
        .fault_phase_steps_max = 1,
        .repair_phase_steps_max = 2,
    }, Scenario{
        .context = &context,
        .run_fault_phase_fn = Context.runFault,
        .transition_to_repair_fn = Context.transition,
        .run_repair_phase_fn = Context.runRepair,
        .pending_reason_fn = Context.pending,
    });

    try testing.expect(!summary.converged);
    try testing.expect(summary.pending_reason != null);
    try testing.expectEqual(PendingReason.work_queue_not_empty, summary.pending_reason.?.reason);
    try testing.expectEqual(@as(u32, 1), summary.pending_reason.?.count);

    var buffer: [256]u8 = undefined;
    const text = try formatSummary(&buffer, summary);
    try testing.expect(std.mem.indexOf(u8, text, "pending_reason=work_queue_not_empty") != null);
}

test "runRepairLiveness can stop before repair when safety fails" {
    const Scenario = RepairLivenessScenario(error{});
    const violations = [_]checker.Violation{
        .{ .code = "safety.failed", .message = "fault phase violated an invariant" },
    };
    const Context = struct {
        repair_transition_count: u32 = 0,

        fn runFault(_: *anyopaque, steps_max: u32) error{}!PhaseExecution {
            return .{
                .steps_executed = steps_max,
                .check_result = checker.CheckResult.fail(&violations, null),
            };
        }

        fn transition(context_ptr: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.repair_transition_count += 1;
        }

        fn runRepair(_: *anyopaque, _: u32) error{}!PhaseExecution {
            unreachable;
        }

        fn pending(_: *anyopaque) error{}!?PendingReasonDetail {
            unreachable;
        }
    };

    var context = Context{};
    const summary = try runRepairLiveness(error{}, .{
        .fault_phase_steps_max = 3,
        .repair_phase_steps_max = 3,
        .stop_on_safety_failure = true,
    }, Scenario{
        .context = &context,
        .run_fault_phase_fn = Context.runFault,
        .transition_to_repair_fn = Context.transition,
        .run_repair_phase_fn = Context.runRepair,
        .pending_reason_fn = Context.pending,
    });

    try testing.expect(!summary.fault_phase.check_result.passed);
    try testing.expect(summary.repair_phase == null);
    try testing.expect(!summary.converged);
    try testing.expectEqual(@as(u32, 0), context.repair_transition_count);
}

test "runRepairLiveness keeps converged false when fault phase safety already failed" {
    const Scenario = RepairLivenessScenario(error{});
    const violations = [_]checker.Violation{
        .{ .code = "safety.failed", .message = "fault phase violated an invariant" },
    };
    const Context = struct {
        repaired: bool = false,

        fn runFault(_: *anyopaque, steps_max: u32) error{}!PhaseExecution {
            return .{
                .steps_executed = steps_max,
                .check_result = checker.CheckResult.fail(&violations, null),
            };
        }

        fn transition(context_ptr: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.repaired = true;
        }

        fn runRepair(context_ptr: *anyopaque, steps_max: u32) error{}!PhaseExecution {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            assert(context.repaired);
            return .{
                .steps_executed = steps_max,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn pending(_: *anyopaque) error{}!?PendingReasonDetail {
            return null;
        }
    };

    var context = Context{};
    const summary = try runRepairLiveness(error{}, .{
        .fault_phase_steps_max = 2,
        .repair_phase_steps_max = 2,
        .stop_on_safety_failure = false,
    }, Scenario{
        .context = &context,
        .run_fault_phase_fn = Context.runFault,
        .transition_to_repair_fn = Context.transition,
        .run_repair_phase_fn = Context.runRepair,
        .pending_reason_fn = Context.pending,
    });

    try testing.expect(!summary.fault_phase.check_result.passed);
    try testing.expect(summary.repair_phase != null);
    try testing.expect(summary.repair_phase.?.check_result.passed);
    try testing.expect(!summary.converged);
}
