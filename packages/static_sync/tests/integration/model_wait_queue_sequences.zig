const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_sync = @import("static_sync");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const wait_queue = static_sync.wait_queue;
const CancelSource = static_sync.cancel.CancelSource;
const CancelToken = static_sync.cancel.CancelToken;

const ScenarioCount: u32 = 3;
const ActionCount: u32 = 6;

const ActionTag = enum(u32) {
    wait_equal_timeout_zero = 1,
    store_one = 2,
    wait_mismatch_returns = 3,
    wake_all = 4,
    cancel = 5,
    wait_equal_cancelled = 6,
    reset_cancel = 7,
    store_zero = 8,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.wait_equal_timeout_zero) },
        .{ .tag = @intFromEnum(ActionTag.store_one) },
        .{ .tag = @intFromEnum(ActionTag.wait_mismatch_returns) },
        .{ .tag = @intFromEnum(ActionTag.wake_all) },
        .{ .tag = @intFromEnum(ActionTag.store_zero) },
        .{ .tag = @intFromEnum(ActionTag.wait_equal_timeout_zero) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.wait_equal_cancelled) },
        .{ .tag = @intFromEnum(ActionTag.reset_cancel) },
        .{ .tag = @intFromEnum(ActionTag.wait_equal_timeout_zero) },
        .{ .tag = @intFromEnum(ActionTag.store_one) },
        .{ .tag = @intFromEnum(ActionTag.wait_mismatch_returns) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.store_one) },
        .{ .tag = @intFromEnum(ActionTag.wake_all) },
        .{ .tag = @intFromEnum(ActionTag.wait_mismatch_returns) },
        .{ .tag = @intFromEnum(ActionTag.store_zero) },
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.wait_equal_cancelled) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_sync.wait_queue_model",
        .message = "wait_queue sequential contract diverged from the bounded reference model",
    },
};

const ScenarioExpectations = struct {
    state_value: u32,
    cancelled: bool,
    saw_timeout: bool,
    saw_cancelled: bool,
    saw_mismatch: bool,
};

const scenario_expectations = [ScenarioCount]ScenarioExpectations{
    .{
        .state_value = 0,
        .cancelled = false,
        .saw_timeout = true,
        .saw_cancelled = false,
        .saw_mismatch = true,
    },
    .{
        .state_value = 1,
        .cancelled = false,
        .saw_timeout = true,
        .saw_cancelled = true,
        .saw_mismatch = true,
    },
    .{
        .state_value = 0,
        .cancelled = true,
        .saw_timeout = false,
        .saw_cancelled = true,
        .saw_mismatch = true,
    },
};

const Context = struct {
    state_value: u32 = 0,
    cancel_source: CancelSource = .{},
    token: CancelToken = undefined,
    cancelled: bool = false,
    saw_timeout: bool = false,
    saw_cancelled: bool = false,
    saw_mismatch: bool = false,

    fn resetState(self: *@This()) void {
        self.state_value = 0;
        self.cancel_source = .{};
        self.token = self.cancel_source.token();
        self.cancelled = false;
        self.saw_timeout = false;
        self.saw_cancelled = false;
        self.saw_mismatch = false;
        assert(!self.token.isCancelled());
    }

    fn validate(self: *const @This()) checker.CheckResult {
        if (self.token.isCancelled() != self.cancelled) return checker.CheckResult.fail(&violation, null);

        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, self.state_value) << 32) |
                (@as(u128, @intFromBool(self.cancelled)) << 3) |
                (@as(u128, @intFromBool(self.saw_timeout)) << 2) |
                (@as(u128, @intFromBool(self.saw_cancelled)) << 1) |
                @as(u128, @intFromBool(self.saw_mismatch)),
        ));
    }

    fn waitEqualTimeoutZero(self: *@This()) checker.CheckResult {
        wait_queue.waitValue(u32, &self.state_value, 0, .{ .timeout_ns = 0 }) catch |err| switch (err) {
            error.Timeout => {
                self.saw_timeout = true;
                return self.validate();
            },
            error.Cancelled, error.Unsupported => return checker.CheckResult.fail(&violation, null),
        };
        return checker.CheckResult.fail(&violation, null);
    }

    fn storeOne(self: *@This()) checker.CheckResult {
        @atomicStore(u32, &self.state_value, 1, .release);
        self.state_value = 1;
        return self.validate();
    }

    fn storeZero(self: *@This()) checker.CheckResult {
        @atomicStore(u32, &self.state_value, 0, .release);
        self.state_value = 0;
        return self.validate();
    }

    fn waitMismatchReturns(self: *@This()) checker.CheckResult {
        wait_queue.waitValue(u32, &self.state_value, 0, .{ .timeout_ns = std.time.ns_per_ms }) catch {
            return checker.CheckResult.fail(&violation, null);
        };
        self.saw_mismatch = true;
        return self.validate();
    }

    fn wakeAll(self: *const @This()) checker.CheckResult {
        wait_queue.wakeValue(u32, &self.state_value, std.math.maxInt(u32));
        return self.validate();
    }

    fn cancelNow(self: *@This()) checker.CheckResult {
        self.cancel_source.cancel();
        self.cancelled = true;
        return self.validate();
    }

    fn waitEqualCancelled(self: *@This()) checker.CheckResult {
        wait_queue.waitValue(u32, &self.state_value, 0, .{
            .timeout_ns = std.time.ns_per_ms,
            .cancel = self.token,
        }) catch |err| switch (err) {
            error.Cancelled => {
                self.saw_cancelled = true;
                return self.validate();
            },
            error.Timeout, error.Unsupported => return checker.CheckResult.fail(&violation, null),
        };
        return checker.CheckResult.fail(&violation, null);
    }

    fn resetCancel(self: *@This()) checker.CheckResult {
        self.cancel_source.reset();
        self.cancelled = false;
        return self.validate();
    }

    fn finish(self: *const @This(), case_index: u32) checker.CheckResult {
        assert(case_index < ScenarioCount);
        const expectations = scenario_expectations[case_index];

        assert(self.state_value == expectations.state_value);
        assert(self.cancelled == expectations.cancelled);
        assert(self.saw_timeout == expectations.saw_timeout);
        assert(self.saw_cancelled == expectations.saw_cancelled);
        assert(self.saw_mismatch == expectations.saw_mismatch);

        return self.validate();
    }
};

test "wait_queue sequential contract sequences stay aligned with testing.model" {
    if (!wait_queue.supports_wait_queue) return error.SkipZigTest;

    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_sync",
            .run_name = "wait_queue_sequences",
            .base_seed = .init(0x17b4_2026_0000_9701),
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
        .wait_equal_timeout_zero => context.waitEqualTimeoutZero(),
        .store_one => context.storeOne(),
        .wait_mismatch_returns => context.waitMismatchReturns(),
        .wake_all => context.wakeAll(),
        .cancel => context.cancelNow(),
        .wait_equal_cancelled => context.waitEqualCancelled(),
        .reset_cancel => context.resetCancel(),
        .store_zero => context.storeZero(),
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
            .wait_equal_timeout_zero => "wait_equal_timeout_zero",
            .store_one => "store_one",
            .wait_mismatch_returns => "wait_mismatch_returns",
            .wake_all => "wake_all",
            .cancel => "cancel",
            .wait_equal_cancelled => "wait_equal_cancelled",
            .reset_cancel => "reset_cancel",
            .store_zero => "store_zero",
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
