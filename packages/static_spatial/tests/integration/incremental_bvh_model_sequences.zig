const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_spatial = @import("static_spatial");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed = static_testing.testing.seed;

const AABB3 = static_spatial.AABB3;
const BVH = static_spatial.IncrementalBVH(u32);

const ScenarioCount: u32 = 3;
const ActionCount: u32 = 9;

const ActionTag = enum(u32) {
    insert_a = 1,
    insert_b = 2,
    query_origin_a = 3,
    query_broad_ab = 4,
    refit_a_far = 5,
    query_origin_after_refit = 6,
    query_far_a = 7,
    remove_a = 8,
    remove_b = 9,
    reinsert_c = 10,
    query_c = 11,
    remove_c = 12,
    refit_b_to_origin = 13,
    query_origin_ab = 14,
    query_origin_b_only = 15,
    query_empty = 16,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_a) },
        .{ .tag = @intFromEnum(ActionTag.insert_b) },
        .{ .tag = @intFromEnum(ActionTag.query_broad_ab) },
        .{ .tag = @intFromEnum(ActionTag.refit_a_far) },
        .{ .tag = @intFromEnum(ActionTag.query_origin_after_refit) },
        .{ .tag = @intFromEnum(ActionTag.query_far_a) },
        .{ .tag = @intFromEnum(ActionTag.remove_b) },
        .{ .tag = @intFromEnum(ActionTag.remove_a) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_a) },
        .{ .tag = @intFromEnum(ActionTag.query_origin_a) },
        .{ .tag = @intFromEnum(ActionTag.remove_a) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
        .{ .tag = @intFromEnum(ActionTag.reinsert_c) },
        .{ .tag = @intFromEnum(ActionTag.query_c) },
        .{ .tag = @intFromEnum(ActionTag.remove_c) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_a) },
        .{ .tag = @intFromEnum(ActionTag.insert_b) },
        .{ .tag = @intFromEnum(ActionTag.refit_b_to_origin) },
        .{ .tag = @intFromEnum(ActionTag.query_origin_ab) },
        .{ .tag = @intFromEnum(ActionTag.remove_a) },
        .{ .tag = @intFromEnum(ActionTag.query_origin_b_only) },
        .{ .tag = @intFromEnum(ActionTag.remove_b) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_spatial.incremental_bvh_model",
        .message = "incremental BVH mutation or query behavior diverged from the bounded reference model",
    },
};

const origin_aabb = AABB3.init(-1, -1, -1, 2, 2, 2);
const broad_aabb = AABB3.init(-1, -1, -1, 12, 12, 12);
const far_aabb = AABB3.init(49, 49, 49, 52, 52, 52);
const c_aabb = AABB3.init(7, 7, 7, 10, 10, 10);

const LeafSlot = enum(u2) {
    a = 0,
    b = 1,
    c = 2,
};

const LeafState = struct {
    live: bool = false,
    handle: BVH.NodeIndex = BVH.INVALID,
    value: u32 = 0,
    bounds: AABB3 = AABB3.init(0, 0, 0, 0, 0, 0),
};

const Context = struct {
    bvh: BVH = undefined,
    initialized: bool = false,
    leaves: [3]LeafState = undefined,
    query_buffer: [4]u32 = undefined,
    last_removed_handle: ?BVH.NodeIndex = null,
    saw_refit_far: bool = false,
    saw_reuse_after_empty: bool = false,
    saw_overlap_query: bool = false,

    fn resetState(self: *@This()) void {
        if (self.initialized) self.bvh.deinit();
        self.bvh = BVH.init(testing.allocator);
        self.initialized = true;
        self.leaves = [_]LeafState{.{}, .{}, .{}};
        self.query_buffer = [_]u32{0} ** 4;
        self.last_removed_handle = null;
        self.saw_refit_far = false;
        self.saw_reuse_after_empty = false;
        self.saw_overlap_query = false;
        assert(self.bvh.count() == 0);
    }

    fn validateCount(self: *const @This()) checker.CheckResult {
        var expected_count: u32 = 0;
        for (self.leaves) |leaf_state| {
            if (leaf_state.live) expected_count += 1;
        }
        assert(self.bvh.count() == expected_count);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, expected_count) << 64) |
                (@as(u128, @intFromBool(self.saw_refit_far)) << 2) |
                (@as(u128, @intFromBool(self.saw_reuse_after_empty)) << 1) |
                @as(u128, @intFromBool(self.saw_overlap_query)),
        ));
    }

    fn leafState(self: *@This(), slot: LeafSlot) *LeafState {
        return &self.leaves[@intFromEnum(slot)];
    }

    fn insertLeaf(self: *@This(), slot: LeafSlot, bounds: AABB3, value: u32) checker.CheckResult {
        const leaf_state = self.leafState(slot);
        assert(!leaf_state.live);
        const handle = self.bvh.insert(bounds, value) catch return checker.CheckResult.fail(&violation, null);
        leaf_state.* = .{
            .live = true,
            .handle = handle,
            .value = value,
            .bounds = bounds,
        };
        return self.validateCount();
    }

    fn removeLeaf(self: *@This(), slot: LeafSlot) checker.CheckResult {
        const leaf_state = self.leafState(slot);
        if (!leaf_state.live) return checker.CheckResult.fail(&violation, null);
        self.last_removed_handle = leaf_state.handle;
        self.bvh.remove(leaf_state.handle);
        leaf_state.live = false;
        leaf_state.handle = BVH.INVALID;
        return self.validateCount();
    }

    fn refitLeaf(self: *@This(), slot: LeafSlot, bounds: AABB3) checker.CheckResult {
        const leaf_state = self.leafState(slot);
        if (!leaf_state.live) return checker.CheckResult.fail(&violation, null);
        self.bvh.refit(leaf_state.handle, bounds);
        leaf_state.bounds = bounds;
        return self.validateCount();
    }

    fn expectQuery(self: *@This(), aabb: AABB3, expected: []const u32) checker.CheckResult {
        const hit_count = self.bvh.queryAABB(aabb, &self.query_buffer);
        assert(expected.len <= self.query_buffer.len);
        assert(hit_count >= @as(u32, @intCast(expected.len)));
        const hits = self.query_buffer[0..expected.len];
        if (hits.len != expected.len) return checker.CheckResult.fail(&violation, null);
        for (expected) |needle| {
            if (!containsValue(hits, needle)) return checker.CheckResult.fail(&violation, null);
        }
        for (hits) |value| {
            if (!containsValue(expected, value)) return checker.CheckResult.fail(&violation, null);
        }
        return self.validateCount();
    }

    fn finish(self: *const @This(), case_index: usize) checker.CheckResult {
        const count_check = self.validateCount();
        if (!count_check.passed) return count_check;
        assert(self.bvh.count() == 0);
        switch (case_index) {
            0 => assert(self.saw_refit_far),
            1 => assert(self.saw_reuse_after_empty),
            2 => assert(self.saw_overlap_query),
            else => unreachable,
        }
        return checker.CheckResult.pass(null);
    }
};

test "incremental BVH runtime sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.initialized) context.bvh.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_spatial",
            .run_name = "incremental_bvh_runtime_sequences",
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
        .insert_a => context.insertLeaf(.a, AABB3.init(0, 0, 0, 1, 1, 1), 10),
        .insert_b => context.insertLeaf(.b, AABB3.init(5, 5, 5, 6, 6, 6), 20),
        .query_origin_a => context.expectQuery(origin_aabb, &.{10}),
        .query_broad_ab => context.expectQuery(broad_aabb, &.{ 10, 20 }),
        .refit_a_far => blk: {
            context.saw_refit_far = true;
            break :blk context.refitLeaf(.a, AABB3.init(50, 50, 50, 51, 51, 51));
        },
        .query_origin_after_refit => context.expectQuery(origin_aabb, &.{}),
        .query_far_a => context.expectQuery(far_aabb, &.{10}),
        .remove_a => context.removeLeaf(.a),
        .remove_b => context.removeLeaf(.b),
        .reinsert_c => blk: {
            const result = context.insertLeaf(.c, AABB3.init(8, 8, 8, 9, 9, 9), 88);
            if (!result.passed) break :blk result;
            context.saw_reuse_after_empty = true;
            break :blk result;
        },
        .query_c => context.expectQuery(c_aabb, &.{88}),
        .remove_c => context.removeLeaf(.c),
        .refit_b_to_origin => context.refitLeaf(.b, AABB3.init(0.5, 0.5, 0.5, 1.5, 1.5, 1.5)),
        .query_origin_ab => blk: {
            context.saw_overlap_query = true;
            break :blk context.expectQuery(origin_aabb, &.{ 10, 20 });
        },
        .query_origin_b_only => context.expectQuery(origin_aabb, &.{20}),
        .query_empty => context.expectQuery(broad_aabb, &.{}),
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
            .insert_a => "insert_a",
            .insert_b => "insert_b",
            .query_origin_a => "query_origin_a",
            .query_broad_ab => "query_broad_ab",
            .refit_a_far => "refit_a_far",
            .query_origin_after_refit => "query_origin_after_refit",
            .query_far_a => "query_far_a",
            .remove_a => "remove_a",
            .remove_b => "remove_b",
            .reinsert_c => "reinsert_c",
            .query_c => "query_c",
            .remove_c => "remove_c",
            .refit_b_to_origin => "refit_b_to_origin",
            .query_origin_ab => "query_origin_ab",
            .query_origin_b_only => "query_origin_b_only",
            .query_empty => "query_empty",
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

fn containsValue(values: []const u32, needle: u32) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}
