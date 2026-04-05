const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_sync = @import("static_sync");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const Barrier = static_sync.barrier.Barrier;
const Parties: usize = 2;
const ScenarioCount: u32 = 4;
const ActionCount: u32 = 10;

const ActionTag = enum(u32) {
    assert_parties = 1,
    arrive = 2,
    wait_gen0_block = 3,
    wait_gen0_open = 4,
    wait_gen1_block = 5,
    wait_gen1_open = 6,
    wait_current_block = 7,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.assert_parties) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen0_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen0_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen0_open) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_open) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.assert_parties) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen0_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen0_open) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_open) },
        .{ .tag = @intFromEnum(ActionTag.wait_current_block) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.assert_parties) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen0_open) },
        .{ .tag = @intFromEnum(ActionTag.wait_current_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_open) },
        .{ .tag = @intFromEnum(ActionTag.wait_current_block) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.assert_parties) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen0_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen0_open) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_block) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_block) },
        .{ .tag = @intFromEnum(ActionTag.arrive) },
        .{ .tag = @intFromEnum(ActionTag.wait_gen1_open) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_sync.barrier_model",
        .message = "barrier phase or generation semantics diverged from the bounded reference model",
    },
};

const Context = struct {
    barrier: Barrier = undefined,
    generation: u64 = 0,
    arrivals_in_phase: usize = 0,
    completed_phases: u32 = 0,
    saw_would_block: bool = false,
    saw_reuse: bool = false,
    saw_phase_close: bool = false,

    fn resetState(self: *@This()) void {
        self.barrier = Barrier.init(Parties) catch unreachable;
        self.generation = 0;
        self.arrivals_in_phase = 0;
        self.completed_phases = 0;
        self.saw_would_block = false;
        self.saw_reuse = false;
        self.saw_phase_close = false;

        assert(self.barrier.parties() == Parties);
        assert(self.barrier.generationNow() == 0);
    }

    fn validate(self: *const @This()) checker.CheckResult {
        if (self.barrier.parties() != Parties) {
            return checker.CheckResult.fail(&violation, null);
        }
        if (self.barrier.generationNow() != self.generation) {
            return checker.CheckResult.fail(&violation, null);
        }
        if (self.completed_phases != self.generation) {
            return checker.CheckResult.fail(&violation, null);
        }

        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, self.generation) << 64) |
                (@as(u128, self.arrivals_in_phase) << 32) |
                @as(u128, self.completed_phases),
        ));
    }

    fn assertParties(self: *const @This()) checker.CheckResult {
        return self.validate();
    }

    fn arrive(self: *@This()) checker.CheckResult {
        const expected_last = self.arrivals_in_phase + 1 == Parties;
        const actual_last = self.barrier.arrive();
        if (actual_last != expected_last) {
            return checker.CheckResult.fail(&violation, null);
        }

        if (expected_last) {
            self.arrivals_in_phase = 0;
            self.generation += 1;
            self.completed_phases += 1;
            self.saw_phase_close = true;
            if (self.completed_phases > 1) self.saw_reuse = true;
        } else {
            self.arrivals_in_phase += 1;
        }
        return self.validate();
    }

    fn expectWouldBlock(self: *@This(), observed_generation: u64) checker.CheckResult {
        self.barrier.tryWait(observed_generation) catch |err| switch (err) {
            error.WouldBlock => {
                self.saw_would_block = true;
                return self.validate();
            },
        };
        return checker.CheckResult.fail(&violation, null);
    }

    fn expectOpen(self: *@This(), observed_generation: u64) checker.CheckResult {
        self.barrier.tryWait(observed_generation) catch {
            return checker.CheckResult.fail(&violation, null);
        };
        return self.validate();
    }

    fn finish(self: *const @This()) checker.CheckResult {
        assert(self.completed_phases == 2);
        assert(self.generation == 2);
        assert(self.arrivals_in_phase == 0);
        assert(self.saw_would_block);
        assert(self.saw_reuse);
        assert(self.saw_phase_close);
        assert(self.barrier.parties() == Parties);
        assert(self.barrier.generationNow() == 2);
        self.barrier.tryWait(1) catch unreachable;
        testing.expectError(error.WouldBlock, self.barrier.tryWait(2)) catch unreachable;
        return self.validate();
    }
};

test "barrier phase sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_sync",
            .run_name = "barrier_phase_sequences",
            .base_seed = .init(0x17b4_2026_0000_9301),
            .build_mode = .debug,
            .case_count_max = ScenarioCount,
            .action_count_max = ActionCount,
        },
        .target = Target{
            .context = &context,
            .reset_fn = reset,
            .next_action_fn = nextAction,
            .step_fn = step,
            .finish_fn = finish,
            .describe_action_fn = describe,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    try testing.expectEqual(ScenarioCount, summary.executed_case_count);
    try testing.expect(summary.failed_case == null);
}

fn nextAction(
    _: *anyopaque,
    run_identity: identity.RunIdentity,
    action_index: u32,
    _: seed.Seed,
) error{}!model.RecordedAction {
    assert(run_identity.case_index < ScenarioCount);
    assert(action_index < ActionCount);
    return action_table[run_identity.case_index][action_index];
}

fn step(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action: model.RecordedAction,
) error{}!model.ModelStep {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const tag: ActionTag = @enumFromInt(action.tag);
    const result = switch (tag) {
        .assert_parties => context.assertParties(),
        .arrive => context.arrive(),
        .wait_gen0_block => context.expectWouldBlock(0),
        .wait_gen0_open => context.expectOpen(0),
        .wait_gen1_block => context.expectWouldBlock(1),
        .wait_gen1_open => context.expectOpen(1),
        .wait_current_block => context.expectWouldBlock(context.generation),
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return context.finish();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .assert_parties => "assert_parties",
            .arrive => "arrive",
            .wait_gen0_block => "wait_gen0_block",
            .wait_gen0_open => "wait_gen0_open",
            .wait_gen1_block => "wait_gen1_block",
            .wait_gen1_open => "wait_gen1_open",
            .wait_current_block => "wait_current_block",
        },
    };
}

fn reset(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
) error{}!void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.resetState();
}
