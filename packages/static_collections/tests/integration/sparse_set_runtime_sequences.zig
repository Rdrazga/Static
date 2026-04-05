//! Model-based coverage for SparseSet insert/remove/clear/clone sequences.
//! Verifies dense-item membership against a bounded reference model.
const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const testing = std.testing;
const static_collections = @import("static_collections");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;

const SparseSet = static_collections.sparse_set.SparseSet;
const UniverseSize: usize = 8;
const ScenarioCount: u32 = 3;
const ActionCount: u32 = 12;

const ActionTag = enum(u32) {
    insert = 1,
    remove = 2,
    probe = 3,
    clear = 4,
    clone_validate = 5,
};

const violations = [_]checker.Violation{
    .{
        .code = "static_collections.sparse_set_model",
        .message = "sparse set runtime sequence diverged from the bounded reference model",
    },
};

fn encodeAction(comptime tag: ActionTag, comptime value: u32) model.RecordedAction {
    return .{
        .tag = @intFromEnum(tag),
        .value = value,
    };
}

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        encodeAction(.insert, 3),
        encodeAction(.insert, 7),
        encodeAction(.probe, 3),
        encodeAction(.remove, 5),
        encodeAction(.insert, 3),
        encodeAction(.insert, 1),
        encodeAction(.clone_validate, 0),
        encodeAction(.remove, 7),
        encodeAction(.probe, 1),
        encodeAction(.clear, 0),
        encodeAction(.insert, 6),
        encodeAction(.clone_validate, 0),
    },
    .{
        encodeAction(.insert, 0),
        encodeAction(.insert, 4),
        encodeAction(.remove, 2),
        encodeAction(.probe, 4),
        encodeAction(.insert, 0),
        encodeAction(.insert, 6),
        encodeAction(.clone_validate, 0),
        encodeAction(.remove, 4),
        encodeAction(.probe, 6),
        encodeAction(.clear, 0),
        encodeAction(.insert, 5),
        encodeAction(.clone_validate, 0),
    },
    .{
        encodeAction(.insert, 2),
        encodeAction(.insert, 5),
        encodeAction(.probe, 2),
        encodeAction(.remove, 1),
        encodeAction(.insert, 5),
        encodeAction(.insert, 7),
        encodeAction(.clone_validate, 0),
        encodeAction(.remove, 2),
        encodeAction(.probe, 7),
        encodeAction(.clear, 0),
        encodeAction(.insert, 3),
        encodeAction(.clone_validate, 0),
    },
};

const ReferenceState = struct {
    present: [UniverseSize]bool = [_]bool{false} ** UniverseSize,
    len: usize = 0,

    fn reset(self: *@This()) void {
        self.present = [_]bool{false} ** UniverseSize;
        self.len = 0;
        assert(self.len == 0);
    }

    fn insert(self: *@This(), value: usize) bool {
        if (self.present[value]) return false;
        self.present[value] = true;
        self.len += 1;
        return true;
    }

    fn remove(self: *@This(), value: usize) bool {
        if (!self.present[value]) return false;
        self.present[value] = false;
        self.len -= 1;
        return true;
    }

    fn clear(self: *@This()) void {
        self.reset();
    }
};

const Context = struct {
    set: SparseSet = undefined,
    set_initialized: bool = false,
    reference: ReferenceState = .{},
    saw_duplicate_insert: bool = false,
    saw_missing_remove: bool = false,
    saw_probe: bool = false,
    saw_clear: bool = false,
    saw_clone: bool = false,

    fn resetState(self: *@This()) void {
        if (self.set_initialized) self.set.deinit();
        self.set = SparseSet.init(testing.allocator, .{
            .universe_size = UniverseSize,
            .budget = null,
        }) catch |err| panic("resetState: SparseSet.init failed: {s}", .{@errorName(err)});
        self.set_initialized = true;
        self.reference.reset();
        self.saw_duplicate_insert = false;
        self.saw_missing_remove = false;
        self.saw_probe = false;
        self.saw_clear = false;
        self.saw_clone = false;
        assert(self.set.len() == 0);
    }

    fn validate(self: *@This()) checker.CheckResult {
        if (!compareSetToReference(&self.set, &self.reference)) {
            return checker.CheckResult.fail(&violations, null);
        }

        var digest: u128 = @as(u128, self.set.len()) << 64;
        for (self.reference.present, 0..) |present, value| {
            if (!present) continue;
            digest ^= @as(u128, value);
        }
        return checker.CheckResult.pass(checker.CheckpointDigest.init(digest));
    }

    fn insertValue(self: *@This(), value: usize) checker.CheckResult {
        const inserted = self.reference.insert(value);
        self.set.insert(@intCast(value)) catch |err| switch (err) {
            error.InvalidInput => return checker.CheckResult.fail(&violations, null),
            else => return checker.CheckResult.fail(&violations, null),
        };
        if (!inserted) self.saw_duplicate_insert = true;
        return self.validate();
    }

    fn removeValue(self: *@This(), value: usize) checker.CheckResult {
        const expected_present = self.reference.remove(value);
        self.set.remove(@intCast(value)) catch |err| switch (err) {
            error.InvalidInput => {
                if (!expected_present) {
                    self.saw_missing_remove = true;
                    return self.validate();
                }
                return checker.CheckResult.fail(&violations, null);
            },
        };
        if (!expected_present) return checker.CheckResult.fail(&violations, null);
        return self.validate();
    }

    fn probeValue(self: *@This(), value: usize) checker.CheckResult {
        const actual = self.set.contains(@intCast(value));
        if (actual != self.reference.present[value]) return checker.CheckResult.fail(&violations, null);
        self.saw_probe = true;
        return self.validate();
    }

    fn clearSet(self: *@This()) checker.CheckResult {
        self.set.clear();
        self.reference.clear();
        self.saw_clear = true;
        return self.validate();
    }

    fn cloneValidate(self: *@This()) checker.CheckResult {
        var clone = self.set.clone() catch return checker.CheckResult.fail(&violations, null);
        defer clone.deinit();
        if (!compareSetToReference(&clone, &self.reference)) return checker.CheckResult.fail(&violations, null);

        const original_present = self.reference.present[0];
        clone.insert(0) catch return checker.CheckResult.fail(&violations, null);
        if (!compareSetToReference(&self.set, &self.reference)) return checker.CheckResult.fail(&violations, null);
        if (self.set.contains(0) != original_present) return checker.CheckResult.fail(&violations, null);

        self.saw_clone = true;
        return self.validate();
    }

    fn finish(self: *@This()) checker.CheckResult {
        assert(self.saw_duplicate_insert);
        assert(self.saw_missing_remove);
        assert(self.saw_probe);
        assert(self.saw_clear);
        assert(self.saw_clone);
        return self.validate();
    }
};

test "sparse set runtime sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.set_initialized) context.set.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_collections",
            .run_name = "sparse_set_runtime_sequences",
            .base_seed = .init(0x17b4_2026_0000_7303),
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

fn compareSetToReference(set: *const SparseSet, reference: *const ReferenceState) bool {
    if (set.len() != reference.len) return false;

    for (reference.present, 0..) |present, value| {
        if (set.contains(@intCast(value)) != present) return false;
    }

    var seen = [_]bool{false} ** UniverseSize;
    for (set.items()) |value| {
        if (value >= UniverseSize) return false;
        if (!reference.present[value]) return false;
        if (seen[value]) return false;
        seen[value] = true;
    }
    return true;
}

fn nextAction(
    _: *anyopaque,
    run_identity: identity.RunIdentity,
    action_index: u32,
    _: static_testing.testing.seed.Seed,
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
    const value: usize = @intCast(action.value);
    const result = switch (tag) {
        .insert => context.insertValue(value),
        .remove => context.removeValue(value),
        .probe => context.probeValue(value),
        .clear => context.clearSet(),
        .clone_validate => context.cloneValidate(),
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
            .insert => "insert",
            .remove => "remove",
            .probe => "probe",
            .clear => "clear",
            .clone_validate => "clone_validate",
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
