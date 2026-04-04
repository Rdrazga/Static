const std = @import("std");
const static_collections = @import("static_collections");
const static_memory = static_collections.memory;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const Vec = static_collections.vec.Vec(u8);
const BudgetLimit: usize = 3;
const InitialCapacity: u32 = 2;
const ScenarioCount: u32 = 4;
const ActionCount: u32 = 8;

const ActionTag = enum(u32) {
    append_one = 1,
    append_two = 2,
    ensure_exact_three = 3,
    append_three = 4,
    append_four_no_space = 5,
    pop_three = 6,
    pop_two = 7,
    pop_one = 8,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.append_one), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.append_two), .value = 2 },
        .{ .tag = @intFromEnum(ActionTag.ensure_exact_three), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.append_three), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.append_four_no_space), .value = 4 },
        .{ .tag = @intFromEnum(ActionTag.pop_three), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.pop_two), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.pop_one), .value = 0 },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.append_one), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.ensure_exact_three), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.append_two), .value = 2 },
        .{ .tag = @intFromEnum(ActionTag.append_three), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.append_four_no_space), .value = 4 },
        .{ .tag = @intFromEnum(ActionTag.pop_three), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.pop_two), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.pop_one), .value = 0 },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.append_two), .value = 2 },
        .{ .tag = @intFromEnum(ActionTag.append_one), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.ensure_exact_three), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.append_three), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.append_four_no_space), .value = 4 },
        .{ .tag = @intFromEnum(ActionTag.pop_three), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.pop_one), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.pop_two), .value = 0 },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.ensure_exact_three), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.append_one), .value = 1 },
        .{ .tag = @intFromEnum(ActionTag.append_two), .value = 2 },
        .{ .tag = @intFromEnum(ActionTag.append_three), .value = 3 },
        .{ .tag = @intFromEnum(ActionTag.append_four_no_space), .value = 4 },
        .{ .tag = @intFromEnum(ActionTag.pop_three), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.pop_two), .value = 0 },
        .{ .tag = @intFromEnum(ActionTag.pop_one), .value = 0 },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_collections.vec_budget_model",
        .message = "vec growth, capacity, or budget accounting diverged from the bounded reference model",
    },
};

const Context = struct {
    budget: static_memory.budget.Budget = undefined,
    vec: Vec = undefined,
    vec_initialized: bool = false,
    values: [3]u8 = undefined,
    len: usize = 0,
    expected_capacity: usize = InitialCapacity,
    expected_budget_used: u64 = @as(u64, InitialCapacity),
    saw_exact_fallback: bool = false,
    saw_no_space_left: bool = false,
    saw_pop_order: bool = false,

    fn resetState(self: *@This()) void {
        if (self.vec_initialized) {
            self.vec.deinit();
        }

        self.budget = static_memory.budget.Budget.init(BudgetLimit) catch
            |err| std.debug.panic("resetState: Budget.init failed: {s}", .{@errorName(err)});
        self.vec = Vec.init(std.testing.allocator, .{
            .initial_capacity = InitialCapacity,
            .budget = &self.budget,
        }) catch |err| std.debug.panic("resetState: Vec.init failed: {s}", .{@errorName(err)});
        self.vec_initialized = true;
        self.values = .{ 0, 0, 0 };
        self.len = 0;
        self.expected_capacity = InitialCapacity;
        self.expected_budget_used = InitialCapacity;
        self.saw_exact_fallback = false;
        self.saw_no_space_left = false;
        self.saw_pop_order = false;

        std.debug.assert(self.vec.len() == 0);
        std.debug.assert(self.vec.capacity() == InitialCapacity);
        std.debug.assert(self.budget.used() == InitialCapacity);
    }

    fn validate(self: *const @This()) checker.CheckResult {
        std.debug.assert(self.vec_initialized);
        std.debug.assert(self.vec.len() == self.len);
        std.debug.assert(self.vec.capacity() == self.expected_capacity);
        std.debug.assert(self.budget.used() == self.expected_budget_used);
        std.debug.assert(self.budget.used() <= self.budget.limit());
        std.debug.assert(self.budget.remaining() + self.budget.used() == self.budget.limit());

        const items = self.vec.itemsConst();
        std.debug.assert(items.len == self.len);
        for (items, 0..) |item, index| {
            std.debug.assert(item == self.values[index]);
        }
        if (!std.mem.eql(u8, items, self.values[0..self.len])) {
            return checker.CheckResult.fail(&violation, null);
        }
        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, self.vec.capacity()) << 64) |
                (@as(u128, self.vec.len()) << 32) |
                @as(u128, self.budget.used()),
        ));
    }

    fn appendValue(self: *@This(), value: u8) checker.CheckResult {
        const before_len = self.len;
        const before_capacity = self.expected_capacity;
        const before_used = self.expected_budget_used;
        self.vec.append(value) catch |err| switch (err) {
            error.NoSpaceLeft => return checker.CheckResult.fail(&violation, null),
            error.Overflow => return checker.CheckResult.fail(&violation, null),
            error.OutOfMemory => return checker.CheckResult.fail(&violation, null),
            error.InvalidConfig => return checker.CheckResult.fail(&violation, null),
        };
        std.debug.assert(self.len == before_len);
        self.values[self.len] = value;
        self.len += 1;
        self.expected_capacity = self.vec.capacity();
        self.expected_budget_used = self.budget.used();
        std.debug.assert(self.expected_capacity >= before_capacity);
        std.debug.assert(self.expected_budget_used >= before_used);
        return self.validate();
    }

    fn ensureExactThree(self: *@This()) checker.CheckResult {
        const before_capacity = self.expected_capacity;
        const before_used = self.expected_budget_used;
        self.vec.ensureCapacity(3) catch |err| switch (err) {
            error.NoSpaceLeft => return checker.CheckResult.fail(&violation, null),
            error.Overflow => return checker.CheckResult.fail(&violation, null),
            error.InvalidConfig => return checker.CheckResult.fail(&violation, null),
            error.OutOfMemory => return checker.CheckResult.fail(&violation, null),
        };
        std.debug.assert(self.vec.capacity() == 3);
        std.debug.assert(self.budget.used() == 3);
        std.debug.assert(before_capacity <= self.vec.capacity());
        std.debug.assert(before_used <= self.budget.used());
        self.expected_capacity = 3;
        self.expected_budget_used = 3;
        self.saw_exact_fallback = true;
        return self.validate();
    }

    fn appendNoSpaceLeft(self: *@This(), value: u8) checker.CheckResult {
        const before_len = self.len;
        const before_capacity = self.expected_capacity;
        const before_used = self.expected_budget_used;
        self.vec.append(value) catch |err| switch (err) {
            error.NoSpaceLeft => {
                self.saw_no_space_left = true;
                std.debug.assert(self.vec.len() == before_len);
                std.debug.assert(self.vec.capacity() == before_capacity);
                std.debug.assert(self.budget.used() == before_used);
                return self.validate();
            },
            else => return checker.CheckResult.fail(&violation, null),
        };
        return checker.CheckResult.fail(&violation, null);
    }

    fn popValue(self: *@This(), expected: ?u8) checker.CheckResult {
        const before_capacity = self.expected_capacity;
        const before_used = self.expected_budget_used;
        const popped = self.vec.pop();
        if (expected == null) {
            if (popped != null) return checker.CheckResult.fail(&violation, null);
            std.debug.assert(self.len == 0);
            std.debug.assert(self.vec.capacity() == before_capacity);
            std.debug.assert(self.budget.used() == before_used);
            self.saw_pop_order = true;
            return self.validate();
        }

        const expected_value = expected.?;
        if (popped == null or popped.? != expected_value) {
            return checker.CheckResult.fail(&violation, null);
        }
        std.debug.assert(self.len > 0);
        self.len -= 1;
        self.values[self.len] = 0;
        std.debug.assert(self.vec.capacity() == before_capacity);
        std.debug.assert(self.budget.used() == before_used);
        if (self.len == 0) self.saw_pop_order = true;
        return self.validate();
    }

    fn finish(self: *const @This()) checker.CheckResult {
        std.debug.assert(self.vec_initialized);
        std.debug.assert(self.len == 0);
        std.debug.assert(self.saw_exact_fallback);
        std.debug.assert(self.saw_no_space_left);
        std.debug.assert(self.saw_pop_order);
        std.debug.assert(self.vec.capacity() == 3);
        std.debug.assert(self.budget.used() == 3);
        return self.validate();
    }
};

test "vec budget-aware capacity growth stays aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.vec_initialized) context.vec.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_collections",
            .run_name = "vec_budget_capacity_sequences",
            .base_seed = .init(0x17b4_2026_0000_7201),
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

    try std.testing.expectEqual(ScenarioCount, summary.executed_case_count);
    try std.testing.expect(summary.failed_case == null);
}

fn nextAction(
    _: *anyopaque,
    run_identity: identity.RunIdentity,
    action_index: u32,
    _: seed.Seed,
) error{}!model.RecordedAction {
    std.debug.assert(run_identity.case_index < ScenarioCount);
    std.debug.assert(action_index < ActionCount);
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
        .append_one => context.appendValue(@intCast(action.value)),
        .append_two => context.appendValue(@intCast(action.value)),
        .ensure_exact_three => context.ensureExactThree(),
        .append_three => context.appendValue(@intCast(action.value)),
        .append_four_no_space => context.appendNoSpaceLeft(@intCast(action.value)),
        .pop_three => context.popValue(3),
        .pop_two => context.popValue(2),
        .pop_one => context.popValue(1),
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
            .append_one => "append_one",
            .append_two => "append_two",
            .ensure_exact_three => "ensure_exact_three",
            .append_three => "append_three",
            .append_four_no_space => "append_four_no_space",
            .pop_three => "pop_three",
            .pop_two => "pop_two",
            .pop_one => "pop_one",
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
