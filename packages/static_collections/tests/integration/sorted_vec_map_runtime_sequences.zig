//! Model-based coverage for SortedVecMap mutation sequences with borrowed comparator callbacks.
//! Verifies sorted iteration, borrowed lookups, clear/reuse, and clone isolation.
const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const testing = std.testing;
const static_collections = @import("static_collections");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;

const Key = struct {
    hi: u32,
    lo: u32,
    tag: u32,
};

const PtrCmp = struct {
    pub fn less(a: *const Key, b: *const Key) bool {
        if (a.hi != b.hi) return a.hi < b.hi;
        if (a.lo != b.lo) return a.lo < b.lo;
        return a.tag < b.tag;
    }
};

const Map = static_collections.sorted_vec_map.SortedVecMap(Key, u32, PtrCmp);
const ScenarioCount: u32 = 3;
const ActionCount: u32 = 13;

const key_universe = [_]Key{
    .{ .hi = 3, .lo = 0, .tag = 1 },
    .{ .hi = 1, .lo = 9, .tag = 2 },
    .{ .hi = 2, .lo = 5, .tag = 3 },
    .{ .hi = 1, .lo = 2, .tag = 4 },
    .{ .hi = 4, .lo = 1, .tag = 5 },
    .{ .hi = 0, .lo = 7, .tag = 6 },
};

const ActionTag = enum(u32) {
    put = 1,
    get_or_put = 2,
    remove = 3,
    remove_or_null = 4,
    probe = 5,
    clear = 6,
    clone_validate = 7,
};

const violations = [_]checker.Violation{
    .{
        .code = "static_collections.sorted_vec_map_model",
        .message = "sorted vec map runtime sequence diverged from the bounded reference model",
    },
};

fn encodeAction(comptime tag: ActionTag, comptime slot: u32, comptime value: u32) model.RecordedAction {
    return .{
        .tag = @intFromEnum(tag),
        .value = (@as(u64, slot) << 32) | value,
    };
}

fn decodeSlot(action: model.RecordedAction) usize {
    return @intCast(action.value >> 32);
}

fn decodePayload(action: model.RecordedAction) u32 {
    return @intCast(action.value & 0xffff_ffff);
}

const action_table = [ScenarioCount][ActionCount]model.RecordedAction{
    .{
        encodeAction(.put, 2, 20),
        encodeAction(.put, 0, 10),
        encodeAction(.get_or_put, 0, 99),
        encodeAction(.get_or_put, 3, 30),
        encodeAction(.probe, 2, 0),
        encodeAction(.clone_validate, 0, 0),
        encodeAction(.remove, 4, 0),
        encodeAction(.put, 1, 15),
        encodeAction(.remove_or_null, 3, 0),
        encodeAction(.probe, 1, 0),
        encodeAction(.clear, 0, 0),
        encodeAction(.get_or_put, 5, 40),
        encodeAction(.clone_validate, 0, 0),
    },
    .{
        encodeAction(.put, 5, 60),
        encodeAction(.put, 1, 15),
        encodeAction(.get_or_put, 5, 99),
        encodeAction(.probe, 1, 0),
        encodeAction(.get_or_put, 2, 20),
        encodeAction(.remove, 4, 0),
        encodeAction(.clone_validate, 0, 0),
        encodeAction(.put, 3, 30),
        encodeAction(.remove_or_null, 2, 0),
        encodeAction(.probe, 3, 0),
        encodeAction(.clear, 0, 0),
        encodeAction(.get_or_put, 0, 10),
        encodeAction(.clone_validate, 0, 0),
    },
    .{
        encodeAction(.put, 4, 40),
        encodeAction(.put, 3, 30),
        encodeAction(.get_or_put, 1, 15),
        encodeAction(.probe, 4, 0),
        encodeAction(.get_or_put, 4, 99),
        encodeAction(.remove, 2, 0),
        encodeAction(.clone_validate, 0, 0),
        encodeAction(.put, 0, 10),
        encodeAction(.remove_or_null, 3, 0),
        encodeAction(.probe, 1, 0),
        encodeAction(.clear, 0, 0),
        encodeAction(.get_or_put, 5, 60),
        encodeAction(.clone_validate, 0, 0),
    },
};

const ReferenceState = struct {
    present: [key_universe.len]bool = [_]bool{false} ** key_universe.len,
    values: [key_universe.len]u32 = [_]u32{0} ** key_universe.len,
    len: usize = 0,

    fn reset(self: *@This()) void {
        self.present = [_]bool{false} ** key_universe.len;
        self.values = [_]u32{0} ** key_universe.len;
        self.len = 0;
        assert(self.len == 0);
    }

    fn put(self: *@This(), slot: usize, value: u32) void {
        if (!self.present[slot]) self.len += 1;
        self.present[slot] = true;
        self.values[slot] = value;
        assert(self.len <= key_universe.len);
    }

    fn remove(self: *@This(), slot: usize) ?u32 {
        if (!self.present[slot]) return null;
        const value = self.values[slot];
        self.present[slot] = false;
        self.values[slot] = 0;
        self.len -= 1;
        return value;
    }

    fn clear(self: *@This()) void {
        self.reset();
    }
};

const Context = struct {
    map: Map = undefined,
    map_initialized: bool = false,
    reference: ReferenceState = .{},
    saw_inserted_get_or_put: bool = false,
    saw_existing_get_or_put: bool = false,
    saw_remove_missing: bool = false,
    saw_remove_or_null: bool = false,
    saw_probe: bool = false,
    saw_clear: bool = false,
    saw_clone: bool = false,

    fn resetState(self: *@This()) void {
        if (self.map_initialized) self.map.deinit();
        self.map = Map.init(testing.allocator, .{ .budget = null }) catch
            |err| panic("resetState: SortedVecMap.init failed: {s}", .{@errorName(err)});
        self.map_initialized = true;
        self.reference.reset();
        self.saw_inserted_get_or_put = false;
        self.saw_existing_get_or_put = false;
        self.saw_remove_missing = false;
        self.saw_remove_or_null = false;
        self.saw_probe = false;
        self.saw_clear = false;
        self.saw_clone = false;
        assert(self.map.len() == 0);
    }

    fn validate(self: *@This()) checker.CheckResult {
        if (!compareMapToReference(&self.map, &self.reference)) {
            return checker.CheckResult.fail(&violations, null);
        }

        var digest: u128 = @as(u128, self.map.len()) << 64;
        var slot: usize = 0;
        while (slot < key_universe.len) : (slot += 1) {
            if (!self.reference.present[slot]) continue;
            digest ^= (@as(u128, slot) << 32) ^ @as(u128, self.reference.values[slot]);
        }
        return checker.CheckResult.pass(checker.CheckpointDigest.init(digest));
    }

    fn putValue(self: *@This(), slot: usize, value: u32) checker.CheckResult {
        const key = key_universe[slot];
        self.map.put(key, value) catch return checker.CheckResult.fail(&violations, null);
        self.reference.put(slot, value);
        return self.validate();
    }

    fn getOrPutValue(self: *@This(), slot: usize, value: u32) checker.CheckResult {
        const key = key_universe[slot];
        const expected_existing = self.reference.present[slot];
        const result = self.map.getOrPut(key, value) catch return checker.CheckResult.fail(&violations, null);
        if (result.found_existing != expected_existing) return checker.CheckResult.fail(&violations, null);

        const final_value = if (expected_existing) self.reference.values[slot] + 1 else value + 1;
        result.value_ptr.* = final_value;
        self.reference.put(slot, final_value);
        if (expected_existing) {
            self.saw_existing_get_or_put = true;
        } else {
            self.saw_inserted_get_or_put = true;
        }
        return self.validate();
    }

    fn removeValue(self: *@This(), slot: usize) checker.CheckResult {
        const key = key_universe[slot];
        const expected = self.reference.remove(slot);
        if (expected) |value| {
            const removed = self.map.removeBorrowed(&key) catch return checker.CheckResult.fail(&violations, null);
            if (removed != value) return checker.CheckResult.fail(&violations, null);
        } else {
            _ = self.map.removeBorrowed(&key) catch |err| switch (err) {
                error.NotFound => {
                    self.saw_remove_missing = true;
                    return self.validate();
                },
                else => return checker.CheckResult.fail(&violations, null),
            };
            return checker.CheckResult.fail(&violations, null);
        }
        return self.validate();
    }

    fn removeOrNullValue(self: *@This(), slot: usize) checker.CheckResult {
        const key = key_universe[slot];
        const expected = self.reference.remove(slot);
        const removed = self.map.removeOrNullBorrowed(&key);
        if (removed != expected) return checker.CheckResult.fail(&violations, null);
        self.saw_remove_or_null = true;
        return self.validate();
    }

    fn probeValue(self: *@This(), slot: usize) checker.CheckResult {
        const key = key_universe[slot];
        const contains = self.map.containsBorrowed(&key);
        const value_ptr = self.map.getConstBorrowed(&key);
        if (contains != self.reference.present[slot]) return checker.CheckResult.fail(&violations, null);
        if (self.reference.present[slot]) {
            if (value_ptr == null or value_ptr.?.* != self.reference.values[slot]) {
                return checker.CheckResult.fail(&violations, null);
            }
        } else if (value_ptr != null) {
            return checker.CheckResult.fail(&violations, null);
        }
        self.saw_probe = true;
        return self.validate();
    }

    fn clearMap(self: *@This()) checker.CheckResult {
        self.map.clear();
        self.reference.clear();
        self.saw_clear = true;
        return self.validate();
    }

    fn cloneValidate(self: *@This()) checker.CheckResult {
        var clone = self.map.clone() catch return checker.CheckResult.fail(&violations, null);
        defer clone.deinit();
        if (!compareMapToReference(&clone, &self.reference)) return checker.CheckResult.fail(&violations, null);

        const original_present = self.reference.present[0];
        const original_value = self.reference.values[0];
        clone.put(key_universe[0], 777) catch return checker.CheckResult.fail(&violations, null);
        if (!compareMapToReference(&self.map, &self.reference)) return checker.CheckResult.fail(&violations, null);
        if (original_present) {
            const current = self.map.getConstBorrowed(&key_universe[0]) orelse return checker.CheckResult.fail(&violations, null);
            if (current.* != original_value) return checker.CheckResult.fail(&violations, null);
        } else if (self.map.getConstBorrowed(&key_universe[0]) != null) {
            return checker.CheckResult.fail(&violations, null);
        }

        self.saw_clone = true;
        return self.validate();
    }

    fn finish(self: *@This()) checker.CheckResult {
        assert(self.saw_inserted_get_or_put);
        assert(self.saw_existing_get_or_put);
        assert(self.saw_remove_missing);
        assert(self.saw_remove_or_null);
        assert(self.saw_probe);
        assert(self.saw_clear);
        assert(self.saw_clone);
        return self.validate();
    }
};

test "sorted vec map runtime sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.map_initialized) context.map.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_collections",
            .run_name = "sorted_vec_map_runtime_sequences",
            .base_seed = .init(0x17b4_2026_0000_7302),
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

fn compareMapToReference(map: *const Map, reference: *const ReferenceState) bool {
    if (map.len() != reference.len) return false;

    var slot: usize = 0;
    while (slot < key_universe.len) : (slot += 1) {
        const key = key_universe[slot];
        const contains = map.containsBorrowed(&key);
        const value_ptr = map.getConstBorrowed(&key);
        if (contains != reference.present[slot]) return false;
        if (reference.present[slot]) {
            if (value_ptr == null or value_ptr.?.* != reference.values[slot]) return false;
        } else if (value_ptr != null) {
            return false;
        }
    }

    var expected_order: [key_universe.len]usize = undefined;
    const expected_len = collectSortedSlots(reference, &expected_order);

    var index: usize = 0;
    var it = map.iteratorConst();
    while (it.next()) |entry| : (index += 1) {
        if (index >= expected_len) return false;
        const slot_index = slotForKey(entry.key_ptr.*) orelse return false;
        if (slot_index != expected_order[index]) return false;
        if (entry.value_ptr.* != reference.values[slot_index]) return false;
    }
    return index == expected_len;
}

fn collectSortedSlots(reference: *const ReferenceState, out: *[key_universe.len]usize) usize {
    var len: usize = 0;
    for (key_universe, 0..) |_, slot| {
        if (!reference.present[slot]) continue;
        out[len] = slot;
        len += 1;
    }

    var i: usize = 1;
    while (i < len) : (i += 1) {
        const current = out[i];
        var j: usize = i;
        while (j > 0 and PtrCmp.less(&key_universe[current], &key_universe[out[j - 1]])) : (j -= 1) {
            out[j] = out[j - 1];
        }
        out[j] = current;
    }
    return len;
}

fn slotForKey(key: Key) ?usize {
    for (key_universe, 0..) |candidate, slot| {
        if (!PtrCmp.less(&candidate, &key) and !PtrCmp.less(&key, &candidate)) return slot;
    }
    return null;
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
    const slot = decodeSlot(action);
    const payload = decodePayload(action);
    const result = switch (tag) {
        .put => context.putValue(slot, payload),
        .get_or_put => context.getOrPutValue(slot, payload),
        .remove => context.removeValue(slot),
        .remove_or_null => context.removeOrNullValue(slot),
        .probe => context.probeValue(slot),
        .clear => context.clearMap(),
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
            .put => "put",
            .get_or_put => "get_or_put",
            .remove => "remove",
            .remove_or_null => "remove_or_null",
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
