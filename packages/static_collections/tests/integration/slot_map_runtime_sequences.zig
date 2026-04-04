const std = @import("std");
const static_collections = @import("static_collections");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;

const SlotMap = static_collections.slot_map.SlotMap(u32);
const Handle = static_collections.handle.Handle;

const max_live_handles: usize = 4;

const ActionTag = enum(u32) {
    insert_value = 1,
    remove_oldest = 2,
    probe_stale = 3,
};

const slot_map_violation = [_]checker.Violation{
    .{
        .code = "static_collections.slot_map_model",
        .message = "slot map sequence diverged from the bounded reference model",
    },
};

const ReferenceState = struct {
    const Removed = struct {
        handle: Handle,
        value: u32,
    };

    handles: [max_live_handles]Handle = undefined,
    values: [max_live_handles]u32 = undefined,
    len: usize = 0,
    next_value: u32 = 1,
    pending_reuse: ?Handle = null,
    stale_handle: ?Handle = null,

    fn reset(self: *@This()) void {
        self.len = 0;
        self.next_value = 1;
        self.pending_reuse = null;
        self.stale_handle = null;
        std.debug.assert(self.len == 0);
        std.debug.assert(self.pending_reuse == null);
    }

    fn insert(self: *@This(), handle: Handle, value: u32) void {
        std.debug.assert(self.len < max_live_handles);
        if (self.pending_reuse) |expected| {
            std.debug.assert(handle.index == expected.index);
            std.debug.assert(handle.generation != expected.generation);
            self.pending_reuse = null;
        }
        self.handles[self.len] = handle;
        self.values[self.len] = value;
        self.len += 1;
        self.next_value += 1;
        std.debug.assert(self.len <= max_live_handles);
    }

    fn removeOldest(self: *@This()) ?Removed {
        if (self.len == 0) return null;
        const removed: Removed = .{
            .handle = self.handles[0],
            .value = self.values[0],
        };
        var index: usize = 1;
        while (index < self.len) : (index += 1) {
            self.handles[index - 1] = self.handles[index];
            self.values[index - 1] = self.values[index];
        }
        self.len -= 1;
        self.pending_reuse = removed.handle;
        self.stale_handle = removed.handle;
        std.debug.assert(self.len <= max_live_handles);
        return removed;
    }

};

const Context = struct {
    map: SlotMap = undefined,
    map_initialized: bool = false,
    reference: ReferenceState = .{},

    fn resetState(self: *@This()) void {
        if (self.map_initialized) {
            self.map.deinit();
        }
        self.map = SlotMap.init(std.testing.allocator, .{}) catch unreachable;
        self.map_initialized = true;
        self.reference.reset();
        std.debug.assert(self.map.len() == 0);
    }

    fn validate(self: *@This()) checker.CheckResult {
        var digest: u128 = @as(u128, self.map.len());
        std.debug.assert(self.map.len() == self.reference.len);
        for (self.reference.handles[0..self.reference.len], 0..) |handle, index| {
            const actual = self.map.get(handle) orelse {
                return checker.CheckResult.fail(&slot_map_violation, checker.CheckpointDigest.init(digest));
            };
            const expected_value = self.reference.values[index];
            if (actual.* != expected_value) {
                return checker.CheckResult.fail(&slot_map_violation, checker.CheckpointDigest.init(digest));
            }
            digest = digest ^ (@as(u128, handle.index) << 32) ^ (@as(u128, handle.generation) << 64) ^ @as(u128, expected_value);
        }
        if (self.reference.stale_handle) |stale_handle| {
            if (self.map.get(stale_handle) != null) {
                return checker.CheckResult.fail(&slot_map_violation, checker.CheckpointDigest.init(digest));
            }
            if (self.map.remove(stale_handle)) |_| {
                return checker.CheckResult.fail(&slot_map_violation, checker.CheckpointDigest.init(digest));
            } else |err| switch (err) {
                error.NotFound => {},
                else => return checker.CheckResult.fail(&slot_map_violation, checker.CheckpointDigest.init(digest)),
            }
        }
        return checker.CheckResult.pass(checker.CheckpointDigest.init(digest));
    }

    fn insertValue(self: *@This()) checker.CheckResult {
        if (self.reference.len == max_live_handles) {
            const expected = self.reference.removeOldest() orelse unreachable;
            const removed = self.map.remove(expected.handle) catch {
                return checker.CheckResult.fail(&slot_map_violation, null);
            };
            if (removed != expected.value) {
                return checker.CheckResult.fail(&slot_map_violation, null);
            }
        }
        const value = self.reference.next_value;
        const handle = self.map.insert(value) catch {
            return checker.CheckResult.fail(&slot_map_violation, null);
        };
        self.reference.insert(handle, value);
        return self.validate();
    }

    fn removeOldest(self: *@This()) checker.CheckResult {
        const expected = self.reference.removeOldest() orelse return self.validate();
        const removed = self.map.remove(expected.handle) catch {
            return checker.CheckResult.fail(&slot_map_violation, null);
        };
        if (removed != expected.value) {
            return checker.CheckResult.fail(&slot_map_violation, null);
        }
        return self.validate();
    }

    fn probeStale(self: *@This()) checker.CheckResult {
        if (self.reference.stale_handle) |stale_handle| {
            if (self.map.get(stale_handle) != null) {
                return checker.CheckResult.fail(&slot_map_violation, null);
            }
            if (self.map.remove(stale_handle)) |_| {
                return checker.CheckResult.fail(&slot_map_violation, null);
            } else |err| switch (err) {
                error.NotFound => {},
                else => return checker.CheckResult.fail(&slot_map_violation, null),
            }
        }
        return self.validate();
    }
};

test "slot map runtime sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.map_initialized) context.map.deinit();

    var action_storage: [16]model.RecordedAction = undefined;
    var reduction_scratch: [16]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_collections",
            .run_name = "slot_map_runtime_sequences",
            .base_seed = .init(0x534c_4f54_4d41_5001),
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
    try std.testing.expect(summary.failed_case == null);
}

test "slot map reuses the most recently removed slot first" {
    var sm = try SlotMap.init(std.testing.allocator, .{});
    defer sm.deinit();

    const first = try sm.insert(1);
    const second = try sm.insert(2);
    const third = try sm.insert(3);

    _ = try sm.remove(second);
    _ = try sm.remove(first);

    const reuse_first = try sm.insert(4);
    try std.testing.expectEqual(first.index, reuse_first.index);
    try std.testing.expect(reuse_first.generation != first.generation);

    const reuse_second = try sm.insert(5);
    try std.testing.expectEqual(second.index, reuse_second.index);
    try std.testing.expect(reuse_second.generation != second.generation);

    try std.testing.expectEqual(@as(u32, 3), sm.get(third).?.*);
    try std.testing.expect(sm.get(first) == null);
    try std.testing.expect(sm.get(second) == null);
    try std.testing.expectError(error.NotFound, sm.remove(first));
    try std.testing.expectError(error.NotFound, sm.remove(second));
}

fn nextAction(
    _: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action_seed: seed_mod.Seed,
) error{}!model.RecordedAction {
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x534c_4f54_4d41_5002);
    const random = prng.random();
    const tag: ActionTag = switch (random.uintLessThan(u32, 3)) {
        0 => .insert_value,
        1 => .remove_oldest,
        else => .probe_stale,
    };
    return .{
        .tag = @intFromEnum(tag),
        .value = random.int(u64),
    };
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
        .insert_value => context.insertValue(),
        .remove_oldest => context.removeOldest(),
        .probe_stale => context.probeStale(),
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
            .insert_value => "insert_value",
            .remove_oldest => "remove_oldest",
            .probe_stale => "probe_stale",
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
