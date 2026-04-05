const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_memory = @import("static_memory");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const Budget = static_memory.budget.Budget;
const BudgetedAllocator = static_memory.budget.BudgetedAllocator;

const ParentBufferLen: usize = 8;
const ScenarioCount: u32 = 3;
const ActionCount: u32 = 6;

const ActionTag = enum(u32) {
    alloc_4 = 1,
    grow_to_6 = 2,
    shrink_to_3 = 3,
    deny_grow_to_8 = 4,
    consume_denied_true = 5,
    consume_denied_false = 6,
    free_live = 7,
    parent_oom_alloc_9 = 8,
    probe_accounting = 9,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_4) },
        .{ .tag = @intFromEnum(ActionTag.deny_grow_to_8) },
        .{ .tag = @intFromEnum(ActionTag.consume_denied_true) },
        .{ .tag = @intFromEnum(ActionTag.consume_denied_false) },
        .{ .tag = @intFromEnum(ActionTag.free_live) },
        .{ .tag = @intFromEnum(ActionTag.probe_accounting) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_4) },
        .{ .tag = @intFromEnum(ActionTag.grow_to_6) },
        .{ .tag = @intFromEnum(ActionTag.shrink_to_3) },
        .{ .tag = @intFromEnum(ActionTag.free_live) },
        .{ .tag = @intFromEnum(ActionTag.consume_denied_false) },
        .{ .tag = @intFromEnum(ActionTag.probe_accounting) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.parent_oom_alloc_9) },
        .{ .tag = @intFromEnum(ActionTag.consume_denied_false) },
        .{ .tag = @intFromEnum(ActionTag.alloc_4) },
        .{ .tag = @intFromEnum(ActionTag.free_live) },
        .{ .tag = @intFromEnum(ActionTag.consume_denied_false) },
        .{ .tag = @intFromEnum(ActionTag.probe_accounting) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_memory.budgeted_allocator_model",
        .message = "budgeted allocator accounting diverged from the bounded reference model",
    },
};

const Context = struct {
    backing: [ParentBufferLen]u8 = undefined,
    fixed_buffer: std.heap.FixedBufferAllocator = undefined,
    budget: Budget = undefined,
    wrapper: BudgetedAllocator = undefined,
    live: ?[]u8 = null,
    budget_limit: u64 = 0,
    expected_used: u64 = 0,
    expected_high_water: u64 = 0,
    expected_overflow: u32 = 0,
    saw_budget_denial: bool = false,
    saw_denied_true: bool = false,
    saw_denied_false: bool = false,
    saw_growth: bool = false,
    saw_shrink: bool = false,
    saw_free: bool = false,
    saw_parent_oom: bool = false,
    saw_parent_oom_recovery: bool = false,
    saw_probe_accounting: bool = false,

    fn resetState(self: *@This(), case_index: usize) void {
        assert(case_index < @as(usize, ScenarioCount));
        self.fixed_buffer = std.heap.FixedBufferAllocator.init(&self.backing);
        self.budget_limit = switch (case_index) {
            0 => 7,
            1 => 12,
            2 => 12,
            else => unreachable,
        };
        self.budget = Budget.init(self.budget_limit) catch unreachable;
        self.wrapper = BudgetedAllocator.init(self.fixed_buffer.allocator(), &self.budget);
        self.live = null;
        self.expected_used = 0;
        self.expected_high_water = 0;
        self.expected_overflow = 0;
        self.saw_budget_denial = false;
        self.saw_denied_true = false;
        self.saw_denied_false = false;
        self.saw_growth = false;
        self.saw_shrink = false;
        self.saw_free = false;
        self.saw_parent_oom = false;
        self.saw_parent_oom_recovery = false;
        self.saw_probe_accounting = false;

        assert(self.budget.limit() == self.budget_limit);
        assert(self.budget.used() == 0);
        assert(self.budget.highWater() == 0);
        assert(self.budget.overflowCount() == 0);
        assert(self.budget.remaining() == self.budget_limit);
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
        const self: *@This() = @ptrCast(@alignCast(context_ptr));
        const tag: ActionTag = @enumFromInt(action.tag);
        const result = switch (tag) {
            .alloc_4 => self.alloc4(),
            .grow_to_6 => self.growTo6(),
            .shrink_to_3 => self.shrinkTo3(),
            .deny_grow_to_8 => self.denyGrowTo8(),
            .consume_denied_true => self.consumeDenied(true),
            .consume_denied_false => self.consumeDenied(false),
            .free_live => self.freeLive(),
            .parent_oom_alloc_9 => self.parentOomAlloc9(),
            .probe_accounting => self.probeAccounting(),
        };
        return .{ .check_result = result };
    }

    fn finish(self: *const @This(), case_index: usize) checker.CheckResult {
        const state_check = self.validateState(case_index);
        if (!state_check.passed) return state_check;

        switch (case_index) {
            0 => {
                assert(self.saw_budget_denial);
                assert(self.saw_denied_true);
                assert(self.saw_denied_false);
                assert(self.saw_free);
                assert(self.saw_probe_accounting);
            },
            1 => {
                assert(self.saw_growth);
                assert(self.saw_shrink);
                assert(self.saw_denied_false);
                assert(self.saw_free);
                assert(self.saw_probe_accounting);
            },
            2 => {
                assert(self.saw_parent_oom);
                assert(self.saw_parent_oom_recovery);
                assert(self.saw_denied_false);
                assert(self.saw_free);
                assert(self.saw_probe_accounting);
            },
            else => unreachable,
        }

        return checker.CheckResult.pass(null);
    }

    fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
        const tag: ActionTag = @enumFromInt(action.tag);
        return .{
            .label = switch (tag) {
                .alloc_4 => "alloc_4",
                .grow_to_6 => "grow_to_6",
                .shrink_to_3 => "shrink_to_3",
                .deny_grow_to_8 => "deny_grow_to_8",
                .consume_denied_true => "consume_denied_true",
                .consume_denied_false => "consume_denied_false",
                .free_live => "free_live",
                .parent_oom_alloc_9 => "parent_oom_alloc_9",
                .probe_accounting => "probe_accounting",
            },
        };
    }

    fn alloc4(self: *@This()) checker.CheckResult {
        assert(self.live == null);
        const alloc_if = self.wrapper.allocator();
        const mem = alloc_if.alloc(u8, 4) catch {
            return checker.CheckResult.fail(&violation, null);
        };
        assert(mem.len == 4);
        self.live = mem;
        self.expected_used = 4;
        if (self.saw_parent_oom) {
            self.saw_parent_oom_recovery = true;
        }
        self.bumpHighWater();
        return self.validateState(null);
    }

    fn growTo6(self: *@This()) checker.CheckResult {
        const live = self.live orelse return checker.CheckResult.fail(&violation, null);
        const alloc_if = self.wrapper.allocator();
        if (!alloc_if.resize(live, 6)) return checker.CheckResult.fail(&violation, null);
        self.live = live.ptr[0..6];
        self.expected_used = 6;
        self.saw_growth = true;
        self.bumpHighWater();
        return self.validateState(null);
    }

    fn shrinkTo3(self: *@This()) checker.CheckResult {
        const live = self.live orelse return checker.CheckResult.fail(&violation, null);
        const alloc_if = self.wrapper.allocator();
        if (!alloc_if.resize(live, 3)) return checker.CheckResult.fail(&violation, null);
        self.live = live[0..3];
        self.expected_used = 3;
        self.saw_shrink = true;
        return self.validateState(null);
    }

    fn denyGrowTo8(self: *@This()) checker.CheckResult {
        const live = self.live orelse return checker.CheckResult.fail(&violation, null);
        const alloc_if = self.wrapper.allocator();
        if (alloc_if.resize(live, 8)) return checker.CheckResult.fail(&violation, null);
        self.saw_budget_denial = true;
        self.expected_overflow += 1;
        self.expected_high_water = 8;
        return self.validateState(null);
    }

    fn consumeDenied(self: *@This(), expected: bool) checker.CheckResult {
        const actual = self.wrapper.takeDeniedLast();
        if (actual != expected) return checker.CheckResult.fail(&violation, null);
        if (expected) {
            self.saw_denied_true = true;
        } else {
            self.saw_denied_false = true;
        }
        return self.validateState(null);
    }

    fn freeLive(self: *@This()) checker.CheckResult {
        const live = self.live orelse return checker.CheckResult.fail(&violation, null);
        const alloc_if = self.wrapper.allocator();
        alloc_if.free(live);
        self.live = null;
        self.expected_used = 0;
        self.saw_free = true;
        return self.validateState(null);
    }

    fn parentOomAlloc9(self: *@This()) checker.CheckResult {
        assert(self.live == null);
        const alloc_if = self.wrapper.allocator();
        _ = alloc_if.alloc(u8, 9) catch |err| switch (err) {
            error.OutOfMemory => {
                self.saw_parent_oom = true;
                self.expected_high_water = 9;
                return self.validateState(null);
            },
        };
        return checker.CheckResult.fail(&violation, null);
    }

    fn probeAccounting(self: *@This()) checker.CheckResult {
        self.saw_probe_accounting = true;
        return self.validateState(null);
    }

    fn validateState(self: *const @This(), case_index: ?usize) checker.CheckResult {
        const report = self.budget.reportBytes();
        assert(self.budget.limit() == self.budget_limit);
        assert(self.budget.used() == self.expected_used);
        assert(self.budget.highWater() == self.expected_high_water);
        assert(self.budget.overflowCount() == self.expected_overflow);
        assert(self.budget.remaining() + self.budget.used() == self.budget.limit());
        assert(report.used == self.expected_used);
        assert(report.high_water == self.expected_high_water);
        assert(report.capacity == self.budget_limit);
        assert(report.overflow_count == self.expected_overflow);

        if (self.live) |live| {
            assert(live.len == self.expected_used);
        } else {
            assert(self.expected_used == 0);
        }

        if (case_index) |idx| {
            assert(idx < @as(usize, ScenarioCount));
        }
        return checker.CheckResult.pass(null);
    }

    fn bumpHighWater(self: *@This()) void {
        if (self.expected_used > self.expected_high_water) {
            self.expected_high_water = self.expected_used;
        }
        assert(self.expected_high_water >= self.expected_used);
    }
};

test "budgeted allocator runtime sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState(0);

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_memory",
            .run_name = "budgeted_allocator_runtime_sequences",
            .base_seed = .init(0x17b4_2026_0000_6401),
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
        .alloc_4 => context.alloc4(),
        .grow_to_6 => context.growTo6(),
        .shrink_to_3 => context.shrinkTo3(),
        .deny_grow_to_8 => context.denyGrowTo8(),
        .consume_denied_true => context.consumeDenied(true),
        .consume_denied_false => context.consumeDenied(false),
        .free_live => context.freeLive(),
        .parent_oom_alloc_9 => context.parentOomAlloc9(),
        .probe_accounting => context.probeAccounting(),
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index < ScenarioCount);
    return context.finish(run_identity.case_index);
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .alloc_4 => "alloc_4",
            .grow_to_6 => "grow_to_6",
            .shrink_to_3 => "shrink_to_3",
            .deny_grow_to_8 => "deny_grow_to_8",
            .consume_denied_true => "consume_denied_true",
            .consume_denied_false => "consume_denied_false",
            .free_live => "free_live",
            .parent_oom_alloc_9 => "parent_oom_alloc_9",
            .probe_accounting => "probe_accounting",
        },
    };
}

fn reset(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
) error{}!void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index < ScenarioCount);
    context.resetState(run_identity.case_index);
}
