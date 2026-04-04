const std = @import("std");
const static_memory = @import("static_memory");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const Slab = static_memory.slab.Slab;

const SmallClassSize: u32 = 16;
const LargeClassSize: u32 = 32;
const SmallAllocLen: u32 = 8;
const LargeAllocLen: u32 = 24;
const SmallClassAlignment: u32 = 16;
const LargeClassAlignment: u32 = 32;
const SlabCapacityBytes: u64 = @as(u64, SmallClassSize) + @as(u64, LargeClassSize);
const ScenarioCount: u32 = 4;
const ActionCount: u32 = 16;

const ActionTag = enum(u32) {
    alloc_small = 1,
    alloc_large = 2,
    exhaust_small = 3,
    exhaust_large = 4,
    unsupported_size_mid = 5,
    unsupported_size_large = 6,
    invalid_small_align_free = 7,
    invalid_large_align_free = 8,
    free_small_for_reuse = 9,
    double_free_small = 10,
    reuse_small = 11,
    free_small_final = 12,
    free_large_for_reuse = 13,
    double_free_large = 14,
    reuse_large = 15,
    free_large_final = 16,
};

const slab_violation = [_]checker.Violation{
    .{
        .code = "static_memory.slab_model",
        .message = "slab class routing, reuse, or misuse handling diverged from the bounded reference model",
    },
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_small) },
        .{ .tag = @intFromEnum(ActionTag.alloc_large) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_small) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_large) },
        .{ .tag = @intFromEnum(ActionTag.unsupported_size_mid) },
        .{ .tag = @intFromEnum(ActionTag.unsupported_size_large) },
        .{ .tag = @intFromEnum(ActionTag.invalid_small_align_free) },
        .{ .tag = @intFromEnum(ActionTag.invalid_large_align_free) },
        .{ .tag = @intFromEnum(ActionTag.free_small_for_reuse) },
        .{ .tag = @intFromEnum(ActionTag.double_free_small) },
        .{ .tag = @intFromEnum(ActionTag.reuse_small) },
        .{ .tag = @intFromEnum(ActionTag.free_small_final) },
        .{ .tag = @intFromEnum(ActionTag.free_large_for_reuse) },
        .{ .tag = @intFromEnum(ActionTag.double_free_large) },
        .{ .tag = @intFromEnum(ActionTag.reuse_large) },
        .{ .tag = @intFromEnum(ActionTag.free_large_final) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_large) },
        .{ .tag = @intFromEnum(ActionTag.alloc_small) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_large) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_small) },
        .{ .tag = @intFromEnum(ActionTag.invalid_large_align_free) },
        .{ .tag = @intFromEnum(ActionTag.invalid_small_align_free) },
        .{ .tag = @intFromEnum(ActionTag.unsupported_size_large) },
        .{ .tag = @intFromEnum(ActionTag.unsupported_size_mid) },
        .{ .tag = @intFromEnum(ActionTag.free_large_for_reuse) },
        .{ .tag = @intFromEnum(ActionTag.double_free_large) },
        .{ .tag = @intFromEnum(ActionTag.reuse_large) },
        .{ .tag = @intFromEnum(ActionTag.free_large_final) },
        .{ .tag = @intFromEnum(ActionTag.free_small_for_reuse) },
        .{ .tag = @intFromEnum(ActionTag.double_free_small) },
        .{ .tag = @intFromEnum(ActionTag.reuse_small) },
        .{ .tag = @intFromEnum(ActionTag.free_small_final) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_small) },
        .{ .tag = @intFromEnum(ActionTag.alloc_large) },
        .{ .tag = @intFromEnum(ActionTag.invalid_small_align_free) },
        .{ .tag = @intFromEnum(ActionTag.invalid_large_align_free) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_small) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_large) },
        .{ .tag = @intFromEnum(ActionTag.unsupported_size_mid) },
        .{ .tag = @intFromEnum(ActionTag.unsupported_size_large) },
        .{ .tag = @intFromEnum(ActionTag.free_small_for_reuse) },
        .{ .tag = @intFromEnum(ActionTag.double_free_small) },
        .{ .tag = @intFromEnum(ActionTag.reuse_small) },
        .{ .tag = @intFromEnum(ActionTag.free_large_for_reuse) },
        .{ .tag = @intFromEnum(ActionTag.double_free_large) },
        .{ .tag = @intFromEnum(ActionTag.reuse_large) },
        .{ .tag = @intFromEnum(ActionTag.free_small_final) },
        .{ .tag = @intFromEnum(ActionTag.free_large_final) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.alloc_large) },
        .{ .tag = @intFromEnum(ActionTag.alloc_small) },
        .{ .tag = @intFromEnum(ActionTag.unsupported_size_large) },
        .{ .tag = @intFromEnum(ActionTag.unsupported_size_mid) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_large) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_small) },
        .{ .tag = @intFromEnum(ActionTag.invalid_large_align_free) },
        .{ .tag = @intFromEnum(ActionTag.invalid_small_align_free) },
        .{ .tag = @intFromEnum(ActionTag.free_large_for_reuse) },
        .{ .tag = @intFromEnum(ActionTag.double_free_large) },
        .{ .tag = @intFromEnum(ActionTag.reuse_large) },
        .{ .tag = @intFromEnum(ActionTag.free_small_for_reuse) },
        .{ .tag = @intFromEnum(ActionTag.double_free_small) },
        .{ .tag = @intFromEnum(ActionTag.reuse_small) },
        .{ .tag = @intFromEnum(ActionTag.free_large_final) },
        .{ .tag = @intFromEnum(ActionTag.free_small_final) },
    },
};

const Context = struct {
    slab: Slab = undefined,
    slab_initialized: bool = false,
    small_block: ?[]u8 = null,
    large_block: ?[]u8 = null,
    small_stale_block: ?[]u8 = null,
    large_stale_block: ?[]u8 = null,
    small_initial_ptr: usize = 0,
    large_initial_ptr: usize = 0,
    saw_small_exhaustion: bool = false,
    saw_large_exhaustion: bool = false,
    saw_small_reuse: bool = false,
    saw_large_reuse: bool = false,
    saw_unsupported_mid: bool = false,
    saw_unsupported_large: bool = false,
    saw_small_invalid_align: bool = false,
    saw_large_invalid_align: bool = false,
    saw_small_double_free: bool = false,
    saw_large_double_free: bool = false,
    expected_used_bytes: u64 = 0,
    expected_high_water_bytes: u64 = 0,
    expected_overflow_count: u32 = 0,

    fn resetState(self: *@This()) void {
        if (self.slab_initialized) {
            self.slab.deinit();
        }
        self.slab = Slab.init(std.testing.allocator, .{
            .class_sizes = &[_]u32{ SmallClassSize, LargeClassSize },
            .class_counts = &[_]u32{ 1, 1 },
            .allow_large_fallback = false,
        }) catch unreachable;
        self.slab_initialized = true;
        self.small_block = null;
        self.large_block = null;
        self.small_stale_block = null;
        self.large_stale_block = null;
        self.small_initial_ptr = 0;
        self.large_initial_ptr = 0;
        self.saw_small_exhaustion = false;
        self.saw_large_exhaustion = false;
        self.saw_small_reuse = false;
        self.saw_large_reuse = false;
        self.saw_unsupported_mid = false;
        self.saw_unsupported_large = false;
        self.saw_small_invalid_align = false;
        self.saw_large_invalid_align = false;
        self.saw_small_double_free = false;
        self.saw_large_double_free = false;
        self.expected_used_bytes = 0;
        self.expected_high_water_bytes = 0;
        self.expected_overflow_count = 0;

        const report = self.slab.report();
        std.debug.assert(report.capacity == SlabCapacityBytes);
        std.debug.assert(report.used == 0);
        std.debug.assert(report.high_water == 0);
        std.debug.assert(report.overflow_count == 0);
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
        const self: *@This() = @ptrCast(@alignCast(context_ptr));
        const tag: ActionTag = @enumFromInt(action.tag);
        const result = switch (tag) {
            .alloc_small => self.allocSmall(),
            .alloc_large => self.allocLarge(),
            .exhaust_small => self.exhaustSmall(),
            .exhaust_large => self.exhaustLarge(),
            .unsupported_size_mid => self.unsupportedSizeMid(),
            .unsupported_size_large => self.unsupportedSizeLarge(),
            .invalid_small_align_free => self.invalidSmallAlignFree(),
            .invalid_large_align_free => self.invalidLargeAlignFree(),
            .free_small_for_reuse => self.freeSmallForReuse(),
            .double_free_small => self.doubleFreeSmall(),
            .reuse_small => self.reuseSmall(),
            .free_small_final => self.freeSmallFinal(),
            .free_large_for_reuse => self.freeLargeForReuse(),
            .double_free_large => self.doubleFreeLarge(),
            .reuse_large => self.reuseLarge(),
            .free_large_final => self.freeLargeFinal(),
        };
        return .{ .check_result = result };
    }

    fn finishModel(self: *const @This()) checker.CheckResult {
        const state_check = self.validate();
        if (!state_check.passed) return state_check;
        const report = self.slab.report();
        std.debug.assert(self.small_block == null);
        std.debug.assert(self.large_block == null);
        std.debug.assert(self.small_stale_block == null);
        std.debug.assert(self.large_stale_block == null);
        std.debug.assert(self.saw_small_exhaustion);
        std.debug.assert(self.saw_large_exhaustion);
        std.debug.assert(self.saw_small_reuse);
        std.debug.assert(self.saw_large_reuse);
        std.debug.assert(self.saw_unsupported_mid);
        std.debug.assert(self.saw_unsupported_large);
        std.debug.assert(self.saw_small_invalid_align);
        std.debug.assert(self.saw_large_invalid_align);
        std.debug.assert(self.saw_small_double_free);
        std.debug.assert(self.saw_large_double_free);
        std.debug.assert(report.capacity == SlabCapacityBytes);
        std.debug.assert(report.used == 0);
        std.debug.assert(report.high_water == SlabCapacityBytes);
        std.debug.assert(report.overflow_count == 2);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            @as(u128, report.capacity) ^
                (@as(u128, report.high_water) << 32) ^
                (@as(u128, report.overflow_count) << 96),
        ));
    }

    fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
        const tag: ActionTag = @enumFromInt(action.tag);
        return .{
            .label = switch (tag) {
                .alloc_small => "alloc_small",
                .alloc_large => "alloc_large",
                .exhaust_small => "exhaust_small",
                .exhaust_large => "exhaust_large",
                .unsupported_size_mid => "unsupported_size_mid",
                .unsupported_size_large => "unsupported_size_large",
                .invalid_small_align_free => "invalid_small_align_free",
                .invalid_large_align_free => "invalid_large_align_free",
                .free_small_for_reuse => "free_small_for_reuse",
                .double_free_small => "double_free_small",
                .reuse_small => "reuse_small",
                .free_small_final => "free_small_final",
                .free_large_for_reuse => "free_large_for_reuse",
                .double_free_large => "double_free_large",
                .reuse_large => "reuse_large",
                .free_large_final => "free_large_final",
            },
        };
    }

    fn allocSmall(self: *@This()) checker.CheckResult {
        std.debug.assert(self.small_block == null);
        std.debug.assert(self.slab.report().capacity == SlabCapacityBytes);
        const block = self.slab.alloc(SmallAllocLen, SmallClassAlignment) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        std.debug.assert(block.len == SmallAllocLen);
        self.small_block = block;
        if (self.small_initial_ptr == 0) {
            self.small_initial_ptr = @intFromPtr(block.ptr);
            std.debug.assert(self.small_initial_ptr != 0);
        }
        self.expected_used_bytes += SmallClassSize;
        self.updateHighWater();
        return self.validate();
    }

    fn allocLarge(self: *@This()) checker.CheckResult {
        std.debug.assert(self.large_block == null);
        std.debug.assert(self.slab.report().capacity == SlabCapacityBytes);
        const block = self.slab.alloc(LargeAllocLen, LargeClassAlignment) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        std.debug.assert(block.len == LargeAllocLen);
        self.large_block = block;
        if (self.large_initial_ptr == 0) {
            self.large_initial_ptr = @intFromPtr(block.ptr);
            std.debug.assert(self.large_initial_ptr != 0);
        }
        self.expected_used_bytes += LargeClassSize;
        self.updateHighWater();
        return self.validate();
    }

    fn exhaustSmall(self: *@This()) checker.CheckResult {
        std.debug.assert(self.small_block != null);
        tryExpectNoSpaceLeft(self.slab.alloc(SmallAllocLen, SmallClassAlignment), &self.saw_small_exhaustion) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        self.expected_overflow_count += 1;
        return self.validate();
    }

    fn exhaustLarge(self: *@This()) checker.CheckResult {
        std.debug.assert(self.large_block != null);
        tryExpectNoSpaceLeft(self.slab.alloc(LargeAllocLen, LargeClassAlignment), &self.saw_large_exhaustion) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        self.expected_overflow_count += 1;
        return self.validate();
    }

    fn unsupportedSizeMid(self: *@This()) checker.CheckResult {
        _ = self.slab.alloc(LargeClassSize + 8, SmallClassAlignment) catch |err| switch (err) {
            error.UnsupportedSize => {
                self.saw_unsupported_mid = true;
                return self.validate();
            },
            else => return checker.CheckResult.fail(&slab_violation, null),
        };
        return checker.CheckResult.fail(&slab_violation, null);
    }

    fn unsupportedSizeLarge(self: *@This()) checker.CheckResult {
        _ = self.slab.alloc(LargeClassSize + 16, LargeClassAlignment) catch |err| switch (err) {
            error.UnsupportedSize => {
                self.saw_unsupported_large = true;
                return self.validate();
            },
            else => return checker.CheckResult.fail(&slab_violation, null),
        };
        return checker.CheckResult.fail(&slab_violation, null);
    }

    fn invalidSmallAlignFree(self: *@This()) checker.CheckResult {
        const live = self.small_block orelse return checker.CheckResult.fail(&slab_violation, null);
        self.slab.free(live, LargeClassAlignment) catch |err| switch (err) {
            error.InvalidBlock => {
                self.saw_small_invalid_align = true;
                return self.validate();
            },
            else => return checker.CheckResult.fail(&slab_violation, null),
        };
        return checker.CheckResult.fail(&slab_violation, null);
    }

    fn invalidLargeAlignFree(self: *@This()) checker.CheckResult {
        const live = self.large_block orelse return checker.CheckResult.fail(&slab_violation, null);
        self.slab.free(live, LargeClassAlignment * 2) catch |err| switch (err) {
            error.InvalidAlignment => {
                self.saw_large_invalid_align = true;
                return self.validate();
            },
            error.InvalidBlock => {
                self.saw_large_invalid_align = true;
                return self.validate();
            },
            else => return checker.CheckResult.fail(&slab_violation, null),
        };
        return checker.CheckResult.fail(&slab_violation, null);
    }

    fn freeSmallForReuse(self: *@This()) checker.CheckResult {
        const live = self.small_block orelse return checker.CheckResult.fail(&slab_violation, null);
        std.debug.assert(self.small_stale_block == null);
        self.slab.free(live, SmallClassAlignment) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        self.small_stale_block = live;
        self.small_block = null;
        self.expected_used_bytes -= SmallClassSize;
        return self.validate();
    }

    fn doubleFreeSmall(self: *@This()) checker.CheckResult {
        const stale = self.small_stale_block orelse return checker.CheckResult.fail(&slab_violation, null);
        self.slab.free(stale, SmallClassAlignment) catch |err| switch (err) {
            error.InvalidBlock => {
                self.saw_small_double_free = true;
                self.small_stale_block = null;
                return self.validate();
            },
            else => return checker.CheckResult.fail(&slab_violation, null),
        };
        return checker.CheckResult.fail(&slab_violation, null);
    }

    fn reuseSmall(self: *@This()) checker.CheckResult {
        std.debug.assert(self.small_block == null);
        const block = self.slab.alloc(SmallAllocLen, SmallClassAlignment) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        std.debug.assert(block.len == SmallAllocLen);
        std.debug.assert(self.small_initial_ptr != 0);
        std.debug.assert(@intFromPtr(block.ptr) == self.small_initial_ptr);
        self.small_block = block;
        self.saw_small_reuse = true;
        self.expected_used_bytes += SmallClassSize;
        self.updateHighWater();
        return self.validate();
    }

    fn freeSmallFinal(self: *@This()) checker.CheckResult {
        const live = self.small_block orelse return checker.CheckResult.fail(&slab_violation, null);
        self.slab.free(live, SmallClassAlignment) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        self.small_block = null;
        self.small_stale_block = null;
        self.expected_used_bytes -= SmallClassSize;
        return self.validate();
    }

    fn freeLargeForReuse(self: *@This()) checker.CheckResult {
        const live = self.large_block orelse return checker.CheckResult.fail(&slab_violation, null);
        std.debug.assert(self.large_stale_block == null);
        self.slab.free(live, LargeClassAlignment) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        self.large_stale_block = live;
        self.large_block = null;
        self.expected_used_bytes -= LargeClassSize;
        return self.validate();
    }

    fn doubleFreeLarge(self: *@This()) checker.CheckResult {
        const stale = self.large_stale_block orelse return checker.CheckResult.fail(&slab_violation, null);
        self.slab.free(stale, LargeClassAlignment) catch |err| switch (err) {
            error.InvalidBlock => {
                self.saw_large_double_free = true;
                self.large_stale_block = null;
                return self.validate();
            },
            else => return checker.CheckResult.fail(&slab_violation, null),
        };
        return checker.CheckResult.fail(&slab_violation, null);
    }

    fn reuseLarge(self: *@This()) checker.CheckResult {
        std.debug.assert(self.large_block == null);
        const block = self.slab.alloc(LargeAllocLen, LargeClassAlignment) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        std.debug.assert(block.len == LargeAllocLen);
        std.debug.assert(self.large_initial_ptr != 0);
        std.debug.assert(@intFromPtr(block.ptr) == self.large_initial_ptr);
        self.large_block = block;
        self.saw_large_reuse = true;
        self.expected_used_bytes += LargeClassSize;
        self.updateHighWater();
        return self.validate();
    }

    fn freeLargeFinal(self: *@This()) checker.CheckResult {
        const live = self.large_block orelse return checker.CheckResult.fail(&slab_violation, null);
        self.slab.free(live, LargeClassAlignment) catch {
            return checker.CheckResult.fail(&slab_violation, null);
        };
        self.large_block = null;
        self.large_stale_block = null;
        self.expected_used_bytes -= LargeClassSize;
        return self.validate();
    }

    fn validate(self: *const @This()) checker.CheckResult {
        const report = self.slab.report();
        const expected_used = self.expected_used_bytes;
        std.debug.assert(expected_used <= SlabCapacityBytes);
        std.debug.assert(report.capacity == SlabCapacityBytes);
        std.debug.assert(report.used == expected_used);
        std.debug.assert(report.high_water == self.expected_high_water_bytes);
        std.debug.assert(report.overflow_count == self.expected_overflow_count);

        if (self.small_block) |block| {
            std.debug.assert(block.len == SmallAllocLen);
            std.debug.assert(@intFromPtr(block.ptr) == self.small_initial_ptr);
        }
        if (self.large_block) |block| {
            std.debug.assert(block.len == LargeAllocLen);
            std.debug.assert(@intFromPtr(block.ptr) == self.large_initial_ptr);
        }
        if (self.small_stale_block) |block| {
            std.debug.assert(block.len == SmallAllocLen);
        }
        if (self.large_stale_block) |block| {
            std.debug.assert(block.len == LargeAllocLen);
        }

        return checker.CheckResult.pass(checker.CheckpointDigest.init(@as(u128, report.used) ^ (@as(u128, report.overflow_count) << 32) ^ (@as(u128, report.high_water) << 64)));
    }

    fn updateHighWater(self: *@This()) void {
        if (self.expected_used_bytes > self.expected_high_water_bytes) {
            self.expected_high_water_bytes = self.expected_used_bytes;
        }
        std.debug.assert(self.expected_high_water_bytes >= self.expected_used_bytes);
    }
};

fn tryExpectNoSpaceLeft(
    result: error{ OutOfMemory, InvalidConfig, InvalidAlignment, InvalidBlock, NoSpaceLeft, UnsupportedSize, Overflow }![]u8,
    saw_flag: *bool,
) !void {
    _ = result catch |err| switch (err) {
        error.NoSpaceLeft => {
            saw_flag.* = true;
            return;
        },
        else => return error.InvalidBlock,
    };
    return error.InvalidBlock;
}

test "slab model covers class routing reuse exhaustion and invalid frees" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.slab_initialized) context.slab.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_memory",
            .run_name = "slab_model_class_reuse_exhaustion",
            .base_seed = .init(0x17b4_2026_0000_6301),
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
        .alloc_small => context.allocSmall(),
        .alloc_large => context.allocLarge(),
        .exhaust_small => context.exhaustSmall(),
        .exhaust_large => context.exhaustLarge(),
            .unsupported_size_mid => context.unsupportedSizeMid(),
            .unsupported_size_large => context.unsupportedSizeLarge(),
            .invalid_small_align_free => context.invalidSmallAlignFree(),
            .invalid_large_align_free => context.invalidLargeAlignFree(),
        .free_small_for_reuse => context.freeSmallForReuse(),
        .double_free_small => context.doubleFreeSmall(),
        .reuse_small => context.reuseSmall(),
        .free_small_final => context.freeSmallFinal(),
        .free_large_for_reuse => context.freeLargeForReuse(),
        .double_free_large => context.doubleFreeLarge(),
        .reuse_large => context.reuseLarge(),
        .free_large_final => context.freeLargeFinal(),
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return context.finishModel();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .alloc_small => "alloc_small",
            .alloc_large => "alloc_large",
            .exhaust_small => "exhaust_small",
            .exhaust_large => "exhaust_large",
            .unsupported_size_mid => "unsupported_size_mid",
            .unsupported_size_large => "unsupported_size_large",
            .invalid_small_align_free => "invalid_small_align_free",
            .invalid_large_align_free => "invalid_large_align_free",
            .free_small_for_reuse => "free_small_for_reuse",
            .double_free_small => "double_free_small",
            .reuse_small => "reuse_small",
            .free_small_final => "free_small_final",
            .free_large_for_reuse => "free_large_for_reuse",
            .double_free_large => "double_free_large",
            .reuse_large => "reuse_large",
            .free_large_final => "free_large_final",
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
