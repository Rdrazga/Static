const std = @import("std");
const static_scheduling = @import("static_scheduling");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;

const Wheel = static_scheduling.timer_wheel.TimerWheel(u32);

const ActionTag = enum(u32) {
    schedule_immediate = 1,
    schedule_short = 2,
    schedule_long = 3,
    cancel_oldest = 4,
    tick = 5,
};

const delivery_violation = [_]checker.Violation{
    .{
        .code = "timer_wheel_delivery",
        .message = "timer wheel delivered entries out of the expected bounded order",
    },
};

const cancel_violation = [_]checker.Violation{
    .{
        .code = "timer_wheel_cancel",
        .message = "timer wheel cancel path diverged from the bounded reference model",
    },
};

const capacity_violation = [_]checker.Violation{
    .{
        .code = "timer_wheel_capacity",
        .message = "timer wheel capacity behavior diverged from the bounded reference model",
    },
};

const finish_violation = [_]checker.Violation{
    .{
        .code = "timer_wheel_finish",
        .message = "timer wheel retained unexpected active timers after bounded drain",
    },
};

const ExpectedTimer = struct {
    active: bool = false,
    id: static_scheduling.timer_wheel.TimerId = undefined,
    entry: u32 = 0,
    due_tick: u64 = 0,
    sequence_no: u32 = 0,
};

const TimerWheelModelContext = struct {
    allocator: std.mem.Allocator,
    wheel: Wheel,
    expected: [8]ExpectedTimer = [_]ExpectedTimer{.{}} ** 8,
    next_sequence_no: u32 = 0,
    drain_buffer: [8]u32 = [_]u32{0} ** 8,

    fn init(allocator: std.mem.Allocator) !TimerWheelModelContext {
        std.debug.assert(@sizeOf(ExpectedTimer) > 0);
        var context = TimerWheelModelContext{
            .allocator = allocator,
            .wheel = try Wheel.init(allocator, .{
                .buckets = 8,
                .entries_max = 8,
            }),
        };
        std.debug.assert(context.wheel.nowTick() == 0);
        std.debug.assert(context.activeCount() == 0);
        return context;
    }

    fn deinit(self: *TimerWheelModelContext) void {
        std.debug.assert(self.expected.len == 8);
        self.wheel.deinit();
        self.* = undefined;
    }

    fn reset(self: *TimerWheelModelContext) !void {
        self.wheel.deinit();
        self.wheel = try Wheel.init(self.allocator, .{
            .buckets = 8,
            .entries_max = 8,
        });
        self.expected = [_]ExpectedTimer{.{}} ** 8;
        self.next_sequence_no = 0;
        @memset(self.drain_buffer[0..], 0);
        std.debug.assert(self.wheel.nowTick() == 0);
        std.debug.assert(self.activeCount() == 0);
    }

    fn activeCount(self: *const TimerWheelModelContext) u32 {
        var count: u32 = 0;
        for (self.expected) |timer| {
            if (timer.active) count += 1;
        }
        std.debug.assert(count <= self.expected.len);
        return count;
    }

    fn firstFreeSlotIndex(self: *const TimerWheelModelContext) ?usize {
        for (self.expected, 0..) |timer, index| {
            if (!timer.active) return index;
        }
        return null;
    }

    fn oldestActiveSlotIndex(self: *const TimerWheelModelContext) ?usize {
        var best_index: ?usize = null;
        var best_sequence_no: u32 = 0;
        for (self.expected, 0..) |timer, index| {
            if (!timer.active) continue;
            if (best_index == null or timer.sequence_no < best_sequence_no) {
                best_index = index;
                best_sequence_no = timer.sequence_no;
            }
        }
        return best_index;
    }

    fn checkpoint(self: *const TimerWheelModelContext) checker.CheckpointDigest {
        const digest_value = (@as(u128, self.wheel.nowTick()) << 64) | self.activeCount();
        return checker.CheckpointDigest.init(digest_value);
    }

    fn pass(self: *const TimerWheelModelContext) checker.CheckResult {
        return checker.CheckResult.pass(self.checkpoint());
    }

    fn fail(
        self: *const TimerWheelModelContext,
        violations: []const checker.Violation,
    ) checker.CheckResult {
        return checker.CheckResult.fail(violations, self.checkpoint());
    }

    fn performSchedule(
        self: *TimerWheelModelContext,
        delay_ticks: u64,
        entry: u32,
    ) static_scheduling.timer_wheel.TimerError!checker.CheckResult {
        std.debug.assert(entry != 0);
        if (self.firstFreeSlotIndex()) |slot_index| {
            const id = try self.wheel.schedule(entry, delay_ticks);
            self.expected[slot_index] = .{
                .active = true,
                .id = id,
                .entry = entry,
                .due_tick = self.wheel.nowTick() + delay_ticks + 1,
                .sequence_no = self.next_sequence_no,
            };
            self.next_sequence_no += 1;
            std.debug.assert(self.expected[slot_index].active);
            return self.pass();
        }

        _ = self.wheel.schedule(entry, delay_ticks) catch |err| {
            if (err == error.NoSpaceLeft) return self.pass();
            return err;
        };
        return self.fail(&capacity_violation);
    }

    fn performCancelOldest(self: *TimerWheelModelContext) static_scheduling.timer_wheel.TimerError!checker.CheckResult {
        const slot_index = self.oldestActiveSlotIndex() orelse return self.pass();
        const expected_timer = self.expected[slot_index];
        const cancelled = try self.wheel.cancel(expected_timer.id);
        if (cancelled != expected_timer.entry) return self.fail(&cancel_violation);
        self.expected[slot_index] = .{};
        std.debug.assert(!self.expected[slot_index].active);
        return self.pass();
    }

    fn collectDueSlots(
        self: *const TimerWheelModelContext,
        due_tick: u64,
        due_slots: *[8]usize,
    ) u32 {
        var due_count: u32 = 0;
        for (self.expected, 0..) |timer, index| {
            if (!timer.active or timer.due_tick != due_tick) continue;
            due_slots[due_count] = index;
            due_count += 1;
        }

        var index: u32 = 1;
        while (index < due_count) : (index += 1) {
            const slot_index = due_slots[index];
            var cursor = index;
            while (cursor > 0 and self.expected[due_slots[cursor - 1]].sequence_no > self.expected[slot_index].sequence_no) {
                due_slots[cursor] = due_slots[cursor - 1];
                cursor -= 1;
            }
            due_slots[cursor] = slot_index;
        }

        std.debug.assert(due_count <= self.expected.len);
        return due_count;
    }

    fn performTick(self: *TimerWheelModelContext) static_scheduling.timer_wheel.TimerError!checker.CheckResult {
        const due_tick = self.wheel.nowTick() + 1;
        var due_slots: [8]usize = undefined;
        const expected_due_count = self.collectDueSlots(due_tick, &due_slots);
        const actual_due_count = try self.wheel.tick(&self.drain_buffer);
        if (actual_due_count != expected_due_count) return self.fail(&delivery_violation);

        var index: u32 = 0;
        while (index < expected_due_count) : (index += 1) {
            const slot_index = due_slots[index];
            if (self.drain_buffer[index] != self.expected[slot_index].entry) {
                return self.fail(&delivery_violation);
            }
            self.expected[slot_index] = .{};
        }

        std.debug.assert(self.wheel.nowTick() == due_tick);
        return self.pass();
    }

    fn finish(self: *TimerWheelModelContext) static_scheduling.timer_wheel.TimerError!checker.CheckResult {
        var guard: u32 = 0;
        while (self.activeCount() != 0 and guard < 32) : (guard += 1) {
            const tick_result = try self.performTick();
            if (!tick_result.passed) return tick_result;
        }
        if (self.activeCount() != 0) return self.fail(&finish_violation);
        return self.pass();
    }
};

fn nextAction(
    _: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action_seed: seed_mod.Seed,
) static_scheduling.timer_wheel.TimerError!model.RecordedAction {
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x7a61_3b9d_c412_0081);
    const random = prng.random();
    const choice = random.uintLessThan(u32, 5);
    const entry = 1 + random.uintLessThan(u32, 4096);
    const tag: ActionTag = switch (choice) {
        0 => .schedule_immediate,
        1 => .schedule_short,
        2 => .schedule_long,
        3 => .cancel_oldest,
        else => .tick,
    };
    return .{
        .tag = @intFromEnum(tag),
        .value = entry,
    };
}

fn step(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action: model.RecordedAction,
) static_scheduling.timer_wheel.TimerError!model.ModelStep {
    const context: *TimerWheelModelContext = @ptrCast(@alignCast(context_ptr));
    const tag: ActionTag = @enumFromInt(action.tag);
    const result = switch (tag) {
        .schedule_immediate => try context.performSchedule(0, @intCast(action.value)),
        .schedule_short => try context.performSchedule(1, @intCast(action.value)),
        .schedule_long => try context.performSchedule(3, @intCast(action.value)),
        .cancel_oldest => try context.performCancelOldest(),
        .tick => try context.performTick(),
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
) static_scheduling.timer_wheel.TimerError!checker.CheckResult {
    const context: *TimerWheelModelContext = @ptrCast(@alignCast(context_ptr));
    return context.finish();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .schedule_immediate => "schedule_immediate",
            .schedule_short => "schedule_short",
            .schedule_long => "schedule_long",
            .cancel_oldest => "cancel_oldest",
            .tick => "tick",
        },
    };
}

fn reset(context_ptr: *anyopaque, _: identity.RunIdentity) static_scheduling.timer_wheel.TimerError!void {
    const context: *TimerWheelModelContext = @ptrCast(@alignCast(context_ptr));
    try context.reset();
}

test "timer wheel operation sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(static_scheduling.timer_wheel.TimerError);
    const Runner = model.ModelRunner(static_scheduling.timer_wheel.TimerError);

    var context = try TimerWheelModelContext.init(std.testing.allocator);
    defer context.deinit();

    var action_storage: [24]model.RecordedAction = undefined;
    var reduction_scratch: [24]model.RecordedAction = undefined;

    const summary = try model.runModelCases(static_scheduling.timer_wheel.TimerError, Runner{
        .config = .{
            .package_name = "static_scheduling",
            .run_name = "timer_wheel_model",
            .base_seed = .init(0x17b4_2026_0000_3101),
            .build_mode = .debug,
            .case_count_max = 96,
            .action_count_max = action_storage.len,
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

    try std.testing.expectEqual(@as(u32, 96), summary.executed_case_count);
    if (summary.failed_case) |failed_case| {
        var summary_buffer: [1024]u8 = undefined;
        const summary_text = try model.formatFailedCaseSummary(
            static_scheduling.timer_wheel.TimerError,
            &summary_buffer,
            Target{
                .context = &context,
                .reset_fn = reset,
                .next_action_fn = nextAction,
                .step_fn = step,
                .finish_fn = finish,
                .describe_action_fn = describe,
            },
            failed_case,
        );
        std.debug.print("{s}", .{summary_text});
        return error.TestUnexpectedResult;
    }
}
