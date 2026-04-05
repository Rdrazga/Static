//! Model-based test: IndexPool allocate/release sequences with stale handle
//! rejection and generation bumps. Confirms that released indices are recycled
//! with incremented generations and that stale handles are correctly rejected.
const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const testing = std.testing;
const static_collections = @import("static_collections");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;

const Handle = static_collections.handle.Handle;
const IndexPool = static_collections.index_pool.IndexPool;

const Capacity: u32 = 2;
const ScenarioCount: u32 = 4;
const ActionCount: u32 = 14;

const ActionTag = enum(u32) {
    probe_invalid_handle = 1,
    allocate_first = 2,
    probe_first_live = 3,
    allocate_second = 4,
    exhaust_pool = 5,
    release_first = 6,
    probe_stale_first = 7,
    probe_free_first = 8,
    allocate_reuse_first = 9,
    probe_reused_first = 10,
    release_second = 11,
    probe_free_second = 12,
    release_reused_first = 13,
    probe_free_reused_first = 14,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.probe_invalid_handle) },
        .{ .tag = @intFromEnum(ActionTag.allocate_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_first_live) },
        .{ .tag = @intFromEnum(ActionTag.allocate_second) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_pool) },
        .{ .tag = @intFromEnum(ActionTag.release_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_stale_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_first) },
        .{ .tag = @intFromEnum(ActionTag.allocate_reuse_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.release_second) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_second) },
        .{ .tag = @intFromEnum(ActionTag.release_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_reused_first) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.allocate_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_first_live) },
        .{ .tag = @intFromEnum(ActionTag.probe_invalid_handle) },
        .{ .tag = @intFromEnum(ActionTag.allocate_second) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_pool) },
        .{ .tag = @intFromEnum(ActionTag.release_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_stale_first) },
        .{ .tag = @intFromEnum(ActionTag.allocate_reuse_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.release_second) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_second) },
        .{ .tag = @intFromEnum(ActionTag.release_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_reused_first) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.probe_invalid_handle) },
        .{ .tag = @intFromEnum(ActionTag.allocate_first) },
        .{ .tag = @intFromEnum(ActionTag.allocate_second) },
        .{ .tag = @intFromEnum(ActionTag.probe_first_live) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_pool) },
        .{ .tag = @intFromEnum(ActionTag.release_second) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_second) },
        .{ .tag = @intFromEnum(ActionTag.release_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_stale_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_first) },
        .{ .tag = @intFromEnum(ActionTag.allocate_reuse_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.release_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_reused_first) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.probe_invalid_handle) },
        .{ .tag = @intFromEnum(ActionTag.allocate_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_first_live) },
        .{ .tag = @intFromEnum(ActionTag.allocate_second) },
        .{ .tag = @intFromEnum(ActionTag.exhaust_pool) },
        .{ .tag = @intFromEnum(ActionTag.release_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_stale_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_first) },
        .{ .tag = @intFromEnum(ActionTag.allocate_reuse_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.release_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_reused_first) },
        .{ .tag = @intFromEnum(ActionTag.release_second) },
        .{ .tag = @intFromEnum(ActionTag.probe_free_second) },
    },
};

const violations = [_]checker.Violation{
    .{
        .code = "static_collections.index_pool_model",
        .message = "index pool sequence diverged from the bounded reference model",
    },
};

const Context = struct {
    pool: IndexPool = undefined,
    pool_initialized: bool = false,
    first_handle: ?Handle = null,
    second_handle: ?Handle = null,
    stale_first_handle: ?Handle = null,
    stale_second_handle: ?Handle = null,
    reused_handle: ?Handle = null,
    stale_reused_handle: ?Handle = null,
    live_count: u32 = 0,
    expected_free_count: u32 = Capacity,
    saw_invalid_rejection: bool = false,
    saw_live_probe: bool = false,
    saw_exhaustion: bool = false,
    saw_stale_rejection: bool = false,
    saw_generation_bump: bool = false,
    saw_reused_probe: bool = false,
    saw_free_probe_first: bool = false,
    saw_free_probe_second: bool = false,
    saw_free_probe_reused: bool = false,

    fn resetState(self: *@This()) void {
        if (self.pool_initialized) {
            self.pool.deinit();
        }

        self.pool = IndexPool.init(testing.allocator, .{ .slots_max = Capacity, .budget = null }) catch
            |err| panic("resetState: IndexPool.init failed: {s}", .{@errorName(err)});
        self.pool_initialized = true;
        self.first_handle = null;
        self.second_handle = null;
        self.stale_first_handle = null;
        self.stale_second_handle = null;
        self.reused_handle = null;
        self.stale_reused_handle = null;
        self.live_count = 0;
        self.expected_free_count = Capacity;
        self.saw_invalid_rejection = false;
        self.saw_live_probe = false;
        self.saw_exhaustion = false;
        self.saw_stale_rejection = false;
        self.saw_generation_bump = false;
        self.saw_reused_probe = false;
        self.saw_free_probe_first = false;
        self.saw_free_probe_second = false;
        self.saw_free_probe_reused = false;

        assert(self.pool.capacity() == Capacity);
        assert(self.pool.freeCount() == Capacity);
    }

    fn validate(self: *const @This()) checker.CheckResult {
        assert(self.pool_initialized);
        assert(self.pool.capacity() == Capacity);
        assert(self.pool.freeCount() == self.expected_free_count);
        assert(self.live_count + self.expected_free_count == Capacity);

        var tracked_live: u32 = 0;
        tracked_live += @as(u32, @intFromBool(self.first_handle != null));
        tracked_live += @as(u32, @intFromBool(self.second_handle != null));
        tracked_live += @as(u32, @intFromBool(self.reused_handle != null));
        assert(tracked_live == self.live_count);

        if (self.first_handle) |handle| {
            if (!self.liveHandleMatches(handle)) return checker.CheckResult.fail(&violations, null);
        }
        if (self.second_handle) |handle| {
            if (!self.liveHandleMatches(handle)) return checker.CheckResult.fail(&violations, null);
        }
        if (self.reused_handle) |handle| {
            if (!self.liveHandleMatches(handle)) return checker.CheckResult.fail(&violations, null);
        }

        return checker.CheckResult.pass(null);
    }

    fn liveHandleMatches(self: *const @This(), handle: Handle) bool {
        if (!self.pool.contains(handle)) return false;
        const index = self.pool.validate(handle) catch return false;
        if (index != handle.index) return false;
        const from_index = self.pool.handleForIndex(index) orelse return false;
        return from_index.index == handle.index and from_index.generation == handle.generation;
    }

    fn probeInvalidHandle(self: *@This()) checker.CheckResult {
        const invalid = Handle.invalid();
        assert(!invalid.isValid());
        if (self.pool.contains(invalid)) return checker.CheckResult.fail(&violations, null);
        _ = self.pool.validate(invalid) catch |err| switch (err) {
            error.NotFound => {},
            else => return checker.CheckResult.fail(&violations, null),
        };
        self.pool.release(invalid) catch |err| switch (err) {
            error.NotFound => {},
            else => return checker.CheckResult.fail(&violations, null),
        };
        self.saw_invalid_rejection = true;
        return self.validate();
    }

    fn allocateFirst(self: *@This()) checker.CheckResult {
        assert(self.first_handle == null);
        const handle = self.pool.allocate() catch |err| switch (err) {
            error.NoSpaceLeft => return checker.CheckResult.fail(&violations, null),
            else => return checker.CheckResult.fail(&violations, null),
        };
        self.first_handle = handle;
        self.live_count += 1;
        self.expected_free_count -= 1;
        return self.validate();
    }

    fn probeFirstLive(self: *@This()) checker.CheckResult {
        const handle = self.first_handle orelse return checker.CheckResult.fail(&violations, null);
        if (!self.pool.contains(handle)) return checker.CheckResult.fail(&violations, null);
        const index = self.pool.validate(handle) catch return checker.CheckResult.fail(&violations, null);
        if (index != handle.index) return checker.CheckResult.fail(&violations, null);
        const current = self.pool.handleForIndex(handle.index) orelse return checker.CheckResult.fail(&violations, null);
        if (current.index != handle.index or current.generation != handle.generation) return checker.CheckResult.fail(&violations, null);
        self.saw_live_probe = true;
        return self.validate();
    }

    fn allocateSecond(self: *@This()) checker.CheckResult {
        assert(self.first_handle != null);
        assert(self.second_handle == null);
        const handle = self.pool.allocate() catch |err| switch (err) {
            error.NoSpaceLeft => return checker.CheckResult.fail(&violations, null),
            else => return checker.CheckResult.fail(&violations, null),
        };
        self.second_handle = handle;
        self.live_count += 1;
        self.expected_free_count -= 1;
        return self.validate();
    }

    fn exhaustPool(self: *@This()) checker.CheckResult {
        const handle = self.pool.allocate() catch |err| switch (err) {
            error.NoSpaceLeft => {
                self.saw_exhaustion = true;
                return self.validate();
            },
            else => return checker.CheckResult.fail(&violations, null),
        };
        _ = handle;
        return checker.CheckResult.fail(&violations, null);
    }

    fn releaseFirst(self: *@This()) checker.CheckResult {
        const handle = self.first_handle orelse return checker.CheckResult.fail(&violations, null);
        self.pool.release(handle) catch return checker.CheckResult.fail(&violations, null);
        self.stale_first_handle = handle;
        self.first_handle = null;
        self.live_count -= 1;
        self.expected_free_count += 1;
        return self.validate();
    }

    fn probeStaleFirst(self: *@This()) checker.CheckResult {
        const handle = self.stale_first_handle orelse return checker.CheckResult.fail(&violations, null);
        if (self.pool.contains(handle)) return checker.CheckResult.fail(&violations, null);
        _ = self.pool.validate(handle) catch |err| switch (err) {
            error.NotFound => {},
            else => return checker.CheckResult.fail(&violations, null),
        };
        self.pool.release(handle) catch |err| switch (err) {
            error.NotFound => {},
            else => return checker.CheckResult.fail(&violations, null),
        };
        if (self.pool.handleForIndex(handle.index) != null) return checker.CheckResult.fail(&violations, null);
        self.saw_stale_rejection = true;
        return self.validate();
    }

    fn probeFreeFirst(self: *@This()) checker.CheckResult {
        const handle = self.stale_first_handle orelse return checker.CheckResult.fail(&violations, null);
        if (self.pool.handleForIndex(handle.index) != null) return checker.CheckResult.fail(&violations, null);
        self.saw_free_probe_first = true;
        return self.validate();
    }

    fn allocateReuseFirst(self: *@This()) checker.CheckResult {
        const stale = self.stale_first_handle orelse return checker.CheckResult.fail(&violations, null);
        const handle = self.pool.allocate() catch |err| switch (err) {
            error.NoSpaceLeft => return checker.CheckResult.fail(&violations, null),
            else => return checker.CheckResult.fail(&violations, null),
        };
        if (handle.index != stale.index) return checker.CheckResult.fail(&violations, null);
        if (handle.generation == stale.generation) return checker.CheckResult.fail(&violations, null);
        self.reused_handle = handle;
        self.live_count += 1;
        self.expected_free_count -= 1;
        self.saw_generation_bump = true;
        return self.validate();
    }

    fn probeReusedFirst(self: *@This()) checker.CheckResult {
        const handle = self.reused_handle orelse return checker.CheckResult.fail(&violations, null);
        const stale = self.stale_first_handle orelse return checker.CheckResult.fail(&violations, null);
        if (!self.pool.contains(handle)) return checker.CheckResult.fail(&violations, null);
        const index = self.pool.validate(handle) catch return checker.CheckResult.fail(&violations, null);
        if (index != handle.index) return checker.CheckResult.fail(&violations, null);
        const current = self.pool.handleForIndex(handle.index) orelse return checker.CheckResult.fail(&violations, null);
        if (current.index != handle.index or current.generation != handle.generation) return checker.CheckResult.fail(&violations, null);
        if (self.pool.contains(stale)) return checker.CheckResult.fail(&violations, null);
        _ = self.pool.validate(stale) catch |err| switch (err) {
            error.NotFound => {},
            else => return checker.CheckResult.fail(&violations, null),
        };
        self.saw_reused_probe = true;
        return self.validate();
    }

    fn releaseSecond(self: *@This()) checker.CheckResult {
        const handle = self.second_handle orelse return checker.CheckResult.fail(&violations, null);
        self.pool.release(handle) catch return checker.CheckResult.fail(&violations, null);
        self.stale_second_handle = handle;
        self.second_handle = null;
        self.live_count -= 1;
        self.expected_free_count += 1;
        return self.validate();
    }

    fn probeFreeSecond(self: *@This()) checker.CheckResult {
        const handle = self.stale_second_handle orelse return checker.CheckResult.fail(&violations, null);
        if (self.pool.handleForIndex(handle.index) != null) return checker.CheckResult.fail(&violations, null);
        self.saw_free_probe_second = true;
        return self.validate();
    }

    fn releaseReusedFirst(self: *@This()) checker.CheckResult {
        const handle = self.reused_handle orelse return checker.CheckResult.fail(&violations, null);
        self.pool.release(handle) catch return checker.CheckResult.fail(&violations, null);
        self.stale_reused_handle = handle;
        self.reused_handle = null;
        self.live_count -= 1;
        self.expected_free_count += 1;
        return self.validate();
    }

    fn probeFreeReusedFirst(self: *@This()) checker.CheckResult {
        const handle = self.stale_reused_handle orelse return checker.CheckResult.fail(&violations, null);
        if (self.pool.handleForIndex(handle.index) != null) return checker.CheckResult.fail(&violations, null);
        self.saw_free_probe_reused = true;
        return self.validate();
    }

    fn finish(self: *const @This()) checker.CheckResult {
        assert(self.pool_initialized);
        assert(self.first_handle == null);
        assert(self.second_handle == null);
        assert(self.reused_handle == null);
        assert(self.live_count == 0);
        assert(self.expected_free_count == Capacity);
        assert(self.pool.freeCount() == Capacity);
        // Each behavioral coverage flag must have been triggered at least once.
        // Split into individual assertions to identify which flag was missed.
        assert(self.saw_invalid_rejection);
        assert(self.saw_live_probe);
        assert(self.saw_exhaustion);
        assert(self.saw_stale_rejection);
        assert(self.saw_generation_bump);
        assert(self.saw_reused_probe);
        assert(self.saw_free_probe_first);
        assert(self.saw_free_probe_second);
        assert(self.saw_free_probe_reused);
        return checker.CheckResult.pass(null);
    }
};

test "index pool model covers invalidation reuse and exhaustion" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.pool_initialized) context.pool.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_collections",
            .run_name = "index_pool_runtime_sequences",
            .base_seed = .init(0x17b4_2026_0000_7101),
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

test "index pool reuses the most recently released slot first" {
    var pool = try IndexPool.init(testing.allocator, .{ .slots_max = 2, .budget = null });
    defer pool.deinit();

    const first = try pool.allocate();
    const second = try pool.allocate();
    try testing.expectError(error.NoSpaceLeft, pool.allocate());

    try pool.release(second);
    try pool.release(first);
    try testing.expectEqual(@as(u32, 2), pool.freeCount());

    const reuse_first = try pool.allocate();
    try testing.expectEqual(first.index, reuse_first.index);
    try testing.expect(reuse_first.generation != first.generation);

    const reuse_second = try pool.allocate();
    try testing.expectEqual(second.index, reuse_second.index);
    try testing.expect(reuse_second.generation != second.generation);
    try testing.expectEqual(@as(u32, 0), pool.freeCount());
}

fn nextAction(
    _: *anyopaque,
    run_identity: identity.RunIdentity,
    action_index: u32,
    _: seed_mod.Seed,
) error{}!model.RecordedAction {
    assert(run_identity.case_index < ScenarioCount);
    assert(action_index < ActionCount);
    return action_table[run_identity.case_index][action_index];
}

fn step(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    _: u32,
    action: model.RecordedAction,
) error{}!model.ModelStep {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index < ScenarioCount);
    const tag: ActionTag = @enumFromInt(action.tag);
    const check_result = switch (tag) {
        .probe_invalid_handle => context.probeInvalidHandle(),
        .allocate_first => context.allocateFirst(),
        .probe_first_live => context.probeFirstLive(),
        .allocate_second => context.allocateSecond(),
        .exhaust_pool => context.exhaustPool(),
        .release_first => context.releaseFirst(),
        .probe_stale_first => context.probeStaleFirst(),
        .probe_free_first => context.probeFreeFirst(),
        .allocate_reuse_first => context.allocateReuseFirst(),
        .probe_reused_first => context.probeReusedFirst(),
        .release_second => context.releaseSecond(),
        .probe_free_second => context.probeFreeSecond(),
        .release_reused_first => context.releaseReusedFirst(),
        .probe_free_reused_first => context.probeFreeReusedFirst(),
    };
    return .{ .check_result = check_result };
}

fn finish(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index < ScenarioCount);
    return context.finish();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .probe_invalid_handle => "probe_invalid_handle",
            .allocate_first => "allocate_first",
            .probe_first_live => "probe_first_live",
            .allocate_second => "allocate_second",
            .exhaust_pool => "exhaust_pool",
            .release_first => "release_first",
            .probe_stale_first => "probe_stale_first",
            .probe_free_first => "probe_free_first",
            .allocate_reuse_first => "allocate_reuse_first",
            .probe_reused_first => "probe_reused_first",
            .release_second => "release_second",
            .probe_free_second => "probe_free_second",
            .release_reused_first => "release_reused_first",
            .probe_free_reused_first => "probe_free_reused_first",
        },
    };
}

fn reset(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
) error{}!void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index < ScenarioCount);
    context.resetState();
}
