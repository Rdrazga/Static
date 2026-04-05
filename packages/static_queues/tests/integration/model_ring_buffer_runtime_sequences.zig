const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_queues = @import("static_queues");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;

const RingBuffer = static_queues.ring_buffer.RingBuffer(u8);
const Capacity: usize = 4;
const ActionCount: usize = 16;
const ScenarioCount: u32 = 96;
const BatchMax: usize = 3;

const ActionTag = enum(u32) {
    push_value = 1,
    pop_value = 2,
    push_batch = 3,
    pop_batch = 4,
    discard_some = 5,
    peek_contiguous = 6,
    push_overwrite = 7,
};

const ring_buffer_violation = [_]checker.Violation{
    .{
        .code = "static_queues.ring_buffer_model",
        .message = "ring buffer runtime sequence diverged from the bounded reference model",
    },
};

const ReferenceState = struct {
    storage: [Capacity]u8 = undefined,
    head: usize = 0,
    len: usize = 0,

    fn reset(self: *@This()) void {
        self.head = 0;
        self.len = 0;
        assert(self.head == 0);
        assert(self.len == 0);
    }

    fn capacity(_: *const @This()) usize {
        return Capacity;
    }

    fn tail(self: *const @This()) usize {
        return (self.head + self.len) % Capacity;
    }

    fn isEmpty(self: *const @This()) bool {
        return self.len == 0;
    }

    fn isFull(self: *const @This()) bool {
        return self.len == Capacity;
    }

    fn valueAt(self: *const @This(), logical_index: usize) u8 {
        assert(logical_index < self.len);
        return self.storage[(self.head + logical_index) % Capacity];
    }

    fn tryPush(self: *@This(), value: u8) bool {
        if (self.isFull()) return false;
        const tail_index = self.tail();
        self.storage[tail_index] = value;
        self.len += 1;
        assert(self.len <= Capacity);
        return true;
    }

    fn tryPop(self: *@This()) ?u8 {
        if (self.isEmpty()) return null;
        const value = self.storage[self.head];
        self.head = (self.head + 1) % Capacity;
        self.len -= 1;
        assert(self.len <= Capacity);
        return value;
    }

    fn tryPushBatch(self: *@This(), values: []const u8) usize {
        var sent_count: usize = 0;
        while (sent_count < values.len and self.tryPush(values[sent_count])) : (sent_count += 1) {}
        return sent_count;
    }

    fn tryPopBatch(self: *@This(), out: []u8) usize {
        var recv_count: usize = 0;
        while (recv_count < out.len) : (recv_count += 1) {
            out[recv_count] = self.tryPop() orelse return recv_count;
        }
        return recv_count;
    }

    fn discard(self: *@This(), n: usize) usize {
        const consumed = @min(n, self.len);
        if (consumed == 0) return 0;
        self.head = (self.head + consumed) % Capacity;
        self.len -= consumed;
        assert(self.len <= Capacity);
        return consumed;
    }

    fn pushOverwrite(self: *@This(), value: u8) ?u8 {
        if (self.isFull()) {
            const overwritten = self.storage[self.head];
            self.storage[self.head] = value;
            self.head = (self.head + 1) % Capacity;
            assert(self.len == Capacity);
            return overwritten;
        }

        const inserted = self.tryPush(value);
        assert(inserted);
        return null;
    }

    fn peekContiguous(self: *const @This(), max: usize) []const u8 {
        if (self.len == 0) return self.storage[0..0];
        const contiguous = @min(self.len, Capacity - self.head);
        const count = @min(contiguous, max);
        return self.storage[self.head .. self.head + count];
    }
};

const Context = struct {
    ring: RingBuffer = undefined,
    ring_initialized: bool = false,
    reference: ReferenceState = .{},

    fn resetState(self: *@This()) void {
        if (self.ring_initialized) {
            self.ring.deinit();
        }
        self.ring = RingBuffer.init(testing.allocator, .{ .capacity = Capacity }) catch unreachable;
        self.ring_initialized = true;
        self.reference.reset();
        assert(self.ring.capacity() == Capacity);
        assert(self.ring.len() == 0);
    }

    fn validate(self: *@This()) checker.CheckResult {
        if (self.ring.capacity() != self.reference.capacity()) {
            return checker.CheckResult.fail(&ring_buffer_violation, null);
        }
        if (self.ring.len() != self.reference.len) {
            return checker.CheckResult.fail(&ring_buffer_violation, null);
        }
        if (self.ring.isEmpty() != self.reference.isEmpty()) {
            return checker.CheckResult.fail(&ring_buffer_violation, null);
        }
        if (self.ring.isFull() != self.reference.isFull()) {
            return checker.CheckResult.fail(&ring_buffer_violation, null);
        }

        const expected_peek = self.reference.peekContiguous(Capacity);
        const actual_peek = self.ring.peekContiguous(Capacity);
        if (!std.mem.eql(u8, expected_peek, actual_peek)) {
            return checker.CheckResult.fail(&ring_buffer_violation, null);
        }

        var digest: u128 = (@as(u128, self.reference.head) << 64) | @as(u128, self.reference.len);
        var logical_index: usize = 0;
        while (logical_index < self.reference.len) : (logical_index += 1) {
            digest = (digest << 7) ^ @as(u128, self.reference.valueAt(logical_index));
        }
        return checker.CheckResult.pass(checker.CheckpointDigest.init(digest));
    }

    fn pushValue(self: *@This(), value: u8) checker.CheckResult {
        const expected_ok = self.reference.tryPush(value);
        if (expected_ok) {
            self.ring.tryPush(value) catch {
                return checker.CheckResult.fail(&ring_buffer_violation, null);
            };
        } else {
            self.ring.tryPush(value) catch |err| switch (err) {
                error.WouldBlock => return self.validate(),
            };
            return checker.CheckResult.fail(&ring_buffer_violation, null);
        }
        return self.validate();
    }

    fn popValue(self: *@This()) checker.CheckResult {
        const expected = self.reference.tryPop();
        const actual = self.ring.tryPop() catch |err| switch (err) {
            error.WouldBlock => {
                if (expected != null) return checker.CheckResult.fail(&ring_buffer_violation, null);
                return self.validate();
            },
        };
        if (expected == null) return checker.CheckResult.fail(&ring_buffer_violation, null);
        if (actual != expected.?) return checker.CheckResult.fail(&ring_buffer_violation, null);
        return self.validate();
    }

    fn pushBatch(self: *@This(), values: []const u8) checker.CheckResult {
        const expected_count = self.reference.tryPushBatch(values);
        const actual_count = self.ring.tryPushBatch(values);
        if (actual_count != expected_count) return checker.CheckResult.fail(&ring_buffer_violation, null);
        return self.validate();
    }

    fn popBatch(self: *@This(), out_len: usize) checker.CheckResult {
        var expected_out: [BatchMax]u8 = undefined;
        var actual_out: [BatchMax]u8 = undefined;

        const expected_count = self.reference.tryPopBatch(expected_out[0..out_len]);
        const actual_count = self.ring.tryPopBatch(actual_out[0..out_len]);
        if (actual_count != expected_count) return checker.CheckResult.fail(&ring_buffer_violation, null);
        if (!std.mem.eql(u8, expected_out[0..expected_count], actual_out[0..actual_count])) {
            return checker.CheckResult.fail(&ring_buffer_violation, null);
        }
        return self.validate();
    }

    fn discardSome(self: *@This(), count: usize) checker.CheckResult {
        const expected = self.reference.discard(count);
        const actual = self.ring.discard(count);
        if (actual != expected) return checker.CheckResult.fail(&ring_buffer_violation, null);
        return self.validate();
    }

    fn peekContiguous(self: *@This(), max: usize) checker.CheckResult {
        const expected = self.reference.peekContiguous(max);
        const actual = self.ring.peekContiguous(max);
        if (!std.mem.eql(u8, expected, actual)) return checker.CheckResult.fail(&ring_buffer_violation, null);
        return self.validate();
    }

    fn pushOverwrite(self: *@This(), value: u8) checker.CheckResult {
        const expected = self.reference.pushOverwrite(value);
        const actual = self.ring.pushOverwrite(value);
        if (actual != expected) return checker.CheckResult.fail(&ring_buffer_violation, null);
        return self.validate();
    }
};

test "ring buffer runtime sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();
    defer if (context.ring_initialized) context.ring.deinit();

    var action_storage: [ActionCount]model.RecordedAction = undefined;
    var reduction_scratch: [ActionCount]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_queues",
            .run_name = "ring_buffer_runtime_sequences",
            .base_seed = .init(0x17b4_2026_0000_5101),
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
    _: identity.RunIdentity,
    _: u32,
    action_seed: seed_mod.Seed,
) error{}!model.RecordedAction {
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x17b4_2026_0000_5102);
    const random = prng.random();
    const tag: ActionTag = switch (random.uintLessThan(u32, 7)) {
        0 => .push_value,
        1 => .pop_value,
        2 => .push_batch,
        3 => .pop_batch,
        4 => .discard_some,
        5 => .peek_contiguous,
        else => .push_overwrite,
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
        .push_value => context.pushValue(byteFromValue(action.value, 0)),
        .pop_value => context.popValue(),
        .push_batch => blk: {
            const values = batchValues(action.value);
            break :blk context.pushBatch(&values);
        },
        .pop_batch => context.popBatch(countFromValue(action.value)),
        .discard_some => context.discardSome(countFromValue(action.value)),
        .peek_contiguous => context.peekContiguous(countFromValue(action.value)),
        .push_overwrite => context.pushOverwrite(byteFromValue(action.value, 1)),
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
            .push_value => "push_value",
            .pop_value => "pop_value",
            .push_batch => "push_batch",
            .pop_batch => "pop_batch",
            .discard_some => "discard_some",
            .peek_contiguous => "peek_contiguous",
            .push_overwrite => "push_overwrite",
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

fn byteFromValue(value: u64, shift_bytes: u6) u8 {
    return @truncate(value >> (@as(u6, shift_bytes) * 8));
}

fn countFromValue(value: u64) usize {
    return @as(usize, @intCast((value % BatchMax) + 1));
}

fn batchValues(value: u64) [BatchMax]u8 {
    return .{
        byteFromValue(value, 0),
        byteFromValue(value, 1),
        byteFromValue(value, 2),
    };
}
