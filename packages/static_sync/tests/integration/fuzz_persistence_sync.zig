const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const sync = @import("static_sync");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const corpus = static_testing.testing.corpus;
const failure_bundle = static_testing.testing.failure_bundle;
const fuzz_runner = static_testing.testing.fuzz_runner;
const replay_artifact = static_testing.testing.replay_artifact;
const replay_runner = static_testing.testing.replay_runner;
const seed_mod = static_testing.testing.seed;
const trace = static_testing.testing.trace;

const register_after_cancel_violation = [_]checker.Violation{
    .{
        .code = "static_sync.retained_register_after_cancel",
        .message = "retained cancel registration-after-cancel misuse reproducer",
    },
};

const event_zero_timeout_violation = [_]checker.Violation{
    .{
        .code = "static_sync.retained_event_zero_timeout_pending",
        .message = "retained event zero-timeout pending wait reproducer",
    },
};

const semaphore_zero_timeout_violation = [_]checker.Violation{
    .{
        .code = "static_sync.retained_semaphore_zero_timeout_pending",
        .message = "retained semaphore zero-timeout pending wait reproducer",
    },
};

const wait_queue_zero_timeout_violation = [_]checker.Violation{
    .{
        .code = "static_sync.retained_wait_queue_zero_timeout_pending",
        .message = "retained wait_queue zero-timeout pending wait reproducer",
    },
};

const RetainedTag = enum(u8) {
    register_after_cancel = 0,
    event_zero_timeout_pending = 1,
    semaphore_zero_timeout_pending = 2,
    wait_queue_zero_timeout_pending = 3,
};

const RetainedCase = struct {
    tag: RetainedTag,
    label: []const u8,
    violations: []const checker.Violation,
    digest: u128,
};

const RetainedTargetError = @typeInfo(
    @typeInfo(@TypeOf(assertRetainedCase)).@"fn".return_type.?,
).error_union.error_set;

test "static_sync retained primitive misuse bundle stays replayable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const config = fuzz_runner.FuzzConfig{
        .package_name = "static_sync",
        .run_name = "retained_sync_misuse_bundle",
        .base_seed = .{ .value = 0x571A_71C0_2026_0411 },
        .build_mode = .debug,
        .case_count_max = 8,
        .reduction_budget = .{
            .max_attempts = 64,
            .max_successes = 64,
        },
    };

    const Runner = fuzz_runner.FuzzRunner(RetainedTargetError, RetainedTargetError);
    var reducer_context = ReducerContext{
        .target_tag = retainedTagFromSeed(seed_mod.splitSeed(config.base_seed, 0).value),
    };
    var artifact_buffer: [256]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const summary = try (Runner{
        .config = config,
        .target = .{
            .context = undefined,
            .run_fn = RetainedMisuseTarget.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_sync_retained" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
        .seed_reducer = .{
            .context = &reducer_context,
            .measure_fn = ReducerContext.measure,
            .next_fn = ReducerContext.next,
            .is_interesting_fn = ReducerContext.isInteresting,
        },
    }).run();

    try testing.expectEqual(@as(u32, 1), summary.executed_case_count);
    try testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try testing.expect(failed_case.persisted_entry_name != null);
    if (failed_case.reduced_seed) |reduced_seed| {
        try testing.expectEqual(reduced_seed.value, failed_case.run_identity.seed.value);
    }

    const retained_case = buildRetainedCase(failed_case.run_identity.seed.value);
    try assertRetainedCase(retained_case);

    var corpus_buffer: [256]u8 = undefined;
    const entry = try corpus.readCorpusEntry(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        &corpus_buffer,
    );
    try testing.expectEqual(
        static_testing.testing.identity.identityHash(failed_case.run_identity),
        entry.meta.identity_hash,
    );
    try testing.expectEqual(
        failed_case.run_identity.seed.value,
        entry.artifact.identity.seed.value,
    );

    const replay_outcome = try replay_runner.runReplay(
        RetainedTargetError,
        corpus_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))],
        .{
            .context = undefined,
            .run_fn = RetainedMisuseTarget.replay,
        },
        .{
            .expected_identity_hash = entry.meta.identity_hash,
        },
    );
    try testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, replay_outcome);

    var bundle_entry_name_buffer: [128]u8 = undefined;
    var bundle_artifact_buffer: [512]u8 = undefined;
    var bundle_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var bundle_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var bundle_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    const bundle_meta = try failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "static_sync_bundle" },
        .entry_name_buffer = &bundle_entry_name_buffer,
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &bundle_manifest_buffer,
        .trace_buffer = &bundle_trace_buffer,
        .violations_buffer = &bundle_violations_buffer,
    }, failed_case.run_identity, failed_case.trace_metadata, failed_case.check_result, .{
        .campaign_profile = "retained_misuse",
        .scenario_variant_label = retained_case.label,
    });

    var read_manifest_source: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_source: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const bundle = try failure_bundle.readFailureBundle(io, tmp_dir.dir, bundle_meta.entry_name, .{
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try testing.expectEqualStrings("static_sync", bundle.manifest_document.package_name);
    try testing.expectEqualStrings("retained_sync_misuse_bundle", bundle.manifest_document.run_name);
    try testing.expectEqualStrings(retained_case.label, bundle.manifest_document.scenario_variant_label.?);
    try testing.expectEqual(
        failed_case.run_identity.seed.value,
        bundle.replay_artifact_view.identity.seed.value,
    );
    try testing.expect(bundle.trace_document != null);
    try testing.expectEqualStrings(
        retained_case.violations[0].code,
        bundle.violations_document.violations[0].code,
    );
}

const RetainedMisuseTarget = struct {
    fn run(
        _: *const anyopaque,
        run_identity: static_testing.testing.identity.RunIdentity,
    ) RetainedTargetError!fuzz_runner.FuzzExecution {
        const retained_case = buildRetainedCase(run_identity.seed.value);
        try assertRetainedCase(retained_case);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity, retained_case.digest),
            .check_result = checker.CheckResult.fail(
                retained_case.violations,
                checker.CheckpointDigest.init(retained_case.digest),
            ),
        };
    }

    fn replay(
        _: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) RetainedTargetError!replay_runner.ReplayExecution {
        const retained_case = buildRetainedCase(artifact.identity.seed.value);
        try assertRetainedCase(retained_case);
        return .{
            .trace_metadata = makeTraceMetadata(artifact.identity, retained_case.digest),
            .check_result = checker.CheckResult.fail(
                retained_case.violations,
                checker.CheckpointDigest.init(retained_case.digest),
            ),
        };
    }
};

const ReducerContext = struct {
    target_tag: RetainedTag,

    fn measure(_: *const anyopaque, candidate: static_testing.testing.seed.Seed) u64 {
        return candidate.value;
    }

    fn next(
        _: *const anyopaque,
        current: static_testing.testing.seed.Seed,
        _: u32,
    ) RetainedTargetError!?static_testing.testing.seed.Seed {
        if (current.value <= 1) return null;
        return static_testing.testing.seed.Seed.init(@divFloor(current.value, 2));
    }

    fn isInteresting(
        context_ptr: *const anyopaque,
        candidate: static_testing.testing.seed.Seed,
    ) RetainedTargetError!bool {
        const context: *const ReducerContext = @ptrCast(@alignCast(context_ptr));
        const retained_case = buildRetainedCase(candidate.value);
        try assertRetainedCase(retained_case);
        return retained_case.tag == context.target_tag;
    }
};

fn buildRetainedCase(seed_value: u64) RetainedCase {
    const tag = retainedTagFromSeed(seed_value);
    const label = switch (tag) {
        .register_after_cancel => "register_after_cancel",
        .event_zero_timeout_pending => "event_zero_timeout_pending",
        .semaphore_zero_timeout_pending => "semaphore_zero_timeout_pending",
        .wait_queue_zero_timeout_pending => "wait_queue_zero_timeout_pending",
    };
    const violations = switch (tag) {
        .register_after_cancel => &register_after_cancel_violation,
        .event_zero_timeout_pending => &event_zero_timeout_violation,
        .semaphore_zero_timeout_pending => &semaphore_zero_timeout_violation,
        .wait_queue_zero_timeout_pending => &wait_queue_zero_timeout_violation,
    };
    return .{
        .tag = tag,
        .label = label,
        .violations = violations,
        .digest = retainedDigest(seed_value, @intFromEnum(tag)),
    };
}

fn retainedTagFromSeed(seed_value: u64) RetainedTag {
    if (sync.wait_queue.supports_wait_queue) {
        return switch (seed_value % 4) {
            0 => .register_after_cancel,
            1 => .event_zero_timeout_pending,
            2 => .semaphore_zero_timeout_pending,
            else => .wait_queue_zero_timeout_pending,
        };
    }
    return switch (seed_value % 3) {
        0 => .register_after_cancel,
        1 => .event_zero_timeout_pending,
        else => .semaphore_zero_timeout_pending,
    };
}

fn assertRetainedCase(retained_case: RetainedCase) !void {
    switch (retained_case.tag) {
        .register_after_cancel => {
            var source = sync.cancel.CancelSource{};
            source.cancel();
            const token = source.token();

            var callback_count = std.atomic.Value(u32).init(0);
            var registration = sync.cancel.CancelRegistration.init(wakeCounter, &callback_count);
            try testing.expectError(error.Cancelled, registration.register(token));
            try testing.expectEqual(@as(u32, 0), callback_count.load(.acquire));
            try testing.expect(token.isCancelled());
        },
        .event_zero_timeout_pending => {
            if (!@hasDecl(sync.event.Event, "timedWait")) return error.SkipZigTest;
            var event = sync.event.Event{};
            try testing.expectError(error.Timeout, event.timedWait(0));
            event.set();
            try event.timedWait(0);
        },
        .semaphore_zero_timeout_pending => {
            if (!@hasDecl(sync.semaphore.Semaphore, "timedWait")) return error.SkipZigTest;
            var semaphore = sync.semaphore.Semaphore{};
            try testing.expectError(error.Timeout, semaphore.timedWait(0));
            semaphore.post(1);
            try semaphore.timedWait(0);
            try testing.expectError(error.WouldBlock, semaphore.tryWait());
        },
        .wait_queue_zero_timeout_pending => {
            if (!sync.wait_queue.supports_wait_queue) return error.SkipZigTest;
            var state: u32 = 0;
            try testing.expectError(error.Timeout, sync.wait_queue.waitValue(u32, &state, 0, .{
                .timeout_ns = 0,
            }));
            @atomicStore(u32, &state, 1, .release);
            try sync.wait_queue.waitValue(u32, &state, 0, .{
                .timeout_ns = 0,
            });
        },
    }
}

fn makeTraceMetadata(
    run_identity: static_testing.testing.identity.RunIdentity,
    digest: u128,
) trace.TraceMetadata {
    const timestamp_ns = run_identity.seed.value ^ @as(u64, @truncate(digest));
    return .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = run_identity.case_index,
        .last_sequence_no = run_identity.case_index,
        .first_timestamp_ns = timestamp_ns,
        .last_timestamp_ns = timestamp_ns,
    };
}

fn retainedDigest(seed_value: u64, tag_value: u8) u128 {
    return (@as(u128, mix64(seed_value ^ @as(u64, tag_value))) << 64) |
        @as(u128, mix64(seed_value ^ 0x571A_71C0_2026_0411));
}

fn mix64(value: u64) u64 {
    var mixed = value ^ (value >> 33);
    mixed *%= 0xff51_afd7_ed55_8ccd;
    mixed ^= mixed >> 33;
    mixed *%= 0xc4ce_b9fe_1a85_ec53;
    mixed ^= mixed >> 33;
    return mixed;
}

fn wakeCounter(ctx: ?*anyopaque) void {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = counter.fetchAdd(1, .acq_rel);
}
