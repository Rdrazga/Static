const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_sync = @import("static_sync");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const Semaphore = static_sync.semaphore.Semaphore;
const ScenarioCount: u32 = 4;
const ActionCount: u32 = 9;

const ActionTag = enum(u32) {
    assert_empty = 1,
    post = 2,
    try_wait_success = 3,
    try_wait_block = 4,
    timed_wait_zero_success = 5,
    timed_wait_zero_timeout = 6,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.assert_empty) },
        .{ .tag = @intFromEnum(ActionTag.timed_wait_zero_timeout) },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_block) },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 2 },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_block) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.post), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 2 },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.timed_wait_zero_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_block) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.post), .value = std.math.maxInt(usize) - 1 },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 2 },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.timed_wait_zero_success) },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.assert_empty) },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.timed_wait_zero_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_block) },
        .{ .tag = @intFromEnum(ActionTag.post), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.timed_wait_zero_success) },
        .{ .tag = @intFromEnum(ActionTag.try_wait_block) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_sync.semaphore_model",
        .message = "semaphore permit progression diverged from the bounded reference model",
    },
};

const ScenarioExpectations = struct {
    permits: usize,
    saw_timeout: bool,
    saw_post_zero: bool,
    saw_saturation: bool,
    saw_multi_consume: bool,
};

const scenario_expectations = [ScenarioCount]ScenarioExpectations{
    .{
        .permits = 0,
        .saw_timeout = true,
        .saw_post_zero = false,
        .saw_saturation = false,
        .saw_multi_consume = true,
    },
    .{
        .permits = 0,
        .saw_timeout = false,
        .saw_post_zero = true,
        .saw_saturation = false,
        .saw_multi_consume = true,
    },
    .{
        .permits = std.math.maxInt(usize) - 4,
        .saw_timeout = false,
        .saw_post_zero = true,
        .saw_saturation = true,
        .saw_multi_consume = true,
    },
    .{
        .permits = 0,
        .saw_timeout = false,
        .saw_post_zero = false,
        .saw_saturation = false,
        .saw_multi_consume = true,
    },
};

const Context = struct {
    semaphore: Semaphore = .{},
    expected_permits: usize = 0,
    saw_timeout: bool = false,
    saw_post_zero: bool = false,
    saw_saturation: bool = false,
    saw_multi_consume: bool = false,
    consume_count: u32 = 0,

    fn resetState(self: *@This()) void {
        self.semaphore = .{};
        self.expected_permits = 0;
        self.saw_timeout = false;
        self.saw_post_zero = false;
        self.saw_saturation = false;
        self.saw_multi_consume = false;
        self.consume_count = 0;
        assert(self.actualPermits() == 0);
    }

    fn validate(self: *const @This()) checker.CheckResult {
        if (self.actualPermits() != self.expected_permits) return checker.CheckResult.fail(&violation, null);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, self.expected_permits) << 32) |
                (@as(u128, @intFromBool(self.saw_timeout)) << 3) |
                (@as(u128, @intFromBool(self.saw_post_zero)) << 2) |
                (@as(u128, @intFromBool(self.saw_saturation)) << 1) |
                @as(u128, @intFromBool(self.saw_multi_consume)),
        ));
    }

    fn assertEmpty(self: *const @This()) checker.CheckResult {
        if (self.expected_permits != 0) return checker.CheckResult.fail(&violation, null);
        return self.validate();
    }

    fn postValue(self: *@This(), permit_count: usize) checker.CheckResult {
        self.semaphore.post(permit_count);
        if (permit_count == 0) {
            self.saw_post_zero = true;
            return self.validate();
        }

        if (self.expected_permits > std.math.maxInt(usize) - permit_count) self.saw_saturation = true;
        self.expected_permits = self.expected_permits +| permit_count;
        return self.validate();
    }

    fn tryWaitExpect(self: *@This(), expect_success: bool) checker.CheckResult {
        const outcome = self.semaphore.tryWait();
        if (expect_success) {
            outcome catch {
                return checker.CheckResult.fail(&violation, null);
            };
            if (self.expected_permits == 0) return checker.CheckResult.fail(&violation, null);
            self.expected_permits -= 1;
            self.consume_count += 1;
            if (self.consume_count > 1) self.saw_multi_consume = true;
            return self.validate();
        }

        outcome catch |err| switch (err) {
            error.WouldBlock => return self.validate(),
        };
        return checker.CheckResult.fail(&violation, null);
    }

    fn timedWaitZeroExpect(self: *@This(), expect_success: bool) checker.CheckResult {
        const outcome = self.semaphore.timedWait(0);
        if (expect_success) {
            outcome catch {
                return checker.CheckResult.fail(&violation, null);
            };
            if (self.expected_permits == 0) return checker.CheckResult.fail(&violation, null);
            self.expected_permits -= 1;
            self.consume_count += 1;
            if (self.consume_count > 1) self.saw_multi_consume = true;
            return self.validate();
        }

        outcome catch |err| switch (err) {
            error.Timeout => {
                self.saw_timeout = true;
                return self.validate();
            },
            error.Unsupported => return checker.CheckResult.fail(&violation, null),
        };
        return checker.CheckResult.fail(&violation, null);
    }

    fn finish(self: *const @This(), case_index: u32) checker.CheckResult {
        assert(case_index < ScenarioCount);
        const expectations = scenario_expectations[case_index];

        assert(self.expected_permits == expectations.permits);
        assert(self.saw_timeout == expectations.saw_timeout);
        assert(self.saw_post_zero == expectations.saw_post_zero);
        assert(self.saw_saturation == expectations.saw_saturation);
        assert(self.saw_multi_consume == expectations.saw_multi_consume);

        return self.validate();
    }

    fn actualPermits(self: *const @This()) usize {
        return self.semaphore.permits.load(.acquire);
    }
};

test "semaphore progression sequences stay aligned with testing.model" {
    if (!static_sync.semaphore.supports_timed_wait) return error.SkipZigTest;

    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_sync",
            .run_name = "semaphore_progression_sequences",
            .base_seed = .init(0x17b4_2026_0000_9601),
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
        .assert_empty => context.assertEmpty(),
        .post => context.postValue(action.value),
        .try_wait_success => context.tryWaitExpect(true),
        .try_wait_block => context.tryWaitExpect(false),
        .timed_wait_zero_success => context.timedWaitZeroExpect(true),
        .timed_wait_zero_timeout => context.timedWaitZeroExpect(false),
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return context.finish(run_identity.case_index);
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .assert_empty => "assert_empty",
            .post => if (action.value == 0) "post_zero" else "post_value",
            .try_wait_success => "try_wait_success",
            .try_wait_block => "try_wait_block",
            .timed_wait_zero_success => "timed_wait_zero_success",
            .timed_wait_zero_timeout => "timed_wait_zero_timeout",
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
