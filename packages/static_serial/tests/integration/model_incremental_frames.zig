const std = @import("std");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;
const support = @import("frame_support.zig");

const ActionTag = enum(u32) {
    append_small = 1,
    append_medium = 2,
    append_large = 3,
    append_corrupt = 4,
    truncate_tail = 5,
    drain_ready = 6,
    reset = 7,
};

const incremental_violation = [_]checker.Violation{
    .{
        .code = "static_serial.incremental_frame_model",
        .message = "incremental frame buffering diverged from the bounded reference parser",
    },
};

const IncrementalContext = struct {
    buffer: [256]u8 = [_]u8{0} ** 256,
    len: usize = 0,
    scratch_frame: [support.max_frame_bytes]u8 = [_]u8{0} ** support.max_frame_bytes,

    fn resetState(self: *IncrementalContext) void {
        @memset(self.buffer[0..], 0);
        self.len = 0;
        std.debug.assert(self.len == 0);
    }

    fn validate(self: *IncrementalContext) checker.CheckResult {
        const check = support.evaluateFrameCase(
            self.buffer[0..self.len],
            &incremental_violation,
        );
        if (check.violations) |violations| {
            return checker.CheckResult.fail(
                violations,
                checker.CheckpointDigest.init(check.digest),
            );
        }
        return checker.CheckResult.pass(checker.CheckpointDigest.init(check.digest));
    }

    fn appendFrame(
        self: *IncrementalContext,
        payload_seed: u64,
        payload_len: usize,
        checksum_mode: support.FrameChecksumMode,
    ) checker.CheckResult {
        var payload: [support.max_payload_bytes]u8 = undefined;
        support.fillPayload(payload[0..payload_len], payload_seed);
        const frame_len = support.writeFrame(
            self.scratch_frame[0..],
            payload[0..payload_len],
            checksum_mode,
        ) catch unreachable;

        if (self.len + frame_len > self.buffer.len) {
            return self.validate();
        }

        @memcpy(
            self.buffer[self.len .. self.len + frame_len],
            self.scratch_frame[0..frame_len],
        );
        self.len += frame_len;
        std.debug.assert(self.len <= self.buffer.len);
        return self.validate();
    }

    fn truncateTail(
        self: *IncrementalContext,
        amount: usize,
    ) checker.CheckResult {
        const drop_len = @min(amount, self.len);
        self.len -= drop_len;
        return self.validate();
    }

    fn drainReady(self: *IncrementalContext) checker.CheckResult {
        const actual = support.parseFrameWithSerial(self.buffer[0..self.len]);
        const reference = support.parseFrameReference(self.buffer[0..self.len]);
        if (!support.outcomesEqual(actual, reference)) {
            return checker.CheckResult.fail(
                &incremental_violation,
                checker.CheckpointDigest.init(support.digestBytes(self.buffer[0..self.len])),
            );
        }

        switch (actual) {
            .ready => |ready| {
                const remaining = self.len - ready.consumed;
                std.mem.copyForwards(
                    u8,
                    self.buffer[0..remaining],
                    self.buffer[ready.consumed .. ready.consumed + remaining],
                );
                self.len = remaining;
            },
            else => {},
        }

        return self.validate();
    }
};

fn nextAction(
    _: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action_seed: seed_mod.Seed,
) error{}!model.RecordedAction {
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x5173_6d6f_6465_0001);
    const random = prng.random();
    const choice = random.uintLessThan(u32, 7);
    const tag: ActionTag = switch (choice) {
        0 => .append_small,
        1 => .append_medium,
        2 => .append_large,
        3 => .append_corrupt,
        4 => .truncate_tail,
        5 => .drain_ready,
        else => .reset,
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
    const context: *IncrementalContext = @ptrCast(@alignCast(context_ptr));
    const tag: ActionTag = @enumFromInt(action.tag);
    const result = switch (tag) {
        .append_small => context.appendFrame(
            action.value ^ 0x1101,
            1 + @as(usize, @intCast(action.value % 6)),
            .valid,
        ),
        .append_medium => context.appendFrame(
            action.value ^ 0x1102,
            7 + @as(usize, @intCast(action.value % 10)),
            .valid,
        ),
        .append_large => context.appendFrame(
            action.value ^ 0x1103,
            17 + @as(usize, @intCast(action.value % 20)),
            .valid,
        ),
        .append_corrupt => context.appendFrame(
            action.value ^ 0x1104,
            5 + @as(usize, @intCast(action.value % 10)),
            .mismatch,
        ),
        .truncate_tail => context.truncateTail(1 + @as(usize, @intCast(action.value % 8))),
        .drain_ready => context.drainReady(),
        .reset => blk: {
            context.resetState();
            break :blk context.validate();
        },
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *IncrementalContext = @ptrCast(@alignCast(context_ptr));
    return context.validate();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .append_small => "append_small",
            .append_medium => "append_medium",
            .append_large => "append_large",
            .append_corrupt => "append_corrupt",
            .truncate_tail => "truncate_tail",
            .drain_ready => "drain_ready",
            .reset => "reset",
        },
    };
}

fn reset(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
) error{}!void {
    const context: *IncrementalContext = @ptrCast(@alignCast(context_ptr));
    context.resetState();
}

test "static_serial incremental frame sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = IncrementalContext{};
    context.resetState();

    var action_storage: [32]model.RecordedAction = undefined;
    var reduction_scratch: [32]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_serial",
            .run_name = "incremental_frame_model",
            .base_seed = .init(0x5173_2026_0320_0003),
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
    if (summary.failed_case) |failed_case| {
        var summary_buffer: [1536]u8 = undefined;
        const summary_text = try model.formatFailedCaseSummary(
            error{},
            &summary_buffer,
            Target{
                .context = &context,
                .reset_fn = reset,
                .next_action_fn = nextAction,
                .step_fn = step,
                .finish_fn = finish,
                .describe_action_fn = describe,
            },
            failed_case,
        );
        std.debug.print("{s}", .{summary_text});
        return error.TestUnexpectedResult;
    }
}
