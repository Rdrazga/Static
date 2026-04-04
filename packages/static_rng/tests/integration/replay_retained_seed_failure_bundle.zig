const std = @import("std");
const static_rng = @import("static_rng");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const failure_bundle = static_testing.testing.failure_bundle;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;
const support = @import("support.zig");

const failure_violation = [_]checker.Violation{
    .{
        .code = "static_rng.retained_seed_failure_bundle",
        .message = "retained seed replay and failure bundle persistence regressed",
    },
};

const ActionTag = enum(u32) {
    init_pcg = 1,
    pcg_next_u32 = 2,
    sample_uint_below = 3,
    retained_failure = 4,
};

const Context = struct {
    live: ?static_rng.Pcg32 = null,
    reference: ?support.ReferencePcg32 = null,
    consumer_digest: u64 = 0,

    fn resetState(self: *@This()) void {
        self.live = null;
        self.reference = null;
        self.consumer_digest = 0;
        std.debug.assert(self.live == null);
        std.debug.assert(self.reference == null);
    }

    fn validate(self: *@This()) checker.CheckResult {
        var digest = self.consumer_digest;
        if (!self.aligned()) return checker.CheckResult.fail(&failure_violation, checker.CheckpointDigest.init(digest));
        if (self.live) |live| {
            digest = foldDigest(digest, live.state);
            digest = foldDigest(digest, live.inc);
        }
        std.debug.assert(digest != 0 or self.consumer_digest == 0);
        std.debug.assert(self.consumer_digest == 0 or digest != 0);
        return checker.CheckResult.pass(checker.CheckpointDigest.init(digest));
    }

    fn aligned(self: *@This()) bool {
        if (self.live == null and self.reference == null) return true;
        if (self.live == null or self.reference == null) return false;
        const live = self.live.?;
        const reference = self.reference.?;
        return live.state == reference.state and live.inc == reference.inc;
    }

    fn initPcg(self: *@This(), action_value: u64) checker.CheckResult {
        const seed = support.seedFrom(action_value, 0x5254_4149_4e5f_5345);
        const sequence = support.sequenceFrom(action_value, 0x5254_4149_4e5f_5341);
        self.live = static_rng.Pcg32.init(seed, sequence);
        self.reference = support.ReferencePcg32.init(seed, sequence);
        std.debug.assert(self.aligned());
        std.debug.assert(self.live.?.inc == self.reference.?.inc);
        return self.validate();
    }

    fn pcgNext(self: *@This()) checker.CheckResult {
        if (self.live == null or self.reference == null) return checker.CheckResult.fail(&failure_violation, null);
        if (!self.aligned()) return checker.CheckResult.fail(&failure_violation, null);
        var live = self.live.?;
        var reference = self.reference.?;
        const live_value = live.nextU32();
        const reference_value = reference.nextU32();
        self.live = live;
        self.reference = reference;
        if (live_value != reference_value) return checker.CheckResult.fail(&failure_violation, null);
        self.consumer_digest = foldDigest(self.consumer_digest, live_value);
        return self.validate();
    }

    fn sampleBelow(self: *@This(), action_value: u64) checker.CheckResult {
        if (self.live == null or self.reference == null) return checker.CheckResult.fail(&failure_violation, null);
        if (!self.aligned()) return checker.CheckResult.fail(&failure_violation, null);
        const bound = support.boundFrom(action_value);
        var live = self.live.?;
        var reference = self.reference.?;
        const live_value = static_rng.distributions.uintBelow(&live, bound) catch return checker.CheckResult.fail(&failure_violation, null);
        const reference_value = static_rng.distributions.uintBelow(&reference, bound) catch return checker.CheckResult.fail(&failure_violation, null);
        self.live = live;
        self.reference = reference;
        if (live_value != reference_value) return checker.CheckResult.fail(&failure_violation, null);
        self.consumer_digest = foldDigest(self.consumer_digest, live_value);
        return self.validate();
    }

    fn retainedFailure(self: *@This(), action_value: u64) checker.CheckResult {
        const digest = foldDigest(self.consumer_digest, action_value);
        std.debug.assert(digest != 0 or action_value == 0);
        return checker.CheckResult.fail(&failure_violation, checker.CheckpointDigest.init(digest));
    }
};

fn foldDigest(digest: u64, value: u64) u64 {
    const next = support.mix64(digest ^ value);
    std.debug.assert(next != digest or value == 0);
    std.debug.assert(next == support.mix64(digest ^ value));
    return next;
}

test "static_rng retained seed replay and failure bundle stay aligned" {
    const Runner = model.ModelRunner(error{});
    const Target = model.ModelTarget(error{});

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var bundle_entry_name_buffer: [128]u8 = undefined;
    var bundle_artifact_buffer: [512]u8 = undefined;
    var bundle_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var bundle_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var bundle_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var action_bytes_buffer: [512]u8 = undefined;
    var action_document_buffer: [4096]u8 = undefined;
    var action_document_entries: [4]model.RecordedActionDocumentEntry = undefined;

    var context = Context{};
    context.resetState();

    var action_storage: [4]model.RecordedAction = undefined;
    var reduction_scratch: [4]model.RecordedAction = undefined;

    const summary = try (Runner{
        .config = .{
            .package_name = "static_rng",
            .run_name = "retained_seed_failure_bundle",
            .base_seed = .init(0x5254_4149_4e5f_5345),
            .build_mode = .debug,
            .case_count_max = 1,
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
        .persistence = .{
            .failure_bundle = .{
                .io = io,
                .dir = tmp_dir.dir,
                .naming = .{ .prefix = "static_rng_retained_seed" },
                .entry_name_buffer = &bundle_entry_name_buffer,
                .artifact_buffer = &bundle_artifact_buffer,
                .manifest_buffer = &bundle_manifest_buffer,
                .trace_buffer = &bundle_trace_buffer,
                .violations_buffer = &bundle_violations_buffer,
            },
            .action_bytes_buffer = &action_bytes_buffer,
            .action_document_buffer = &action_document_buffer,
            .action_document_entries = &action_document_entries,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    }).run();

    try std.testing.expectEqual(@as(u32, 1), summary.executed_case_count);
    try std.testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try std.testing.expect(failed_case.persisted_entry_name != null);

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

    try std.testing.expectEqualStrings("static_rng", bundle.manifest_document.package_name);
    try std.testing.expectEqualStrings("retained_seed_failure_bundle", bundle.manifest_document.run_name);
    try std.testing.expectEqual(failed_case.run_identity.seed.value, bundle.replay_artifact_view.identity.seed.value);
    try std.testing.expect(bundle.trace_document != null);
    try std.testing.expectEqualStrings(failure_violation[0].code, bundle.violations_document.violations[0].code);

    var read_action_bytes_buffer: [512]u8 = undefined;
    var read_action_storage: [4]model.RecordedAction = undefined;
    var read_action_document_source_buffer: [4096]u8 = undefined;
    var read_action_document_parse_buffer: [4096]u8 = undefined;
    const recorded_actions = try model.readRecordedActions(io, tmp_dir.dir, failed_case.persisted_entry_name.?, .{
        .actions_buffer = &read_action_storage,
        .action_bytes_buffer = &read_action_bytes_buffer,
        .action_document_source_buffer = &read_action_document_source_buffer,
        .action_document_parse_buffer = &read_action_document_parse_buffer,
    });

    try std.testing.expectEqual(failed_case.recorded_actions.len, recorded_actions.actions.len);
    try std.testing.expect(recorded_actions.action_document != null);
    try std.testing.expectEqual(@as(u32, @intCast(recorded_actions.actions.len)), recorded_actions.action_document.?.action_count);
    try std.testing.expectEqualStrings("retained_failure", recorded_actions.action_document.?.actions[recorded_actions.actions.len - 1].label);
    const replay = try model.replayRecordedActions(error{}, Target{
        .context = &context,
        .reset_fn = reset,
        .next_action_fn = nextAction,
        .step_fn = step,
        .finish_fn = finish,
        .describe_action_fn = describe,
    }, failed_case.run_identity, recorded_actions.actions);

    try std.testing.expect(!replay.check_result.passed);
    try std.testing.expectEqual(failed_case.failing_action_index, replay.failing_action_index);
    try std.testing.expectEqual(failed_case.trace_metadata.event_count, replay.trace_metadata.event_count);
}

fn nextAction(
    _: *anyopaque,
    _: identity.RunIdentity,
    action_index: u32,
    action_seed: seed_mod.Seed,
) error{}!model.RecordedAction {
    const schedule = action_index % 4;
    const value = support.mix64(action_seed.value ^ @as(u64, action_index) ^ 0x5254_4149_4e54_5345);
    const tag: ActionTag = switch (schedule) {
        0 => .init_pcg,
        1 => .pcg_next_u32,
        2 => .sample_uint_below,
        else => .retained_failure,
    };
    return .{ .tag = @intFromEnum(tag), .value = value };
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
        .init_pcg => context.initPcg(action.value),
        .pcg_next_u32 => context.pcgNext(),
        .sample_uint_below => context.sampleBelow(action.value),
        .retained_failure => context.retainedFailure(action.value),
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
            .init_pcg => "init_pcg",
            .pcg_next_u32 => "pcg_next_u32",
            .sample_uint_below => "sample_uint_below",
            .retained_failure => "retained_failure",
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
