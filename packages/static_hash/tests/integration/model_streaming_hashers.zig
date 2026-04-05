const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const hash = @import("static_hash");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;

const ActionTag = enum(u32) {
    update_chunk = 1,
    finalize_streams = 2,
    verify_finalized = 3,
};

const action_count_max: usize = 16;
const payload_max_len: usize = 192;

const streaming_model_violation = [_]checker.Violation{
    .{
        .code = "static_hash.model_streaming_hashers",
        .message = "streaming hasher init/update/final sequence diverged from the bounded reference model",
    },
};

const Context = struct {
    payload: [payload_max_len]u8 = undefined,
    payload_len: usize = 0,
    cursor: usize = 0,
    finalized: bool = false,
    checkpoint: u128 = 0,
    fnv32_seed: u32 = 0,
    fnv64_seed: u64 = 0,
    wyhash_seed: u64 = 0,
    xxhash_seed: u64 = 0,
    sip_key: hash.siphash.Key = undefined,
    fnv32: hash.fnv1a.Fnv1a32 = undefined,
    fnv64: hash.fnv1a.Fnv1a64 = undefined,
    wyhash: hash.wyhash.Wyhash64 = undefined,
    xxhash: hash.xxhash3.XxHash3 = undefined,
    crc32: hash.crc32.Crc32 = undefined,
    crc32c: hash.crc32.Crc32c = undefined,
    sip64: hash.siphash.SipHasher64_24 = undefined,
    sip128: hash.siphash.SipHasher128_24 = undefined,

    fn resetState(self: *@This(), run_identity: identity.RunIdentity) void {
        const seed_value = run_identity.seed.value;
        self.payload_len = buildPayload(seed_value, self.payload[0..]);
        self.cursor = 0;
        self.finalized = false;
        self.checkpoint = 0;
        self.fnv32_seed = @truncate(mixSeed(seed_value, 0x5348_4152_5f46_4e56));
        self.fnv64_seed = mixSeed(seed_value, 0x5348_4152_5f46_4e57);
        self.wyhash_seed = mixSeed(seed_value, 0x5348_4152_5f57_5959);
        self.xxhash_seed = mixSeed(seed_value, 0x5348_4152_5f58_5858);
        self.sip_key = hash.siphash.keyFromU64s(
            mixSeed(seed_value, 0x5348_4152_5f53_4950),
            ~mixSeed(seed_value, 0x5348_4152_5f53_4950),
        );
        self.fnv32 = hash.fnv1a.Fnv1a32.init(self.fnv32_seed);
        self.fnv64 = hash.fnv1a.Fnv1a64.init(self.fnv64_seed);
        self.wyhash = hash.wyhash.Wyhash64.init(self.wyhash_seed);
        self.xxhash = hash.xxhash3.XxHash3.init(self.xxhash_seed);
        self.crc32 = hash.crc32.Crc32.init();
        self.crc32c = hash.crc32.Crc32c.init();
        self.sip64 = hash.siphash.SipHasher64_24.init(&self.sip_key);
        self.sip128 = hash.siphash.SipHasher128_24.init(&self.sip_key);
        assert(self.payload_len <= payload_max_len);
        assert(self.cursor == 0);
        assert(!self.finalized);
    }

    fn feed(self: *@This(), bytes: []const u8) void {
        assert(!self.finalized);
        assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
        self.fnv32.update(bytes);
        self.fnv64.update(bytes);
        self.wyhash.update(bytes);
        self.xxhash.update(bytes);
        self.crc32.update(bytes);
        self.crc32c.update(bytes);
        self.sip64.update(bytes);
        self.sip128.update(bytes);
    }

    fn updateChunk(
        self: *@This(),
        run_seed: u64,
        action_index: u32,
        action_value: u64,
    ) checker.CheckResult {
        assert(!self.finalized);
        assert(self.cursor <= self.payload_len);
        const remaining = self.payload_len - self.cursor;
        const span = chooseSpan(run_seed, action_index, action_value, remaining);

        if ((action_value & 1) != 0) {
            self.feed(self.payload[self.cursor..self.cursor]);
        }

        if (span > 0) {
            assert(span <= remaining);
            const end = self.cursor + span;
            self.feed(self.payload[self.cursor..end]);
            self.cursor = end;
        } else {
            self.feed(self.payload[self.cursor..self.cursor]);
        }

        assert(self.cursor <= self.payload_len);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(progressCheckpoint(self)));
    }

    fn verifyFinalized(self: *@This()) checker.CheckResult {
        assert(self.finalized);
        assert(self.cursor == self.payload_len);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(self.checkpoint));
    }

    fn finalizeStreams(
        self: *@This(),
        action_value: u64,
    ) checker.CheckResult {
        assert(!self.finalized);
        assert(self.cursor <= self.payload_len);

        if ((action_value & 1) != 0) {
            self.feed(self.payload[self.cursor..self.cursor]);
        }

        if (self.cursor < self.payload_len) {
            const end = self.payload_len;
            self.feed(self.payload[self.cursor..end]);
            self.cursor = end;
        }

        assert(self.cursor == self.payload_len);
        const bytes = self.payload[0..self.payload_len];

        const fnv32_actual = self.fnv32.final();
        const fnv32_expected = hash.fnv1a.hash32(self.fnv32_seed, bytes);
        if (fnv32_actual != fnv32_expected) {
            return failProgress(self);
        }

        const fnv64_actual = self.fnv64.final();
        const fnv64_expected = hash.fnv1a.hash64(self.fnv64_seed, bytes);
        if (fnv64_actual != fnv64_expected) {
            return failProgress(self);
        }

        const wyhash_actual = self.wyhash.final();
        const wyhash_expected = hash.wyhash.hashSeeded(self.wyhash_seed, bytes);
        if (wyhash_actual != wyhash_expected) {
            return failProgress(self);
        }

        const xxhash_actual = self.xxhash.final();
        const xxhash_expected = hash.xxhash3.hash64Seeded(self.xxhash_seed, bytes);
        if (xxhash_actual != xxhash_expected) {
            return failProgress(self);
        }

        const crc32_actual = self.crc32.final();
        const crc32_expected = hash.crc32.checksum(bytes);
        if (crc32_actual != crc32_expected) {
            return failProgress(self);
        }

        const crc32c_actual = self.crc32c.final();
        const crc32c_expected = hash.crc32.checksumCastagnoli(bytes);
        if (crc32c_actual != crc32c_expected) {
            return failProgress(self);
        }

        const sip64_actual = self.sip64.final();
        const sip64_expected = hash.siphash.hash64_24(&self.sip_key, bytes);
        if (sip64_actual != sip64_expected) {
            return failProgress(self);
        }

        const sip128_actual = self.sip128.final();
        const sip128_expected = hash.siphash.hash128_24(&self.sip_key, bytes);
        if (sip128_actual != sip128_expected) {
            return failProgress(self);
        }

        self.finalized = true;
        self.checkpoint = makeCheckpoint(fnv64_actual, sip64_actual);
        assert(self.finalized);
        assert(self.cursor == self.payload_len);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(self.checkpoint));
    }

};

test "static_hash streaming hashers stay aligned with testing.model" {
    const Runner = model.ModelRunner(error{});
    const Target = model.ModelTarget(error{});

    var context = Context{};
    const bootstrap_identity = identity.makeRunIdentity(.{
        .package_name = "static_hash",
        .run_name = "model_streaming_hashers_bootstrap",
        .seed = .init(0),
        .build_mode = .debug,
    });
    context.resetState(bootstrap_identity);

    var action_storage: [action_count_max]model.RecordedAction = undefined;
    var reduction_scratch: [action_count_max]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_hash",
            .run_name = "model_streaming_hashers",
            .base_seed = .init(0x5348_4152_5f53_5452),
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

    try testing.expectEqual(@as(u32, 64), summary.executed_case_count);
    try testing.expect(summary.failed_case == null);
}

fn nextAction(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    action_index: u32,
    action_seed: seed_mod.Seed,
) error{}!model.RecordedAction {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const tag: ActionTag = if (context.finalized) blk: {
        break :blk .verify_finalized;
    } else if (action_index >= 2 and action_index < action_count_max - 1 and (action_seed.value & 3) == 0) blk: {
        break :blk .finalize_streams;
    } else blk: {
        break :blk .update_chunk;
    };
    return .{
        .tag = @intFromEnum(tag),
        .value = action_seed.value,
    };
}

fn step(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
    action_index: u32,
    action: model.RecordedAction,
) error{}!model.ModelStep {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const tag: ActionTag = @enumFromInt(action.tag);
    const result = switch (tag) {
        .update_chunk => context.updateChunk(run_identity.seed.value, action_index, action.value),
        .finalize_streams => context.finalizeStreams(action.value),
        .verify_finalized => context.verifyFinalized(),
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (!context.finalized) {
        return context.finalizeStreams(0);
    }
    assert(context.cursor == context.payload_len);
    return checker.CheckResult.pass(checker.CheckpointDigest.init(context.checkpoint));
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .update_chunk => "update_chunk",
            .finalize_streams => "finalize_streams",
            .verify_finalized => "verify_finalized",
        },
    };
}

fn reset(
    context_ptr: *anyopaque,
    run_identity: identity.RunIdentity,
) error{}!void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.resetState(run_identity);
}

fn failProgress(self: *Context) checker.CheckResult {
    return checker.CheckResult.fail(&streaming_model_violation, checker.CheckpointDigest.init(progressCheckpoint(self)));
}

fn progressCheckpoint(self: *Context) u128 {
    return makeCheckpoint(@as(u64, @intCast(self.cursor)), @as(u64, @intCast(self.payload_len)));
}

fn chooseSpan(
    run_seed: u64,
    action_index: u32,
    action_value: u64,
    remaining: usize,
) usize {
    if (remaining == 0) return 0;
    var prng = std.Random.DefaultPrng.init(
        mixSeed(run_seed, 0x5354_5245_414d_5f53) ^
            action_value ^
            (@as(u64, action_index) *% 0x9e37_79b9_7f4a_7c15),
    );
    const random = prng.random();
    const cap = @min(remaining, @as(usize, 17));
    if ((random.int(u8) & 3) == 0) {
        return 0;
    }
    return 1 + random.uintAtMost(usize, cap - 1);
}

fn buildPayload(seed_value: u64, storage: []u8) usize {
    const lengths = [_]usize{ 0, 1, 3, 7, 8, 15, 16, 31, 32, 47, 48, 63, 64, 95, 96, 127, 128, 159, 160, 191 };
    const len = lengths[@as(usize, @intCast(seed_value % lengths.len))];
    assert(len <= storage.len);
    const bytes = storage[0..len];

    switch (@as(u2, @truncate(seed_value >> 8))) {
        0 => @memset(bytes, 0),
        1 => for (bytes, 0..) |*byte, index| {
            byte.* = @truncate(index);
        },
        else => {
            var prng = std.Random.DefaultPrng.init(seed_value ^ 0x9e37_79b9_7f4a_7c15);
            prng.random().bytes(bytes);
        },
    }

    return len;
}

fn makeCheckpoint(left: u64, right: u64) u128 {
    return (@as(u128, right) << 64) | left;
}

fn mixSeed(seed_value: u64, salt: u64) u64 {
    return seed_value ^ (salt *% 0x9e37_79b9_7f4a_7c15);
}
