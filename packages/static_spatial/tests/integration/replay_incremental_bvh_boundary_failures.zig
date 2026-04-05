const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_spatial = @import("static_spatial");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const failure_bundle = static_testing.testing.failure_bundle;
const model = static_testing.testing.model;
const identity = static_testing.testing.identity;
const seed = static_testing.testing.seed;

const AABB3 = static_spatial.AABB3;
const BVH = static_spatial.IncrementalBVH(u32);

const ScenarioCount: u32 = 7;
const ActionCount: u32 = 6;
const RetainedFailureActionCount: u32 = 3;

const ActionTag = enum(u32) {
    insert_point_a = 1,
    insert_face_b = 2,
    insert_edge_b = 3,
    insert_corner_b = 4,
    insert_outer = 5,
    insert_inner = 6,
    insert_left = 7,
    insert_right_gap = 8,
    insert_mover = 9,
    insert_single = 10,
    query_touching = 11,
    query_point_only = 12,
    query_outer = 13,
    query_inner = 14,
    query_left_only = 15,
    query_right_only = 16,
    query_left_after_right_removed = 17,
    query_origin = 18,
    query_origin_after_refit = 19,
    query_far = 20,
    query_hit = 21,
    query_empty = 22,
    remove_b = 23,
    remove_inner = 24,
    remove_right = 25,
    remove_single = 26,
    refit_mover_far = 27,
};

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_point_a) },
        .{ .tag = @intFromEnum(ActionTag.insert_face_b) },
        .{ .tag = @intFromEnum(ActionTag.query_touching) },
        .{ .tag = @intFromEnum(ActionTag.remove_b) },
        .{ .tag = @intFromEnum(ActionTag.query_point_only) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_point_a) },
        .{ .tag = @intFromEnum(ActionTag.insert_edge_b) },
        .{ .tag = @intFromEnum(ActionTag.query_touching) },
        .{ .tag = @intFromEnum(ActionTag.remove_b) },
        .{ .tag = @intFromEnum(ActionTag.query_point_only) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_point_a) },
        .{ .tag = @intFromEnum(ActionTag.insert_corner_b) },
        .{ .tag = @intFromEnum(ActionTag.query_touching) },
        .{ .tag = @intFromEnum(ActionTag.remove_b) },
        .{ .tag = @intFromEnum(ActionTag.query_point_only) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_outer) },
        .{ .tag = @intFromEnum(ActionTag.insert_inner) },
        .{ .tag = @intFromEnum(ActionTag.query_outer) },
        .{ .tag = @intFromEnum(ActionTag.query_inner) },
        .{ .tag = @intFromEnum(ActionTag.remove_inner) },
        .{ .tag = @intFromEnum(ActionTag.query_outer) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_left) },
        .{ .tag = @intFromEnum(ActionTag.insert_right_gap) },
        .{ .tag = @intFromEnum(ActionTag.query_left_only) },
        .{ .tag = @intFromEnum(ActionTag.query_right_only) },
        .{ .tag = @intFromEnum(ActionTag.remove_right) },
        .{ .tag = @intFromEnum(ActionTag.query_left_after_right_removed) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_mover) },
        .{ .tag = @intFromEnum(ActionTag.query_origin) },
        .{ .tag = @intFromEnum(ActionTag.refit_mover_far) },
        .{ .tag = @intFromEnum(ActionTag.query_origin_after_refit) },
        .{ .tag = @intFromEnum(ActionTag.query_far) },
        .{ .tag = @intFromEnum(ActionTag.query_far) },
    },
    .{
        .{ .tag = @intFromEnum(ActionTag.insert_single) },
        .{ .tag = @intFromEnum(ActionTag.query_hit) },
        .{ .tag = @intFromEnum(ActionTag.remove_single) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
        .{ .tag = @intFromEnum(ActionTag.query_empty) },
    },
};

const violation = [_]checker.Violation{
    .{
        .code = "static_spatial.incremental_bvh_boundary",
        .message = "incremental BVH query results diverged from the inclusive AABB3 reference scan",
    },
};

const retained_failure_violation = [_]checker.Violation{
    .{
        .code = "static_spatial.incremental_bvh_boundary_retained",
        .message = "incremental BVH boundary-query failures stopped retaining replayable artifacts",
    },
};

const point_aabb = AABB3.init(0, 0, 0, 0, 0, 0);
const face_touch_aabb = AABB3.init(1, 0, 0, 2, 1, 1);
const edge_touch_aabb = AABB3.init(1, 1, 0, 2, 2, 1);
const corner_touch_aabb = AABB3.init(1, 1, 1, 2, 2, 2);
const outer_aabb = AABB3.init(-5, -5, -5, 5, 5, 5);
const inner_aabb = AABB3.init(-1, -1, -1, 1, 1, 1);
const left_aabb = AABB3.init(0, 0, 0, 1, 1, 1);
const right_gap_aabb = AABB3.init(1.0001, 0, 0, 2.0001, 1, 1);
const mover_near_aabb = AABB3.init(-1, -1, -1, 1, 1, 1);
const mover_far_aabb = AABB3.init(100, 100, 100, 101, 101, 101);
const empty_aabb = AABB3.init(200, 200, 200, 201, 201, 201);

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
    saw_far_refit: bool = false,
    saw_removed_clear: bool = false,

    fn resetState(self: *@This()) void {
        if (self.initialized) self.bvh.deinit();
        self.bvh = BVH.init(testing.allocator);
        self.initialized = true;
        self.leaves = [_]LeafState{ .{}, .{}, .{} };
        self.query_buffer = [_]u32{0} ** 4;
        self.saw_far_refit = false;
        self.saw_removed_clear = false;
        assert(self.bvh.count() == 0);
    }

    fn validateCount(self: *const @This()) checker.CheckResult {
        var expected_count: u32 = 0;
        for (self.leaves) |leaf_state| {
            if (leaf_state.live) expected_count += 1;
        }
        assert(self.bvh.count() == expected_count);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(@as(u128, expected_count)));
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

    fn expectQuery(self: *@This(), aabb: AABB3) checker.CheckResult {
        const hit_count = self.bvh.queryAABB(aabb, &self.query_buffer);

        var expected_values: [3]u32 = undefined;
        var expected_count: usize = 0;
        for (self.leaves) |leaf_state| {
            if (leaf_state.live and leaf_state.bounds.intersects(aabb)) {
                expected_values[expected_count] = leaf_state.value;
                expected_count += 1;
            }
        }

        assert(expected_count <= self.query_buffer.len);
        assert(hit_count >= @as(u32, @intCast(expected_count)));
        const actual = self.query_buffer[0..expected_count];

        if (actual.len != expected_count) return checker.CheckResult.fail(&violation, null);
        for (expected_values[0..expected_count]) |needle| {
            if (!containsValue(actual, needle)) return checker.CheckResult.fail(&violation, null);
        }
        for (actual) |value| {
            if (!containsValue(expected_values[0..expected_count], value)) return checker.CheckResult.fail(&violation, null);
        }
        return self.validateCount();
    }

    fn finish(self: *const @This(), case_index: usize) checker.CheckResult {
        const count_check = self.validateCount();
        if (!count_check.passed) return count_check;

        switch (case_index) {
            0, 1, 2, 3, 4, 5 => assert(self.bvh.count() == 1),
            6 => assert(self.bvh.count() == 0),
            else => unreachable,
        }
        if (case_index == 5) assert(self.saw_far_refit);
        if (case_index == 6) assert(self.saw_removed_clear);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(@as(u128, case_index)));
    }
};

test "incremental BVH boundary failures stay replayable through shared model and failure artifacts" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.initialized) context.bvh.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [512]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    var action_bytes_buffer: [256]u8 = undefined;
    var action_document_buffer: [1024]u8 = undefined;
    var action_document_entries: [ActionCount]model.RecordedActionDocumentEntry = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_spatial",
            .run_name = "incremental_bvh_boundary_failures",
            .base_seed = .init(0x17b4_2026_0b0b_9501),
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
        .persistence = .{
            .failure_bundle = .{
                .io = threaded_io.io(),
                .dir = tmp_dir.dir,
                .entry_name_buffer = &entry_name_buffer,
                .artifact_buffer = &artifact_buffer,
                .manifest_buffer = &manifest_buffer,
                .trace_buffer = &trace_buffer,
                .violations_buffer = &violations_buffer,
            },
            .artifact_selection = .{ .action_document_artifact = .zon },
            .action_bytes_buffer = &action_bytes_buffer,
            .action_document_buffer = &action_document_buffer,
            .action_document_entries = &action_document_entries,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    try testing.expectEqual(ScenarioCount, summary.executed_case_count);
    try testing.expect(summary.failed_case == null);
}

test "incremental BVH boundary failures retain replay artifacts and actions.zon" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.initialized) context.bvh.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var action_storage: [RetainedFailureActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [RetainedFailureActionCount]model.RecordedAction = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [512]u8 = undefined;
    var manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var action_bytes_buffer: [256]u8 = undefined;
    var action_document_buffer: [1024]u8 = undefined;
    var action_document_entries: [RetainedFailureActionCount]model.RecordedActionDocumentEntry = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_spatial",
            .run_name = "incremental_bvh_boundary_retained_failure",
            .base_seed = .init(0x17b4_2026_0b0b_9502),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = RetainedFailureActionCount,
        },
        .target = Target{
            .context = &context,
            .reset_fn = reset,
            .next_action_fn = nextRetainedFailureAction,
            .step_fn = stepRetainedFailure,
            .finish_fn = finishRetainedFailure,
            .describe_action_fn = describe,
        },
        .persistence = .{
            .failure_bundle = .{
                .io = io,
                .dir = tmp_dir.dir,
                .entry_name_buffer = &entry_name_buffer,
                .artifact_buffer = &artifact_buffer,
                .manifest_buffer = &manifest_buffer,
                .trace_buffer = &trace_buffer,
                .violations_buffer = &violations_buffer,
            },
            .artifact_selection = .{ .action_document_artifact = .zon },
            .action_bytes_buffer = &action_bytes_buffer,
            .action_document_buffer = &action_document_buffer,
            .action_document_entries = &action_document_entries,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    try testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try testing.expect(failed_case.persisted_entry_name != null);

    var read_artifact_buffer: [512]u8 = undefined;
    var read_manifest_source: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_source: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const bundle = try failure_bundle.readFailureBundle(io, tmp_dir.dir, failed_case.persisted_entry_name.?, .{
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });
    try testing.expectEqualStrings("static_spatial", bundle.manifest_document.package_name);
    try testing.expectEqualStrings("incremental_bvh_boundary_retained_failure", bundle.manifest_document.run_name);
    try testing.expectEqualStrings(
        retained_failure_violation[0].code,
        bundle.violations_document.violations[0].code,
    );

    var read_action_bytes_buffer: [256]u8 = undefined;
    var read_action_storage: [RetainedFailureActionCount]model.RecordedAction = undefined;
    var read_action_document_source_buffer: [2048]u8 = undefined;
    var read_action_document_parse_buffer: [4096]u8 = undefined;
    const recorded_actions = try model.readRecordedActions(io, tmp_dir.dir, failed_case.persisted_entry_name.?, .{
        .actions_buffer = &read_action_storage,
        .action_bytes_buffer = &read_action_bytes_buffer,
        .action_document_source_buffer = &read_action_document_source_buffer,
        .action_document_parse_buffer = &read_action_document_parse_buffer,
    });
    try testing.expect(recorded_actions.action_document != null);
    try testing.expectEqual(failed_case.recorded_actions.len, recorded_actions.actions.len);
    try testing.expectEqualStrings(
        "query_touching",
        recorded_actions.action_document.?.actions[recorded_actions.actions.len - 1].label,
    );

    const replay = try model.replayRecordedActions(error{}, Target{
        .context = &context,
        .reset_fn = reset,
        .next_action_fn = nextRetainedFailureAction,
        .step_fn = stepRetainedFailure,
        .finish_fn = finishRetainedFailure,
        .describe_action_fn = describe,
    }, failed_case.run_identity, recorded_actions.actions);
    try testing.expect(!replay.check_result.passed);
    try testing.expectEqual(failed_case.failing_action_index, replay.failing_action_index);
    try testing.expectEqual(failed_case.trace_metadata.event_count, replay.trace_metadata.event_count);
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
    run_identity: identity.RunIdentity,
    _: u32,
    action: model.RecordedAction,
) error{}!model.ModelStep {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index < ScenarioCount);
    const tag: ActionTag = @enumFromInt(action.tag);
    const result = switch (tag) {
        .insert_point_a => context.insertLeaf(.a, point_aabb, 10),
        .insert_face_b => context.insertLeaf(.b, face_touch_aabb, 20),
        .insert_edge_b => context.insertLeaf(.b, edge_touch_aabb, 21),
        .insert_corner_b => context.insertLeaf(.b, corner_touch_aabb, 22),
        .insert_outer => context.insertLeaf(.a, outer_aabb, 30),
        .insert_inner => context.insertLeaf(.b, inner_aabb, 31),
        .insert_left => context.insertLeaf(.a, left_aabb, 40),
        .insert_right_gap => context.insertLeaf(.b, right_gap_aabb, 41),
        .insert_mover => context.insertLeaf(.a, mover_near_aabb, 50),
        .insert_single => context.insertLeaf(.a, point_aabb, 60),
        .query_touching => context.expectQuery(AABB3.init(0, 0, 0, 1, 1, 1)),
        .query_point_only => context.expectQuery(point_aabb),
        .query_outer => context.expectQuery(outer_aabb),
        .query_inner => context.expectQuery(inner_aabb),
        .query_left_only => context.expectQuery(left_aabb),
        .query_right_only => context.expectQuery(right_gap_aabb),
        .query_left_after_right_removed => context.expectQuery(left_aabb),
        .query_origin => context.expectQuery(AABB3.init(-1, -1, -1, 1, 1, 1)),
        .query_origin_after_refit => context.expectQuery(empty_aabb),
        .query_far => context.expectQuery(mover_far_aabb),
        .query_hit => context.expectQuery(point_aabb),
        .query_empty => context.expectQuery(empty_aabb),
        .remove_b => context.removeLeaf(.b),
        .remove_inner => context.removeLeaf(.b),
        .remove_right => context.removeLeaf(.b),
        .remove_single => blk: {
            context.saw_removed_clear = true;
            break :blk context.removeLeaf(.a);
        },
        .refit_mover_far => blk: {
            context.saw_far_refit = true;
            break :blk context.refitLeaf(.a, mover_far_aabb);
        },
    };
    return .{ .check_result = result };
}

fn nextRetainedFailureAction(
    _: *anyopaque,
    run_identity: identity.RunIdentity,
    action_index: u32,
    _: seed.Seed,
) error{}!model.RecordedAction {
    assert(run_identity.case_index == 0);
    assert(action_index < RetainedFailureActionCount);
    return switch (action_index) {
        0 => .{ .tag = @intFromEnum(ActionTag.insert_point_a) },
        1 => .{ .tag = @intFromEnum(ActionTag.insert_face_b) },
        2 => .{ .tag = @intFromEnum(ActionTag.query_touching) },
        else => unreachable,
    };
}

fn stepRetainedFailure(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    action_index: u32,
    action: model.RecordedAction,
) error{}!model.ModelStep {
    assert(run_identity.case_index == 0);
    assert(action_index < RetainedFailureActionCount);

    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const tag: ActionTag = @enumFromInt(action.tag);
    const result = switch (tag) {
        .insert_point_a => context.insertLeaf(.a, point_aabb, 10),
        .insert_face_b => context.insertLeaf(.b, face_touch_aabb, 20),
        .query_touching => blk: {
            const query_result = context.expectQuery(AABB3.init(0, 0, 0, 1, 1, 1));
            if (!query_result.passed) break :blk query_result;

            const a_live = context.leafState(.a).live;
            const b_live = context.leafState(.b).live;
            if (a_live and b_live) break :blk checker.CheckResult.fail(&retained_failure_violation, null);
            break :blk query_result;
        },
        else => unreachable,
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

fn finishRetainedFailure(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    executed_action_count: u32,
) error{}!checker.CheckResult {
    assert(run_identity.case_index == 0);
    assert(executed_action_count <= RetainedFailureActionCount);
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return context.validateCount();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .insert_point_a => "insert_point_a",
            .insert_face_b => "insert_face_b",
            .insert_edge_b => "insert_edge_b",
            .insert_corner_b => "insert_corner_b",
            .insert_outer => "insert_outer",
            .insert_inner => "insert_inner",
            .insert_left => "insert_left",
            .insert_right_gap => "insert_right_gap",
            .insert_mover => "insert_mover",
            .insert_single => "insert_single",
            .query_touching => "query_touching",
            .query_point_only => "query_point_only",
            .query_outer => "query_outer",
            .query_inner => "query_inner",
            .query_left_only => "query_left_only",
            .query_right_only => "query_right_only",
            .query_left_after_right_removed => "query_left_after_right_removed",
            .query_origin => "query_origin",
            .query_origin_after_refit => "query_origin_after_refit",
            .query_far => "query_far",
            .query_hit => "query_hit",
            .query_empty => "query_empty",
            .remove_b => "remove_b",
            .remove_inner => "remove_inner",
            .remove_right => "remove_right",
            .remove_single => "remove_single",
            .refit_mover_far => "refit_mover_far",
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
