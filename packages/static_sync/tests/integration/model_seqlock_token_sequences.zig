const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_sync = @import("static_sync");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const SeqLock = static_sync.seqlock.SeqLock;
const ScenarioCount: u32 = 4;
const ActionCount: u32 = 9;

const ActionTag = enum(u32) {
    read_begin_capture = 1,
    retry_captured_open = 2,
    write_lock = 3,
    assert_odd_locked = 4,
    write_unlock = 5,
    retry_captured_stale = 6,
    read_begin_refresh = 7,
    retry_refresh_open = 8,
    retry_manual_odd = 9,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.read_begin_capture) },
        .{ .tag = @intFromEnum(ActionTag.retry_captured_open) },
        .{ .tag = @intFromEnum(ActionTag.write_lock) },
        .{ .tag = @intFromEnum(ActionTag.assert_odd_locked) },
        .{ .tag = @intFromEnum(ActionTag.write_unlock) },
        .{ .tag = @intFromEnum(ActionTag.retry_captured_stale) },
        .{ .tag = @intFromEnum(ActionTag.read_begin_refresh) },
        .{ .tag = @intFromEnum(ActionTag.retry_refresh_open) },
        .{ .tag = @intFromEnum(ActionTag.retry_manual_odd) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.read_begin_capture) },
        .{ .tag = @intFromEnum(ActionTag.write_lock) },
        .{ .tag = @intFromEnum(ActionTag.assert_odd_locked) },
        .{ .tag = @intFromEnum(ActionTag.write_unlock) },
        .{ .tag = @intFromEnum(ActionTag.read_begin_refresh) },
        .{ .tag = @intFromEnum(ActionTag.retry_refresh_open) },
        .{ .tag = @intFromEnum(ActionTag.write_lock) },
        .{ .tag = @intFromEnum(ActionTag.write_unlock) },
        .{ .tag = @intFromEnum(ActionTag.retry_captured_stale) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.read_begin_capture) },
        .{ .tag = @intFromEnum(ActionTag.retry_manual_odd) },
        .{ .tag = @intFromEnum(ActionTag.write_lock) },
        .{ .tag = @intFromEnum(ActionTag.assert_odd_locked) },
        .{ .tag = @intFromEnum(ActionTag.write_unlock) },
        .{ .tag = @intFromEnum(ActionTag.retry_captured_stale) },
        .{ .tag = @intFromEnum(ActionTag.read_begin_refresh) },
        .{ .tag = @intFromEnum(ActionTag.retry_refresh_open) },
        .{ .tag = @intFromEnum(ActionTag.retry_manual_odd) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.read_begin_capture) },
        .{ .tag = @intFromEnum(ActionTag.retry_captured_open) },
        .{ .tag = @intFromEnum(ActionTag.write_lock) },
        .{ .tag = @intFromEnum(ActionTag.assert_odd_locked) },
        .{ .tag = @intFromEnum(ActionTag.write_unlock) },
        .{ .tag = @intFromEnum(ActionTag.retry_captured_stale) },
        .{ .tag = @intFromEnum(ActionTag.read_begin_refresh) },
        .{ .tag = @intFromEnum(ActionTag.retry_refresh_open) },
        .{ .tag = @intFromEnum(ActionTag.retry_manual_odd) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_sync.seqlock_model",
        .message = "seqlock token parity or retry semantics diverged from the bounded reference model",
    },
};

const ScenarioExpectations = struct {
    stale_retry: bool,
    manual_odd_retry: bool,
    refresh_open: bool,
    multi_cycle_progression: bool,
};

const scenario_expectations = [ScenarioCount]ScenarioExpectations{
    .{
        .stale_retry = true,
        .manual_odd_retry = true,
        .refresh_open = true,
        .multi_cycle_progression = false,
    },
    .{
        .stale_retry = true,
        .manual_odd_retry = false,
        .refresh_open = true,
        .multi_cycle_progression = true,
    },
    .{
        .stale_retry = true,
        .manual_odd_retry = true,
        .refresh_open = true,
        .multi_cycle_progression = false,
    },
    .{
        .stale_retry = true,
        .manual_odd_retry = true,
        .refresh_open = true,
        .multi_cycle_progression = false,
    },
};

const Context = struct {
    lock: SeqLock = .{},
    expected_seq: u64 = 0,
    writer_locked: bool = false,
    captured_token: ?u64 = null,
    saw_stale_retry: bool = false,
    saw_manual_odd_retry: bool = false,
    saw_refresh_open: bool = false,
    saw_multi_cycle_progression: bool = false,

    fn resetState(self: *@This()) void {
        self.lock = .{};
        self.expected_seq = 0;
        self.writer_locked = false;
        self.captured_token = null;
        self.saw_stale_retry = false;
        self.saw_manual_odd_retry = false;
        self.saw_refresh_open = false;
        self.saw_multi_cycle_progression = false;
        assert(self.lock.seq.load(.acquire) == 0);
    }

    fn validate(self: *const @This()) checker.CheckResult {
        const actual_seq = self.lock.seq.load(.acquire);
        if (actual_seq != self.expected_seq) return checker.CheckResult.fail(&violation, null);
        if (self.writer_locked != ((actual_seq & 1) == 1)) return checker.CheckResult.fail(&violation, null);
        if (!self.writer_locked and (actual_seq & 1) != 0) return checker.CheckResult.fail(&violation, null);
        if (self.captured_token) |token| {
            if ((token & 1) != 0) return checker.CheckResult.fail(&violation, null);
        }
        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, actual_seq) << 64) |
                (@as(u128, @intFromBool(self.saw_stale_retry)) << 3) |
                (@as(u128, @intFromBool(self.saw_manual_odd_retry)) << 2) |
                (@as(u128, @intFromBool(self.saw_refresh_open)) << 1) |
                @as(u128, @intFromBool(self.saw_multi_cycle_progression)),
        ));
    }

    fn readBeginCapture(self: *@This()) checker.CheckResult {
        if (self.writer_locked) return checker.CheckResult.fail(&violation, null);
        const token = self.lock.readBegin();
        if ((token & 1) != 0 or token != self.expected_seq) return checker.CheckResult.fail(&violation, null);
        self.captured_token = token;
        return self.validate();
    }

    fn retryCaptured(self: *@This(), expected_retry: bool) checker.CheckResult {
        const token = self.captured_token orelse return checker.CheckResult.fail(&violation, null);
        const actual_retry = self.lock.readRetry(token);
        if (actual_retry != expected_retry) return checker.CheckResult.fail(&violation, null);
        if (expected_retry) self.saw_stale_retry = true;
        return self.validate();
    }

    fn writeLock(self: *@This()) checker.CheckResult {
        if (self.writer_locked) return checker.CheckResult.fail(&violation, null);
        const before = self.expected_seq;
        self.lock.writeLock();
        self.writer_locked = true;
        self.expected_seq += 1;
        if (before >= 2) self.saw_multi_cycle_progression = true;
        return self.validate();
    }

    fn assertOddLocked(self: *const @This()) checker.CheckResult {
        if (!self.writer_locked) return checker.CheckResult.fail(&violation, null);
        const token = self.lock.seq.load(.acquire);
        if ((token & 1) != 1 or token != self.expected_seq) return checker.CheckResult.fail(&violation, null);
        return self.validate();
    }

    fn writeUnlock(self: *@This()) checker.CheckResult {
        if (!self.writer_locked) return checker.CheckResult.fail(&violation, null);
        self.lock.writeUnlock();
        self.writer_locked = false;
        self.expected_seq += 1;
        return self.validate();
    }

    fn readBeginRefresh(self: *@This()) checker.CheckResult {
        const result = self.readBeginCapture();
        if (!result.passed) return result;
        self.saw_refresh_open = true;
        return self.validate();
    }

    fn retryManualOdd(self: *@This()) checker.CheckResult {
        if (!self.lock.readRetry(1)) return checker.CheckResult.fail(&violation, null);
        self.saw_manual_odd_retry = true;
        return self.validate();
    }

    fn finish(self: *const @This(), case_index: u32) checker.CheckResult {
        assert(case_index < ScenarioCount);
        const expectations = scenario_expectations[case_index];
        assert(!self.writer_locked);
        assert((self.expected_seq & 1) == 0);
        assert(self.captured_token != null);
        assert(self.saw_stale_retry == expectations.stale_retry);
        assert(self.saw_manual_odd_retry == expectations.manual_odd_retry);
        assert(self.saw_refresh_open == expectations.refresh_open);
        assert(self.saw_multi_cycle_progression == expectations.multi_cycle_progression);
        return self.validate();
    }
};

test "seqlock token sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_sync",
            .run_name = "seqlock_token_sequences",
            .base_seed = .init(0x17b4_2026_0000_9401),
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
        .read_begin_capture => context.readBeginCapture(),
        .retry_captured_open => context.retryCaptured(false),
        .write_lock => context.writeLock(),
        .assert_odd_locked => context.assertOddLocked(),
        .write_unlock => context.writeUnlock(),
        .retry_captured_stale => context.retryCaptured(true),
        .read_begin_refresh => context.readBeginRefresh(),
        .retry_refresh_open => context.retryCaptured(false),
        .retry_manual_odd => context.retryManualOdd(),
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
            .read_begin_capture => "read_begin_capture",
            .retry_captured_open => "retry_captured_open",
            .write_lock => "write_lock",
            .assert_odd_locked => "assert_odd_locked",
            .write_unlock => "write_unlock",
            .retry_captured_stale => "retry_captured_stale",
            .read_begin_refresh => "read_begin_refresh",
            .retry_refresh_open => "retry_refresh_open",
            .retry_manual_odd => "retry_manual_odd",
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
