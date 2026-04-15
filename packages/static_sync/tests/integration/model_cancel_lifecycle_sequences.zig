const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_sync = @import("static_sync");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const CancelRegistration = static_sync.cancel.CancelRegistration;
const CancelSource = static_sync.cancel.CancelSource;
const CancelToken = static_sync.cancel.CancelToken;

const RegCount: usize = 2;
const ScenarioCount: u32 = 4;
const ActionCount: u32 = 10;
const invalid_slot = std.math.maxInt(u32);

const ActionTag = enum(u32) {
    register_0 = 1,
    register_1 = 2,
    register_1_expect_cancelled = 3,
    cancel = 4,
    unregister_0 = 5,
    unregister_1 = 6,
    reset = 7,
    assert_clear = 8,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.register_0) },
        .{ .tag = @intFromEnum(ActionTag.register_1) },
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.unregister_0) },
        .{ .tag = @intFromEnum(ActionTag.unregister_1) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
        .{ .tag = @intFromEnum(ActionTag.register_0) },
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.unregister_0) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.assert_clear) },
        .{ .tag = @intFromEnum(ActionTag.register_0) },
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.register_1_expect_cancelled) },
        .{ .tag = @intFromEnum(ActionTag.unregister_0) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
        .{ .tag = @intFromEnum(ActionTag.register_1) },
        .{ .tag = @intFromEnum(ActionTag.unregister_1) },
        .{ .tag = @intFromEnum(ActionTag.register_0) },
        .{ .tag = @intFromEnum(ActionTag.unregister_0) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.register_0) },
        .{ .tag = @intFromEnum(ActionTag.unregister_0) },
        .{ .tag = @intFromEnum(ActionTag.register_1) },
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.unregister_1) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
        .{ .tag = @intFromEnum(ActionTag.register_0) },
        .{ .tag = @intFromEnum(ActionTag.register_1) },
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.unregister_0) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.register_0) },
        .{ .tag = @intFromEnum(ActionTag.register_1) },
        .{ .tag = @intFromEnum(ActionTag.unregister_1) },
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.unregister_0) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
        .{ .tag = @intFromEnum(ActionTag.register_1) },
        .{ .tag = @intFromEnum(ActionTag.cancel) },
        .{ .tag = @intFromEnum(ActionTag.unregister_1) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_sync.cancel_model",
        .message = "cancel registration lifecycle diverged from the bounded reference model",
    },
};

const ScenarioExpectations = struct {
    expected_counts: [RegCount]u32,
    active: [RegCount]bool,
    cancelled: bool,
    saw_cancelled_reject: bool,
    saw_fanout: bool,
    saw_reuse: bool,
    saw_unregister_without_fire: bool,
};

const scenario_expectations = [ScenarioCount]ScenarioExpectations{
    .{
        .expected_counts = .{ 2, 1 },
        .active = .{ false, false },
        .cancelled = false,
        .saw_cancelled_reject = false,
        .saw_fanout = true,
        .saw_reuse = true,
        .saw_unregister_without_fire = false,
    },
    .{
        .expected_counts = .{ 1, 0 },
        .active = .{ false, false },
        .cancelled = false,
        .saw_cancelled_reject = true,
        .saw_fanout = false,
        .saw_reuse = true,
        .saw_unregister_without_fire = true,
    },
    .{
        .expected_counts = .{ 1, 2 },
        .active = .{ false, true },
        .cancelled = true,
        .saw_cancelled_reject = false,
        .saw_fanout = true,
        .saw_reuse = true,
        .saw_unregister_without_fire = true,
    },
    .{
        .expected_counts = .{ 1, 1 },
        .active = .{ false, false },
        .cancelled = false,
        .saw_cancelled_reject = false,
        .saw_fanout = false,
        .saw_reuse = true,
        .saw_unregister_without_fire = true,
    },
};

const Context = struct {
    source: CancelSource = .{},
    token: CancelToken = undefined,
    counts: [RegCount]u32 = .{0} ** RegCount,
    regs: [RegCount]CancelRegistration = undefined,

    active: [RegCount]bool = .{false} ** RegCount,
    slot_indices: [RegCount]u32 = .{invalid_slot} ** RegCount,
    expected_counts: [RegCount]u32 = .{0} ** RegCount,
    cancelled: bool = false,
    completed_cancel_cycles: u32 = 0,
    saw_cancelled_reject: bool = false,
    saw_fanout: bool = false,
    saw_reuse: bool = false,
    saw_unregister_without_fire: bool = false,

    fn resetState(self: *@This()) void {
        self.source = .{};
        self.token = self.source.token();
        self.counts = .{0} ** RegCount;
        self.regs = .{
            CancelRegistration.init(wakeCount, &self.counts[0]),
            CancelRegistration.init(wakeCount, &self.counts[1]),
        };
        self.active = .{false} ** RegCount;
        self.slot_indices = .{invalid_slot} ** RegCount;
        self.expected_counts = .{0} ** RegCount;
        self.cancelled = false;
        self.completed_cancel_cycles = 0;
        self.saw_cancelled_reject = false;
        self.saw_fanout = false;
        self.saw_reuse = false;
        self.saw_unregister_without_fire = false;

        assert(!self.token.isCancelled());
    }

    fn validate(self: *const @This()) checker.CheckResult {
        if (self.token.isCancelled() != self.cancelled) return checker.CheckResult.fail(&violation, null);

        for (0..RegCount) |index| {
            const reg = self.regs[index];
            const active_actual = reg.state != null and reg.slot_index != invalid_slot;
            if (active_actual != self.active[index]) return checker.CheckResult.fail(&violation, null);
            if (active_actual and reg.slot_index != self.slot_indices[index]) return checker.CheckResult.fail(&violation, null);
            if (!active_actual and (reg.state != null or reg.slot_index != invalid_slot)) {
                return checker.CheckResult.fail(&violation, null);
            }
            if (self.counts[index] != self.expected_counts[index]) return checker.CheckResult.fail(&violation, null);
        }

        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, self.expected_counts[0]) << 96) |
                (@as(u128, self.expected_counts[1]) << 64) |
                (@as(u128, @intFromBool(self.cancelled)) << 32) |
                (@as(u128, @intFromBool(self.active[0])) << 16) |
                (@as(u128, @intFromBool(self.active[1])) << 8) |
                @as(u128, self.completed_cancel_cycles),
        ));
    }

    fn assertClear(self: *const @This()) checker.CheckResult {
        if (self.cancelled) return checker.CheckResult.fail(&violation, null);
        if (self.active[0] or self.active[1]) return checker.CheckResult.fail(&violation, null);
        return self.validate();
    }

    fn registerIndex(self: *@This(), index: usize, expect_cancelled: bool) checker.CheckResult {
        assert(index < RegCount);
        if (self.active[index]) return checker.CheckResult.fail(&violation, null);

        const next_slot = self.nextFreeSlot();
        const outcome = self.regs[index].register(self.token);
        if (expect_cancelled or self.cancelled) {
            outcome catch |err| switch (err) {
                error.Cancelled => {
                    self.saw_cancelled_reject = true;
                    return self.validate();
                },
                error.WouldBlock => return checker.CheckResult.fail(&violation, null),
            };
            return checker.CheckResult.fail(&violation, null);
        }

        outcome catch {
            return checker.CheckResult.fail(&violation, null);
        };
        self.active[index] = true;
        self.slot_indices[index] = next_slot;
        if (self.completed_cancel_cycles > 0) self.saw_reuse = true;
        return self.validate();
    }

    fn cancelNow(self: *@This()) checker.CheckResult {
        self.source.cancel();
        if (!self.cancelled) {
            var active_count: u32 = 0;
            for (0..RegCount) |index| {
                if (!self.active[index]) continue;
                self.expected_counts[index] += 1;
                active_count += 1;
            }
            if (active_count > 1) self.saw_fanout = true;
            self.completed_cancel_cycles += 1;
        }
        self.cancelled = true;
        return self.validate();
    }

    fn unregisterIndex(self: *@This(), index: usize) checker.CheckResult {
        assert(index < RegCount);
        if (!self.active[index]) return checker.CheckResult.fail(&violation, null);
        if (self.expected_counts[index] == 0) self.saw_unregister_without_fire = true;

        self.regs[index].unregister();
        self.active[index] = false;
        self.slot_indices[index] = invalid_slot;
        return self.validate();
    }

    fn resetSource(self: *@This()) checker.CheckResult {
        if (self.active[0] or self.active[1]) return checker.CheckResult.fail(&violation, null);
        self.source.reset();
        self.cancelled = false;
        return self.validate();
    }

    fn finish(self: *const @This(), case_index: u32) checker.CheckResult {
        assert(case_index < ScenarioCount);
        const expectations = scenario_expectations[case_index];

        assert(std.mem.eql(u32, self.expected_counts[0..], expectations.expected_counts[0..]));
        assert(std.mem.eql(bool, self.active[0..], expectations.active[0..]));
        assert(self.cancelled == expectations.cancelled);
        assert(self.saw_cancelled_reject == expectations.saw_cancelled_reject);
        assert(self.saw_fanout == expectations.saw_fanout);
        assert(self.saw_reuse == expectations.saw_reuse);
        assert(self.saw_unregister_without_fire == expectations.saw_unregister_without_fire);

        return self.validate();
    }

    fn nextFreeSlot(self: *const @This()) u32 {
        var slot: u32 = 0;
        while (slot < 16) : (slot += 1) {
            var occupied = false;
            for (0..RegCount) |index| {
                if (self.active[index] and self.slot_indices[index] == slot) {
                    occupied = true;
                    break;
                }
            }
            if (!occupied) return slot;
        }
        unreachable;
    }
};

test "cancel lifecycle sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_sync",
            .run_name = "cancel_lifecycle_sequences",
            .base_seed = .init(0x17b4_2026_0000_9501),
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
        .register_0 => context.registerIndex(0, false),
        .register_1 => context.registerIndex(1, false),
        .register_1_expect_cancelled => context.registerIndex(1, true),
        .cancel => context.cancelNow(),
        .unregister_0 => context.unregisterIndex(0),
        .unregister_1 => context.unregisterIndex(1),
        .reset => context.resetSource(),
        .assert_clear => context.assertClear(),
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
            .register_0 => "register_0",
            .register_1 => "register_1",
            .register_1_expect_cancelled => "register_1_expect_cancelled",
            .cancel => "cancel",
            .unregister_0 => "unregister_0",
            .unregister_1 => "unregister_1",
            .reset => "reset",
            .assert_clear => "assert_clear",
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

fn wakeCount(ctx: ?*anyopaque) void {
    const count: *u32 = @ptrCast(@alignCast(ctx.?));
    count.* += 1;
}
