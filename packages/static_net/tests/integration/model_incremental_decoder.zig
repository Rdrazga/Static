const std = @import("std");
const static_net = @import("static_net");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;
const support = @import("frame_support.zig");

const ActionTag = enum(u32) {
    load_valid_plain = 1,
    load_valid_checksum = 2,
    load_corrupt_checksum = 3,
    load_truncated = 4,
    load_noncanonical = 5,
    feed_small = 6,
    feed_remaining = 7,
    close_input = 8,
    reset = 9,
};

const incremental_violation = [_]checker.Violation{
    .{
        .code = "static_net.incremental_decoder_model",
        .message = "incremental frame decoder diverged from the bounded reference parser",
    },
};

const IncrementalContext = struct {
    current_cfg: static_net.FrameConfig,
    decoder: static_net.Decoder,
    current_frame: [support.max_frame_bytes]u8 = [_]u8{0} ** support.max_frame_bytes,
    current_frame_len: usize = 0,
    delivered_len: usize = 0,
    payload_out: [support.max_payload_bytes]u8 = [_]u8{0} ** support.max_payload_bytes,

    fn init() IncrementalContext {
        const cfg = (static_net.FrameConfig{
            .max_payload_bytes = support.max_payload_bytes,
        }).init() catch unreachable;
        return .{
            .current_cfg = cfg,
            .decoder = static_net.Decoder.init(cfg) catch unreachable,
        };
    }

    fn resetAll(self: *IncrementalContext) void {
        self.current_cfg = (static_net.FrameConfig{
            .max_payload_bytes = support.max_payload_bytes,
        }).init() catch unreachable;
        self.decoder = static_net.Decoder.init(self.current_cfg) catch unreachable;
        self.current_frame_len = 0;
        self.delivered_len = 0;
        @memset(self.current_frame[0..], 0);
        @memset(self.payload_out[0..], 0);
        std.debug.assert(self.deliveredLen() == 0);
    }

    fn deliveredLen(self: *const IncrementalContext) usize {
        return self.delivered_len;
    }

    fn loadValid(self: *IncrementalContext, seed_value: u64, checksum: bool) checker.CheckResult {
        const cfg = (static_net.FrameConfig{
            .max_payload_bytes = support.max_payload_bytes,
            .checksum_mode = if (checksum) .enabled else .disabled,
        }).init() catch unreachable;
        var payload: [support.max_payload_bytes]u8 = undefined;
        const payload_len: usize = if (checksum) 12 else 9;
        support.fillPayload(payload[0..payload_len], seed_value);
        self.current_cfg = cfg;
        self.decoder = static_net.Decoder.init(cfg) catch unreachable;
        self.current_frame_len = support.encodeFrame(cfg, self.current_frame[0..], payload[0..payload_len]) catch unreachable;
        self.delivered_len = 0;
        @memset(self.payload_out[0..], 0);
        return self.currentReferencePass();
    }

    fn loadCorruptChecksum(self: *IncrementalContext, seed_value: u64) checker.CheckResult {
        const cfg = (static_net.FrameConfig{
            .max_payload_bytes = support.max_payload_bytes,
            .checksum_mode = .enabled,
        }).init() catch unreachable;
        var payload: [support.max_payload_bytes]u8 = undefined;
        const payload_len: usize = 10;
        support.fillPayload(payload[0..payload_len], seed_value);
        self.current_cfg = cfg;
        self.decoder = static_net.Decoder.init(cfg) catch unreachable;
        self.current_frame_len = support.encodeFrame(cfg, self.current_frame[0..], payload[0..payload_len]) catch unreachable;
        support.corruptLastChecksumByte(self.current_frame[0..self.current_frame_len], self.current_frame_len);
        self.delivered_len = 0;
        @memset(self.payload_out[0..], 0);
        return self.currentReferencePass();
    }

    fn loadTruncated(self: *IncrementalContext, seed_value: u64) checker.CheckResult {
        const cfg = (static_net.FrameConfig{
            .max_payload_bytes = support.max_payload_bytes,
        }).init() catch unreachable;
        var payload: [support.max_payload_bytes]u8 = undefined;
        const payload_len: usize = 15;
        support.fillPayload(payload[0..payload_len], seed_value);
        self.current_cfg = cfg;
        self.decoder = static_net.Decoder.init(cfg) catch unreachable;
        const written = support.encodeFrame(cfg, self.current_frame[0..], payload[0..payload_len]) catch unreachable;
        self.current_frame_len = written - 4;
        self.delivered_len = 0;
        @memset(self.payload_out[0..], 0);
        return self.currentReferencePass();
    }

    fn loadNoncanonical(self: *IncrementalContext) checker.CheckResult {
        const cfg = (static_net.FrameConfig{
            .max_payload_bytes = support.max_payload_bytes,
        }).init() catch unreachable;
        self.current_cfg = cfg;
        self.decoder = static_net.Decoder.init(cfg) catch unreachable;
        self.current_frame_len = support.writeNoncanonicalLengthFrame(cfg, self.current_frame[0..]);
        self.delivered_len = 0;
        @memset(self.payload_out[0..], 0);
        return self.currentReferencePass();
    }

    fn feedChunk(self: *IncrementalContext, requested_len: usize) checker.CheckResult {
        if (self.delivered_len >= self.current_frame_len) return self.currentReferencePass();

        const remaining = self.current_frame_len - self.delivered_len;
        const take = @min(requested_len, remaining);
        const decode_step = self.decoder.decode(
            self.current_frame[self.delivered_len .. self.delivered_len + take],
            &self.payload_out,
        );
        self.delivered_len += take;
        return self.validateStep(decode_step);
    }

    fn closeInput(self: *IncrementalContext) checker.CheckResult {
        const reference = support.parseReference(
            self.current_cfg,
            self.current_frame[0..self.delivered_len],
        );
        const close_behavior: support.CloseBehavior = blk: {
            self.decoder.endOfInput() catch |err| switch (err) {
                error.EndOfStream => break :blk .end_of_stream,
            };
            break :blk .success;
        };

        if (close_behavior != reference.close_behavior) {
            return checker.CheckResult.fail(
                &incremental_violation,
                checker.CheckpointDigest.init(self.currentDigest()),
            );
        }
        if (!self.decoder.isIdle()) {
            return checker.CheckResult.fail(
                &incremental_violation,
                checker.CheckpointDigest.init(self.currentDigest()),
            );
        }
        self.current_frame_len = 0;
        self.delivered_len = 0;
        @memset(self.current_frame[0..], 0);
        @memset(self.payload_out[0..], 0);
        return self.currentReferencePass();
    }

    fn validateStep(
        self: *IncrementalContext,
        decode_step: static_net.DecodeStep,
    ) checker.CheckResult {
        const reference = support.parseReference(
            self.current_cfg,
            self.current_frame[0..self.delivered_len],
        );

        switch (reference.outcome) {
            .need_more_input => {
                if (decode_step.status != .need_more_input) {
                    return checker.CheckResult.fail(
                        &incremental_violation,
                        checker.CheckpointDigest.init(self.currentDigest()),
                    );
                }
                if (self.decoder.isIdle()) {
                    return checker.CheckResult.fail(
                        &incremental_violation,
                        checker.CheckpointDigest.init(self.currentDigest()),
                    );
                }
            },
            .err => |reference_err| {
                if (decode_step.status != .err or decode_step.status.err != reference_err) {
                    return checker.CheckResult.fail(
                        &incremental_violation,
                        checker.CheckpointDigest.init(self.currentDigest()),
                    );
                }
                if (!self.decoder.isIdle()) {
                    return checker.CheckResult.fail(
                        &incremental_violation,
                        checker.CheckpointDigest.init(self.currentDigest()),
                    );
                }
            },
            .frame => |reference_frame| {
                if (decode_step.status != .frame) {
                    return checker.CheckResult.fail(
                        &incremental_violation,
                        checker.CheckpointDigest.init(self.currentDigest()),
                    );
                }
                if (decode_step.status.frame.payload_len != reference_frame.payload_len) {
                    return checker.CheckResult.fail(
                        &incremental_violation,
                        checker.CheckpointDigest.init(self.currentDigest()),
                    );
                }
                const digest = support.digestBytes(
                    self.payload_out[0..@as(usize, @intCast(reference_frame.payload_len))],
                );
                if (digest != reference_frame.payload_digest) {
                    return checker.CheckResult.fail(
                        &incremental_violation,
                        checker.CheckpointDigest.init(self.currentDigest()),
                    );
                }
                if (!self.decoder.isIdle()) {
                    return checker.CheckResult.fail(
                        &incremental_violation,
                        checker.CheckpointDigest.init(self.currentDigest()),
                    );
                }
            },
        }

        return self.currentReferencePass();
    }

    fn currentReferencePass(self: *IncrementalContext) checker.CheckResult {
        return checker.CheckResult.pass(checker.CheckpointDigest.init(self.currentDigest()));
    }

    fn currentDigest(self: *const IncrementalContext) u128 {
        var digest = support.foldDigest(
            support.digestBytes(self.current_frame[0..self.current_frame_len]),
            self.delivered_len,
        );
        digest = support.foldDigest(digest, if (self.current_cfg.checksumEnabled()) 1 else 0);
        digest = support.foldDigest(digest, self.current_cfg.max_payload_bytes);
        return @as(u128, digest);
    }
};

fn nextAction(
    _: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action_seed: seed_mod.Seed,
) error{}!model.RecordedAction {
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x6e47_6d6f_6465_0001);
    const random = prng.random();
    const choice = random.uintLessThan(u32, 9);
    const tag: ActionTag = switch (choice) {
        0 => .load_valid_plain,
        1 => .load_valid_checksum,
        2 => .load_corrupt_checksum,
        3 => .load_truncated,
        4 => .load_noncanonical,
        5 => .feed_small,
        6 => .feed_remaining,
        7 => .close_input,
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
        .load_valid_plain => context.loadValid(action.value ^ 0x1101, false),
        .load_valid_checksum => context.loadValid(action.value ^ 0x1102, true),
        .load_corrupt_checksum => context.loadCorruptChecksum(action.value ^ 0x1103),
        .load_truncated => context.loadTruncated(action.value ^ 0x1104),
        .load_noncanonical => context.loadNoncanonical(),
        .feed_small => context.feedChunk(1 + @as(usize, @intCast(action.value % 4))),
        .feed_remaining => context.feedChunk(support.max_frame_bytes),
        .close_input => context.closeInput(),
        .reset => blk: {
            context.resetAll();
            break :blk context.currentReferencePass();
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
    return context.currentReferencePass();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .load_valid_plain => "load_valid_plain",
            .load_valid_checksum => "load_valid_checksum",
            .load_corrupt_checksum => "load_corrupt_checksum",
            .load_truncated => "load_truncated",
            .load_noncanonical => "load_noncanonical",
            .feed_small => "feed_small",
            .feed_remaining => "feed_remaining",
            .close_input => "close_input",
            .reset => "reset",
        },
    };
}

fn reset(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
) error{}!void {
    const context: *IncrementalContext = @ptrCast(@alignCast(context_ptr));
    context.resetAll();
}

test "static_net incremental decoder sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = IncrementalContext.init();
    defer context.resetAll();
    context.resetAll();

    var action_storage: [32]model.RecordedAction = undefined;
    var reduction_scratch: [32]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_net",
            .run_name = "incremental_decoder_model",
            .base_seed = .init(0x6e47_2026_0320_0003),
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
    try std.testing.expectEqual(@as(u32, 96), summary.executed_case_count);
}
