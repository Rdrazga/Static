const std = @import("std");
const static_memory = @import("static_memory");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const ModelError = static_memory.pool.PoolError;
const PoolCapacity: u32 = 4;
const PoolBlockSize: u32 = 16;
const PoolBlockAlign: u32 = 8;
const ActionCount: u32 = 11;
const ScenarioCount: u32 = 4;

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = 0, .value = 0 },
        .{ .tag = 1, .value = 1 },
        .{ .tag = 2, .value = 2 },
        .{ .tag = 3, .value = 3 },
        .{ .tag = 4, .value = 0 },
        .{ .tag = 5, .value = 1 },
        .{ .tag = 6, .value = 1 },
        .{ .tag = 7, .value = 0 },
        .{ .tag = 8, .value = 1 },
        .{ .tag = 9, .value = 0 },
        .{ .tag = 10, .value = 0 },
    },
    .{
        .{ .tag = 1, .value = 1 },
        .{ .tag = 0, .value = 0 },
        .{ .tag = 3, .value = 3 },
        .{ .tag = 2, .value = 2 },
        .{ .tag = 4, .value = 0 },
        .{ .tag = 5, .value = 1 },
        .{ .tag = 6, .value = 1 },
        .{ .tag = 7, .value = 0 },
        .{ .tag = 8, .value = 1 },
        .{ .tag = 9, .value = 0 },
        .{ .tag = 10, .value = 0 },
    },
    .{
        .{ .tag = 2, .value = 2 },
        .{ .tag = 1, .value = 1 },
        .{ .tag = 0, .value = 0 },
        .{ .tag = 3, .value = 3 },
        .{ .tag = 4, .value = 0 },
        .{ .tag = 5, .value = 1 },
        .{ .tag = 6, .value = 1 },
        .{ .tag = 7, .value = 0 },
        .{ .tag = 8, .value = 1 },
        .{ .tag = 9, .value = 0 },
        .{ .tag = 10, .value = 0 },
    },
    .{
        .{ .tag = 3, .value = 3 },
        .{ .tag = 1, .value = 1 },
        .{ .tag = 2, .value = 2 },
        .{ .tag = 0, .value = 0 },
        .{ .tag = 4, .value = 0 },
        .{ .tag = 5, .value = 1 },
        .{ .tag = 6, .value = 1 },
        .{ .tag = 7, .value = 0 },
        .{ .tag = 8, .value = 1 },
        .{ .tag = 9, .value = 0 },
        .{ .tag = 10, .value = 0 },
    },
};

const Context = struct {
    pool: static_memory.pool.Pool,
    allocations: [PoolCapacity]?[]u8 = .{null} ** PoolCapacity,
    first_allocation: ?[]u8 = null,
    stale_free_block: ?[]u8 = null,
    freed_slot1_ptr: usize = 0,
    saw_exhaustion: bool = false,
    saw_reuse: bool = false,
    saw_reset: bool = false,
    saw_stale_free_rejection: bool = false,
    expected_live_count: u32 = 0,
    expected_high_water: u32 = 0,
    expected_overflow_count: u32 = 0,

    fn reset(context_ptr: *anyopaque, _: identity.RunIdentity) ModelError!void {
        const self: *@This() = @ptrCast(@alignCast(context_ptr));
        self.pool.deinit();
        try static_memory.pool.Pool.init(
            &self.pool,
            std.testing.allocator,
            PoolBlockSize,
            PoolBlockAlign,
            PoolCapacity,
        );
        self.allocations = .{null} ** PoolCapacity;
        self.first_allocation = null;
        self.stale_free_block = null;
        self.freed_slot1_ptr = 0;
        self.saw_exhaustion = false;
        self.saw_reuse = false;
        self.saw_reset = false;
        self.saw_stale_free_rejection = false;
        self.expected_live_count = 0;
        self.expected_high_water = 0;
        self.expected_overflow_count = 0;

        std.debug.assert(self.pool.available() == PoolCapacity);
        std.debug.assert(self.pool.used() == 0);
    }

    fn nextAction(
        _: *anyopaque,
        run_identity: identity.RunIdentity,
        action_index: u32,
        _: seed.Seed,
    ) ModelError!model.RecordedAction {
        std.debug.assert(run_identity.case_index < ScenarioCount);
        std.debug.assert(action_index < ActionCount);
        return action_table[run_identity.case_index][action_index];
    }

    fn step(
        context_ptr: *anyopaque,
        _: identity.RunIdentity,
        _: u32,
        action: model.RecordedAction,
    ) ModelError!model.ModelStep {
        const self: *@This() = @ptrCast(@alignCast(context_ptr));
        switch (action.tag) {
            0 => self.allocSlot(0),
            1 => self.allocSlot(1),
            2 => self.allocSlot(2),
            3 => self.allocSlot(3),
            4 => self.expectExhaustion(),
            5 => self.freeSlot1(),
            6 => self.allocReuseSlot1(),
            7 => self.resetPool(),
            8 => self.freeStaleSlot1(),
            9 => self.allocAfterReset(),
            10 => self.freeAfterReset(),
            else => std.debug.panic("unexpected pool model action", .{}),
        }

        self.expectState();

        return .{
            .check_result = checker.CheckResult.pass(null),
        };
    }

    fn finish(context_ptr: *anyopaque, _: identity.RunIdentity, _: u32) ModelError!checker.CheckResult {
        const self: *@This() = @ptrCast(@alignCast(context_ptr));
        std.debug.assert(self.saw_exhaustion);
        std.debug.assert(self.saw_reuse);
        std.debug.assert(self.saw_reset);
        std.debug.assert(self.saw_stale_free_rejection);

        inline for (self.allocations) |allocation| {
            std.debug.assert(allocation == null);
        }
        std.debug.assert(self.pool.available() == PoolCapacity);
        std.debug.assert(self.pool.used() == 0);
        std.debug.assert(self.pool.highWaterUsed() == PoolCapacity);
        std.debug.assert(self.pool.overflowCount() == 1);

        const report = self.pool.report();
        std.debug.assert(report.unit == .blocks);
        std.debug.assert(report.used == 0);
        std.debug.assert(report.high_water == @as(u64, PoolCapacity));
        std.debug.assert(report.capacity == @as(u64, PoolCapacity));
        std.debug.assert(report.overflow_count == 1);

        return checker.CheckResult.pass(null);
    }

    fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
        return .{
            .label = switch (action.tag) {
                0 => "alloc_slot_0",
                1 => "alloc_slot_1",
                2 => "alloc_slot_2",
                3 => "alloc_slot_3",
                4 => "exhaust_pool",
                5 => "free_slot_1",
                6 => "alloc_reuse_slot_1",
                7 => "reset_pool",
                8 => "free_stale_slot_1",
                9 => "alloc_after_reset",
                10 => "free_after_reset",
                else => "unknown",
            },
        };
    }

    fn expectState(self: *const @This()) void {
        std.debug.assert(self.pool.available() == PoolCapacity - self.expected_live_count);
        std.debug.assert(self.pool.used() == self.expected_live_count);
        std.debug.assert(self.pool.highWaterUsed() == self.expected_high_water);
        std.debug.assert(self.pool.overflowCount() == self.expected_overflow_count);
    }

    fn allocSlot(self: *@This(), slot: u32) void {
        std.debug.assert(slot < PoolCapacity);
        const slot_index: usize = @intCast(slot);
        std.debug.assert(self.allocations[slot_index] == null);

        const block = self.pool.allocBlock() catch {
            std.debug.panic("unexpected pool allocation failure", .{});
        };
        std.debug.assert(block.len == PoolBlockSize);
        self.allocations[slot_index] = block;
        self.expected_live_count += 1;
        if (self.expected_live_count > self.expected_high_water) {
            self.expected_high_water = self.expected_live_count;
        }
        if (self.first_allocation == null) {
            std.debug.assert(self.first_allocation == null);
            self.first_allocation = block;
        }
    }

    fn expectExhaustion(self: *@This()) void {
        _ = self.pool.allocBlock() catch |err| {
            std.debug.assert(err == error.NoSpaceLeft);
            self.saw_exhaustion = true;
            self.expected_overflow_count = 1;
            return;
        };
        std.debug.panic("expected pool exhaustion", .{});
    }

    fn freeSlot1(self: *@This()) void {
        const block = self.allocations[1] orelse {
            std.debug.panic("slot 1 was not allocated", .{});
        };
        self.freed_slot1_ptr = @intFromPtr(block.ptr);
        self.pool.freeBlock(block) catch {
            std.debug.panic("unexpected pool release failure", .{});
        };
        self.allocations[1] = null;
        self.expected_live_count -= 1;
    }

    fn allocReuseSlot1(self: *@This()) void {
        const block = self.pool.allocBlock() catch {
            std.debug.panic("unexpected pool allocation failure", .{});
        };
        std.debug.assert(self.freed_slot1_ptr != 0);
        std.debug.assert(@intFromPtr(block.ptr) == self.freed_slot1_ptr);
        self.allocations[1] = block;
        self.stale_free_block = block;
        self.saw_reuse = true;
        self.expected_live_count += 1;
    }

    fn resetPool(self: *@This()) void {
        std.debug.assert(self.allocations[1] != null);
        self.stale_free_block = self.allocations[1];
        self.pool.reset();
        self.allocations = .{null} ** PoolCapacity;
        self.saw_reset = true;
        self.expected_live_count = 0;
    }

    fn freeStaleSlot1(self: *@This()) void {
        const block = self.stale_free_block orelse {
            std.debug.panic("stale block was not captured before reset", .{});
        };
        self.pool.freeBlock(block) catch |err| {
            std.debug.assert(err == error.InvalidBlock);
            self.saw_stale_free_rejection = true;
            return;
        };
        std.debug.panic("expected stale block release to fail", .{});
    }

    fn allocAfterReset(self: *@This()) void {
        const block = self.pool.allocBlock() catch {
            std.debug.panic("unexpected pool allocation failure", .{});
        };
        const first_allocation = self.first_allocation orelse {
            std.debug.panic("first allocation was not captured", .{});
        };
        std.debug.assert(@intFromPtr(block.ptr) == @intFromPtr(first_allocation.ptr));
        std.debug.assert(self.allocations[0] == null);
        self.allocations[0] = block;
        self.expected_live_count += 1;
    }

    fn freeAfterReset(self: *@This()) void {
        const block = self.allocations[0] orelse {
            std.debug.panic("slot 0 was not allocated after reset", .{});
        };
        self.pool.freeBlock(block) catch {
            std.debug.panic("unexpected pool release failure", .{});
        };
        self.allocations[0] = null;
        self.expected_live_count -= 1;
    }
};

test "pool model covers allocation reuse reset and exhaustion" {
    var context: Context = .{
        .pool = undefined,
    };
    try static_memory.pool.Pool.init(
        &context.pool,
        std.testing.allocator,
        PoolBlockSize,
        PoolBlockAlign,
        PoolCapacity,
    );
    defer context.pool.deinit();

    const Target = model.ModelTarget(ModelError);
    const Runner = model.ModelRunner(ModelError);
    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(ModelError, Runner{
        .config = .{
            .package_name = "static_memory",
            .run_name = "pool_model_adoption",
            .base_seed = .init(0x17b4_2026_0000_4101),
            .build_mode = .debug,
            .case_count_max = ScenarioCount,
            .action_count_max = ActionCount,
        },
        .target = Target{
            .context = &context,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    try std.testing.expect(summary.failed_case == null);
    try std.testing.expectEqual(@as(u32, ScenarioCount), summary.executed_case_count);
    try std.testing.expectEqual(@as(u32, 4), context.pool.available());
    try std.testing.expectEqual(@as(u32, 0), context.pool.used());
}
