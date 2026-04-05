const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_memory = @import("static_memory");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const Arena = static_memory.arena.Arena;
const ArenaCapacity = 24;
const ScenarioCount: u32 = 4;
const ActionCount: u32 = 7;

const ActionTag = enum(u32) {
    alloc_16 = 1,
    alloc_8 = 2,
    overflow_1 = 3,
    reset = 4,
    alloc_8_after_reset = 5,
    alloc_16_after_reset = 6,
    overflow_1_after_reset = 7,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_16) },
        .{ .tag = @intFromEnum(ActionTag.alloc_8) },
        .{ .tag = @intFromEnum(ActionTag.overflow_1) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
        .{ .tag = @intFromEnum(ActionTag.alloc_8_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.alloc_16_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.overflow_1_after_reset) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_8) },
        .{ .tag = @intFromEnum(ActionTag.alloc_16) },
        .{ .tag = @intFromEnum(ActionTag.overflow_1) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
        .{ .tag = @intFromEnum(ActionTag.alloc_16_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.alloc_8_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.overflow_1_after_reset) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_16) },
        .{ .tag = @intFromEnum(ActionTag.alloc_8) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
        .{ .tag = @intFromEnum(ActionTag.alloc_8_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.alloc_16_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.overflow_1_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.overflow_1_after_reset) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_8) },
        .{ .tag = @intFromEnum(ActionTag.alloc_16) },
        .{ .tag = @intFromEnum(ActionTag.reset) },
        .{ .tag = @intFromEnum(ActionTag.alloc_16_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.alloc_8_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.overflow_1_after_reset) },
        .{ .tag = @intFromEnum(ActionTag.overflow_1_after_reset) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_memory.arena_model",
        .message = "arena reset and overflow accounting diverged from the bounded reference model",
    },
};

const Context = struct {
    arena: Arena = undefined,
    arena_initialized: bool = false,
    first_allocation: ?[]u8 = null,
    saw_reset: bool = false,
    saw_reuse_after_reset: bool = false,
    expected_used: u64 = 0,
    expected_high_water: u64 = 0,
    expected_overflow_count: u32 = 0,

    fn resetState(self: *@This()) void {
        if (self.arena_initialized) {
            self.arena.deinit();
        }
        self.arena = Arena.init(testing.allocator, ArenaCapacity) catch unreachable;
        self.arena_initialized = true;
        self.first_allocation = null;
        self.saw_reset = false;
        self.saw_reuse_after_reset = false;
        self.expected_used = 0;
        self.expected_high_water = 0;
        self.expected_overflow_count = 0;

        assert(self.arena.capacity() == ArenaCapacity);
        assert(self.arena.used() == 0);
        assert(self.arena.remaining() == ArenaCapacity);
    }

    fn expectState(self: *const @This()) void {
        assert(self.arena_initialized);
        assert(self.arena.capacity() == ArenaCapacity);
        assert(self.arena.used() == self.expected_used);
        assert(self.arena.remaining() == ArenaCapacity - self.expected_used);
        assert(self.arena.highWater() == self.expected_high_water);
        assert(self.arena.overflowCount() == self.expected_overflow_count);

        const report = self.arena.report();
        assert(report.unit == .bytes);
        assert(report.used == self.expected_used);
        assert(report.capacity == ArenaCapacity);
        assert(report.high_water == self.expected_high_water);
        assert(report.overflow_count == self.expected_overflow_count);
    }

    fn alloc(self: *@This(), size: usize) checker.CheckResult {
        const alloc_if = self.arena.allocator();
        const block = alloc_if.alloc(u8, size) catch {
            return checker.CheckResult.fail(&violation, null);
        };
        assert(block.len == size);
        if (self.first_allocation == null) {
            assert(self.first_allocation == null);
            self.first_allocation = block;
        } else if (self.saw_reset and self.first_allocation.?.ptr == block.ptr) {
            self.saw_reuse_after_reset = true;
        }
        self.expected_used += @as(u64, size);
        if (self.expected_used > self.expected_high_water) {
            self.expected_high_water = self.expected_used;
        }
        assert(self.arena.used() == self.expected_used);
        self.expectState();
        return checker.CheckResult.pass(null);
    }

    fn overflow(self: *@This(), size: usize) checker.CheckResult {
        const alloc_if = self.arena.allocator();
        const before_overflow_count = self.expected_overflow_count;
        const before_high_water = self.expected_high_water;

        _ = alloc_if.alloc(u8, size) catch |err| switch (err) {
            error.OutOfMemory => {
                self.expected_overflow_count += 1;
                const attempted_end = self.expected_used + @as(u64, size);
                if (attempted_end > self.expected_high_water) self.expected_high_water = attempted_end;
                assert(self.expected_overflow_count == before_overflow_count + 1);
                assert(self.expected_high_water >= before_high_water);
                self.expectState();
                return checker.CheckResult.pass(null);
            },
        };

        return checker.CheckResult.fail(&violation, null);
    }

    fn resetArena(self: *@This()) checker.CheckResult {
        assert(self.arena.used() == self.expected_used);
        self.arena.reset();
        self.saw_reset = true;
        self.expected_used = 0;
        assert(self.arena.used() == 0);
        assert(self.arena.remaining() == ArenaCapacity);
        self.expectState();
        return checker.CheckResult.pass(null);
    }

    fn validate(self: *const @This()) checker.CheckResult {
        self.expectState();
        if (!self.saw_reset or !self.saw_reuse_after_reset) {
            return checker.CheckResult.fail(&violation, null);
        }
        if (self.expected_used != ArenaCapacity) {
            return checker.CheckResult.fail(&violation, null);
        }
        if (self.expected_overflow_count != 2) {
            return checker.CheckResult.fail(&violation, null);
        }
        if (self.expected_high_water != ArenaCapacity + 1) {
            return checker.CheckResult.fail(&violation, null);
        }
        return checker.CheckResult.pass(null);
    }
};

test "arena reset and overflow behavior stays aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.arena_initialized) context.arena.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_memory",
            .run_name = "arena_model_reset_sequences",
            .base_seed = .init(0x17b4_2026_0000_6201),
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
        .alloc_16 => context.alloc(16),
        .alloc_8 => context.alloc(8),
        .overflow_1 => context.overflow(1),
        .reset => context.resetArena(),
        .alloc_8_after_reset => context.alloc(8),
        .alloc_16_after_reset => context.alloc(16),
        .overflow_1_after_reset => context.overflow(1),
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return context.validate();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .alloc_16 => "alloc_16",
            .alloc_8 => "alloc_8",
            .overflow_1 => "overflow_1",
            .reset => "reset",
            .alloc_8_after_reset => "alloc_8_after_reset",
            .alloc_16_after_reset => "alloc_16_after_reset",
            .overflow_1_after_reset => "overflow_1_after_reset",
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
