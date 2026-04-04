const std = @import("std");
const static_rng = @import("static_rng");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;
const support = @import("support.zig");

const model_violation = [_]checker.Violation{
    .{
        .code = "static_rng.model_stream_lineage",
        .message = "stream lineage or deterministic consumer behavior diverged from the bounded reference model",
    },
};

const ActionTag = enum(u32) {
    init_pcg_parent = 1,
    pcg_next_u32 = 2,
    sample_uint_below = 3,
    pcg_next_u64 = 4,
    pcg_split = 5,
    pcg_child_next_u32 = 6,
    shuffle_slice = 7,
    init_xor_parent = 8,
    xor_next_u64 = 9,
    xor_jump = 10,
    xor_split = 11,
    xor_child_next_u64 = 12,
};

const PcgSlot = struct {
    live: ?static_rng.Pcg32 = null,
    reference: ?support.ReferencePcg32 = null,

    fn reset(self: *@This()) void {
        self.live = null;
        self.reference = null;
        std.debug.assert(self.live == null);
        std.debug.assert(self.reference == null);
    }

    fn active(self: *const @This()) bool {
        std.debug.assert((self.live == null) == (self.reference == null));
        std.debug.assert(self.live != null or self.reference == null);
        return self.live != null;
    }
};

const XorSlot = struct {
    live: ?static_rng.Xoroshiro128Plus = null,
    reference: ?support.ReferenceXoroshiro128Plus = null,

    fn reset(self: *@This()) void {
        self.live = null;
        self.reference = null;
        std.debug.assert(self.live == null);
        std.debug.assert(self.reference == null);
    }

    fn active(self: *const @This()) bool {
        std.debug.assert((self.live == null) == (self.reference == null));
        std.debug.assert(self.live != null or self.reference == null);
        return self.live != null;
    }
};

const Context = struct {
    pcg_parent: PcgSlot = .{},
    pcg_child: PcgSlot = .{},
    xor_parent: XorSlot = .{},
    xor_child: XorSlot = .{},
    consumer_digest: u128 = 0,

    fn resetState(self: *@This()) void {
        self.pcg_parent.reset();
        self.pcg_child.reset();
        self.xor_parent.reset();
        self.xor_child.reset();
        self.consumer_digest = 0;
        std.debug.assert(!self.pcg_parent.active());
        std.debug.assert(!self.xor_parent.active());
    }

    fn validate(self: *@This()) checker.CheckResult {
        var digest = self.consumer_digest;
        if (!self.pcgAligned(&self.pcg_parent)) return checker.CheckResult.fail(&model_violation, checker.CheckpointDigest.init(digest));
        if (!self.pcgAligned(&self.pcg_child)) return checker.CheckResult.fail(&model_violation, checker.CheckpointDigest.init(digest));
        if (!self.xorAligned(&self.xor_parent)) return checker.CheckResult.fail(&model_violation, checker.CheckpointDigest.init(digest));
        if (!self.xorAligned(&self.xor_child)) return checker.CheckResult.fail(&model_violation, checker.CheckpointDigest.init(digest));

        if (self.pcg_parent.live) |live| {
            digest = support.foldDigest(digest, live.state);
            digest = support.foldDigest(digest, live.inc);
        }
        if (self.pcg_child.live) |live| {
            digest = support.foldDigest(digest, live.state);
            digest = support.foldDigest(digest, live.inc);
        }
        if (self.xor_parent.live) |live| {
            digest = support.foldDigest(digest, live.s0);
            digest = support.foldDigest(digest, live.s1);
        }
        if (self.xor_child.live) |live| {
            digest = support.foldDigest(digest, live.s0);
            digest = support.foldDigest(digest, live.s1);
        }

        std.debug.assert(digest != 0 or self.consumer_digest == 0);
        std.debug.assert(self.consumer_digest == 0 or digest != 0);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(digest));
    }

    fn pcgAligned(self: *@This(), slot: *const PcgSlot) bool {
        _ = self;
        if (slot.live == null and slot.reference == null) return true;
        if (slot.live == null or slot.reference == null) return false;
        const live = slot.live.?;
        const reference = slot.reference.?;
        return live.state == reference.state and live.inc == reference.inc;
    }

    fn xorAligned(self: *@This(), slot: *const XorSlot) bool {
        _ = self;
        if (slot.live == null and slot.reference == null) return true;
        if (slot.live == null or slot.reference == null) return false;
        const live = slot.live.?;
        const reference = slot.reference.?;
        return live.s0 == reference.s0 and live.s1 == reference.s1;
    }

    fn initPcgParent(self: *@This(), action_value: u64) checker.CheckResult {
        const seed = support.seedFrom(action_value, 0x5050_4347_5f53_4545);
        const sequence = support.sequenceFrom(action_value, 0x5050_4347_5f51_5545);
        self.pcg_parent.live = static_rng.Pcg32.init(seed, sequence);
        self.pcg_parent.reference = support.ReferencePcg32.init(seed, sequence);
        std.debug.assert(self.pcg_parent.active());
        std.debug.assert(self.pcg_parent.live.?.inc == self.pcg_parent.reference.?.inc);
        return self.validate();
    }

    fn initXorParent(self: *@This(), action_value: u64) checker.CheckResult {
        const seed = support.seedFrom(action_value, 0x584f_524f_5f53_4545);
        self.xor_parent.live = static_rng.Xoroshiro128Plus.init(seed);
        self.xor_parent.reference = support.ReferenceXoroshiro128Plus.init(seed);
        std.debug.assert(self.xor_parent.active());
        std.debug.assert(self.xor_parent.live.?.s0 != 0 or self.xor_parent.live.?.s1 != 0);
        return self.validate();
    }

    fn pcgNextU32(self: *@This(), use_child: bool) checker.CheckResult {
        const slot = self.selectPcgSlot(use_child);
        if (!slot.active()) return self.validate();
        const live_value = slot.live.?.nextU32();
        const ref_value = slot.reference.?.nextU32();
        if (live_value != ref_value) return checker.CheckResult.fail(&model_violation, null);
        self.consumer_digest = support.foldDigest(self.consumer_digest, live_value);
        return self.validate();
    }

    fn pcgNextU64(self: *@This(), use_child: bool) checker.CheckResult {
        const slot = self.selectPcgSlot(use_child);
        if (!slot.active()) return self.validate();
        const live_value = slot.live.?.nextU64();
        const ref_value = slot.reference.?.nextU64();
        if (live_value != ref_value) return checker.CheckResult.fail(&model_violation, null);
        self.consumer_digest = support.foldDigest(self.consumer_digest, live_value);
        return self.validate();
    }

    fn pcgSplit(self: *@This()) checker.CheckResult {
        if (!self.pcg_parent.active()) return self.validate();
        self.pcg_child.live = self.pcg_parent.live.?.split();
        self.pcg_child.reference = self.pcg_parent.reference.?.split();
        std.debug.assert(self.pcg_child.active());
        std.debug.assert(self.pcg_parent.active());
        return self.validate();
    }

    fn xorNextU64(self: *@This(), use_child: bool) checker.CheckResult {
        const slot = self.selectXorSlot(use_child);
        if (!slot.active()) return self.validate();
        const live_value = slot.live.?.nextU64();
        const ref_value = slot.reference.?.nextU64();
        if (live_value != ref_value) return checker.CheckResult.fail(&model_violation, null);
        self.consumer_digest = support.foldDigest(self.consumer_digest, live_value);
        return self.validate();
    }

    fn xorJump(self: *@This()) checker.CheckResult {
        if (!self.xor_parent.active()) return self.validate();
        self.xor_parent.live.?.jump();
        self.xor_parent.reference.?.jump();
        return self.validate();
    }

    fn xorSplit(self: *@This()) checker.CheckResult {
        if (!self.xor_parent.active()) return self.validate();
        self.xor_child.live = self.xor_parent.live.?.split();
        self.xor_child.reference = self.xor_parent.reference.?.split();
        std.debug.assert(self.xor_child.active());
        std.debug.assert(self.xor_parent.active());
        return self.validate();
    }

    fn sampleUintBelow(self: *@This(), action_value: u64, use_child: bool) checker.CheckResult {
        const slot = self.selectPcgSlot(use_child);
        if (!slot.active()) return self.validate();
        const bound = support.boundFrom(action_value);
        const live_value = static_rng.distributions.uintBelow(&slot.live.?, bound) catch return checker.CheckResult.fail(&model_violation, null);
        const ref_value = static_rng.distributions.uintBelow(&slot.reference.?, bound) catch return checker.CheckResult.fail(&model_violation, null);
        if (live_value != ref_value) return checker.CheckResult.fail(&model_violation, null);
        self.consumer_digest = support.foldDigest(self.consumer_digest, live_value);
        return self.validate();
    }

    fn shuffleSlice(self: *@This(), action_value: u64) checker.CheckResult {
        _ = action_value;
        const slot = self.selectPcgSlot(false);
        if (!slot.active()) return self.validate();

        var live_values: [support.shuffle_len]u32 = undefined;
        var ref_values: [support.shuffle_len]u32 = undefined;
        support.fillShuffleValues(live_values[0..]);
        support.fillShuffleValues(ref_values[0..]);
        support.shuffleSlice(&slot.live.?, live_values[0..]) catch return checker.CheckResult.fail(&model_violation, null);
        support.shuffleSlice(&slot.reference.?, ref_values[0..]) catch return checker.CheckResult.fail(&model_violation, null);
        if (!std.mem.eql(u32, live_values[0..], ref_values[0..])) return checker.CheckResult.fail(&model_violation, null);

        for (live_values) |value| {
            self.consumer_digest = support.foldDigest(self.consumer_digest, value);
        }
        return self.validate();
    }

    fn selectPcgSlot(self: *@This(), use_child: bool) *PcgSlot {
        if (use_child and self.pcg_child.active()) return &self.pcg_child;
        return &self.pcg_parent;
    }

    fn selectXorSlot(self: *@This(), use_child: bool) *XorSlot {
        if (use_child and self.xor_child.active()) return &self.xor_child;
        return &self.xor_parent;
    }
};

test "static_rng stream lineage stays aligned with testing.model" {
    const Runner = model.ModelRunner(error{});
    const Target = model.ModelTarget(error{});

    var context = Context{};
    context.resetState();

    var action_storage: [64]model.RecordedAction = undefined;
    var reduction_scratch: [64]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_rng",
            .run_name = "model_stream_lineage",
            .base_seed = .init(0x5354_4154_4953_5455),
            .build_mode = .debug,
            .case_count_max = 64,
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

    try std.testing.expectEqual(@as(u32, 64), summary.executed_case_count);
    try std.testing.expect(summary.failed_case == null);
}

fn nextAction(
    _: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action_seed: seed_mod.Seed,
) error{}!model.RecordedAction {
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x5354_4154_454e_5452);
    const random = prng.random();
    const value = random.int(u64);
    const tag: ActionTag = switch (random.uintLessThan(u32, 12)) {
        0 => .init_pcg_parent,
        1 => .pcg_next_u32,
        2 => .sample_uint_below,
        3 => .pcg_next_u64,
        4 => .pcg_split,
        5 => .pcg_child_next_u32,
        6 => .shuffle_slice,
        7 => .init_xor_parent,
        8 => .xor_next_u64,
        9 => .xor_jump,
        10 => .xor_split,
        else => .xor_child_next_u64,
    };
    return .{
        .tag = @intFromEnum(tag),
        .value = value,
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
        .init_pcg_parent => context.initPcgParent(action.value),
        .pcg_next_u32 => context.pcgNextU32((action.value & 1) == 1),
        .sample_uint_below => context.sampleUintBelow(action.value, (action.value & 1) == 1),
        .pcg_next_u64 => context.pcgNextU64((action.value & 1) == 1),
        .pcg_split => context.pcgSplit(),
        .pcg_child_next_u32 => context.pcgNextU32(true),
        .shuffle_slice => context.shuffleSlice(action.value),
        .init_xor_parent => context.initXorParent(action.value),
        .xor_next_u64 => context.xorNextU64((action.value & 1) == 1),
        .xor_jump => context.xorJump(),
        .xor_split => context.xorSplit(),
        .xor_child_next_u64 => context.xorNextU64(true),
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
            .init_pcg_parent => "init_pcg_parent",
            .pcg_next_u32 => "pcg_next_u32",
            .sample_uint_below => "sample_uint_below",
            .pcg_next_u64 => "pcg_next_u64",
            .pcg_split => "pcg_split",
            .pcg_child_next_u32 => "pcg_child_next_u32",
            .shuffle_slice => "shuffle_slice",
            .init_xor_parent => "init_xor_parent",
            .xor_next_u64 => "xor_next_u64",
            .xor_jump => "xor_jump",
            .xor_split => "xor_split",
            .xor_child_next_u64 => "xor_child_next_u64",
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
