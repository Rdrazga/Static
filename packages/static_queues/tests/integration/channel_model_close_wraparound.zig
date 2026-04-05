const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_queues = @import("static_queues");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;

const Channel = static_queues.channel.Channel(u8);

const ActionTag = enum(u32) {
    send_11 = 1,
    send_22 = 2,
    recv_11 = 3,
    send_33 = 4,
    close = 5,
    send_44_after_close = 6,
    recv_22 = 7,
    recv_33 = 8,
    recv_closed = 9,
};

const actions = [_]model.RecordedAction{
    .{ .tag = @intFromEnum(ActionTag.send_11) },
    .{ .tag = @intFromEnum(ActionTag.send_22) },
    .{ .tag = @intFromEnum(ActionTag.recv_11) },
    .{ .tag = @intFromEnum(ActionTag.send_33) },
    .{ .tag = @intFromEnum(ActionTag.close) },
    .{ .tag = @intFromEnum(ActionTag.send_44_after_close) },
    .{ .tag = @intFromEnum(ActionTag.recv_22) },
    .{ .tag = @intFromEnum(ActionTag.recv_33) },
    .{ .tag = @intFromEnum(ActionTag.recv_closed) },
};

const violations = [_]checker.Violation{
    .{
        .code = "static_queues.channel_model",
        .message = "channel close and wraparound sequence diverged from the bounded reference model",
    },
};

const Context = struct {
    channel: Channel = undefined,
    channel_initialized: bool = false,
    saw_wraparound: bool = false,
    saw_close: bool = false,
    saw_send_rejected_after_close: bool = false,
    saw_final_closed_recv: bool = false,

    fn resetState(self: *@This()) void {
        if (self.channel_initialized) {
            assert(self.channel.capacity() == 2);
            assert(self.channel.len() <= self.channel.capacity());
            self.channel.deinit();
        }

        self.channel = Channel.init(testing.allocator, .{ .capacity = 2 }) catch unreachable;
        self.channel_initialized = true;
        self.saw_wraparound = false;
        self.saw_close = false;
        self.saw_send_rejected_after_close = false;
        self.saw_final_closed_recv = false;

        assert(self.channel.capacity() == 2);
        assert(self.channel.len() == 0);
    }

    fn deinitState(self: *@This()) void {
        if (!self.channel_initialized) return;

        assert(self.channel.capacity() == 2);
        assert(self.channel.len() <= self.channel.capacity());
        self.channel.deinit();
        self.channel_initialized = false;
    }

    fn validate(self: *const @This()) checker.CheckResult {
        assert(self.channel_initialized);
        assert(self.channel.len() <= self.channel.capacity());
        if (!self.saw_wraparound or !self.saw_close or !self.saw_send_rejected_after_close or !self.saw_final_closed_recv) {
            return checker.CheckResult.fail(&violations, null);
        }
        if (!self.channel.isEmpty()) {
            return checker.CheckResult.fail(&violations, null);
        }
        return checker.CheckResult.pass(null);
    }

    fn expectSend(self: *@This(), value: u8, expected_len_after: usize) checker.CheckResult {
        assert(self.channel_initialized);
        assert(self.channel.len() + 1 == expected_len_after);
        self.channel.trySend(value) catch |err| switch (err) {
            error.WouldBlock, error.Closed => return checker.CheckResult.fail(&violations, null),
        };
        assert(self.channel.len() == expected_len_after);
        assert(self.channel.len() <= self.channel.capacity());
        return checker.CheckResult.pass(null);
    }

    fn expectRecv(self: *@This(), expected: u8, expected_len_after: usize) checker.CheckResult {
        assert(self.channel_initialized);
        assert(self.channel.len() == expected_len_after + 1);
        const actual = self.channel.tryRecv() catch |err| switch (err) {
            error.WouldBlock, error.Closed => return checker.CheckResult.fail(&violations, null),
        };
        if (actual != expected) return checker.CheckResult.fail(&violations, null);
        assert(self.channel.len() == expected_len_after);
        assert(self.channel.len() <= self.channel.capacity());
        return checker.CheckResult.pass(null);
    }

    fn expectClose(self: *@This()) checker.CheckResult {
        assert(self.channel_initialized);
        assert(self.channel.len() == self.channel.capacity());
        self.channel.close();
        self.saw_close = true;
        assert(self.channel.len() == self.channel.capacity());
        assert(self.channel.capacity() == 2);
        return checker.CheckResult.pass(null);
    }

    fn expectSendClosed(self: *@This(), value: u8) checker.CheckResult {
        assert(self.channel_initialized);
        assert(self.channel.isFull());
        self.channel.trySend(value) catch |err| switch (err) {
            error.Closed => {
                self.saw_send_rejected_after_close = true;
                assert(self.channel.isFull());
                assert(self.channel.len() == self.channel.capacity());
                return checker.CheckResult.pass(null);
            },
            error.WouldBlock => return checker.CheckResult.fail(&violations, null),
        };
        return checker.CheckResult.fail(&violations, null);
    }

    fn expectRecvClosed(self: *@This()) checker.CheckResult {
        assert(self.channel_initialized);
        assert(self.channel.isEmpty());
        _ = self.channel.tryRecv() catch |err| switch (err) {
            error.Closed => {
                self.saw_final_closed_recv = true;
                assert(self.channel.isEmpty());
                assert(self.channel.len() == 0);
                return checker.CheckResult.pass(null);
            },
            error.WouldBlock => return checker.CheckResult.fail(&violations, null),
        };
        return checker.CheckResult.fail(&violations, null);
    }
};

test "channel close and wraparound stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    defer context.deinitState();

    var action_storage: [actions.len]model.RecordedAction = undefined;
    var reduction_scratch: [actions.len]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_queues",
            .run_name = "channel_model_close_wraparound",
            .base_seed = .init(0x5351_5555_4555_4557),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = actions.len,
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

    try testing.expectEqual(@as(u32, 1), summary.executed_case_count);
    try testing.expect(summary.failed_case == null);
}

fn nextAction(
    _: *anyopaque,
    run_identity: identity.RunIdentity,
    action_index: u32,
    _: seed_mod.Seed,
) error{}!model.RecordedAction {
    assert(run_identity.case_index == 0);
    assert(action_index < actions.len);
    return actions[action_index];
}

fn step(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    _: u32,
    action: model.RecordedAction,
) error{}!model.ModelStep {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index == 0);
    const tag: ActionTag = @enumFromInt(action.tag);
    const check_result = switch (tag) {
        .send_11 => context.expectSend(11, 1),
        .send_22 => context.expectSend(22, 2),
        .recv_11 => context.expectRecv(11, 1),
        .send_33 => blk: {
            const result = context.expectSend(33, 2);
            if (result.passed) context.saw_wraparound = true;
            break :blk result;
        },
        .close => context.expectClose(),
        .send_44_after_close => context.expectSendClosed(44),
        .recv_22 => context.expectRecv(22, 1),
        .recv_33 => context.expectRecv(33, 0),
        .recv_closed => context.expectRecvClosed(),
    };
    return .{ .check_result = check_result };
}

fn finish(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index == 0);
    return context.validate();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .send_11 => "send_11",
            .send_22 => "send_22",
            .recv_11 => "recv_11",
            .send_33 => "send_33_wrap",
            .close => "close",
            .send_44_after_close => "send_after_close",
            .recv_22 => "recv_22",
            .recv_33 => "recv_33",
            .recv_closed => "recv_closed",
        },
    };
}

fn reset(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
) error{}!void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    assert(run_identity.case_index == 0);
    context.resetState();
}
