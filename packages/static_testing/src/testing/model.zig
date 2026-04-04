//! Deterministic sequential state-machine harness with recorded-action replay.
//!
//! The harness is intentionally narrow:
//! - one run produces one bounded recorded action trace;
//! - failures are minimized by removing contiguous action chunks;
//! - persisted traces live beside the existing failure bundle artifacts; and
//! - callers define action generation, state reset, action application, and
//!   human-readable action descriptions.

const std = @import("std");
const core = @import("static_core");
const serial = @import("static_serial");
const artifact = @import("../artifact/root.zig");
const checker = @import("checker.zig");
const failure_bundle = @import("failure_bundle.zig");
const identity = @import("identity.zig");
const reducer = @import("reducer.zig");
const seed_mod = @import("seed.zig");
const trace = @import("trace.zig");

pub const recorded_actions_magic = [_]u8{ 'S', 'T', 'T', 'M', 'O', 'D', 'L', '1' };
pub const actions_bin_file_name = "actions.bin";
pub const actions_zon_file_name = "actions.zon";
pub const actions_format_version: u16 = 1;

/// Recorded action shape used for deterministic replay and persistence.
pub const RecordedAction = struct {
    tag: u32,
    value: u64 = 0,
};

/// Human-readable description for one recorded action.
pub const ActionDescriptor = struct {
    label: []const u8,
};

/// Harness configuration for one deterministic model session.
pub const ModelConfig = struct {
    package_name: []const u8,
    run_name: []const u8,
    base_seed: seed_mod.Seed,
    build_mode: identity.BuildMode,
    case_count_max: u32,
    action_count_max: u32,
    reduction_budget: reducer.ReductionBudget = .{
        .max_attempts = 64,
        .max_successes = 64,
    },
};

/// One post-action result emitted by the caller model.
pub const ModelStep = struct {
    check_result: checker.CheckResult,
    stop_after_step: bool = false,
};

/// Replay result over one explicit recorded-action trace.
pub const ModelReplayExecution = struct {
    trace_metadata: trace.TraceMetadata,
    trace_provenance_summary: ?trace.TraceProvenanceSummary = null,
    retained_trace_snapshot: ?trace.TraceSnapshot = null,
    check_result: checker.CheckResult,
    executed_action_count: u32,
    failing_action_index: ?u32,
};

/// One failed model case, optionally reduced and optionally persisted.
pub const ModelCaseResult = struct {
    run_identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
    trace_provenance_summary: ?trace.TraceProvenanceSummary = null,
    check_result: checker.CheckResult,
    recorded_actions: []const RecordedAction,
    original_action_count: u32,
    failing_action_index: ?u32,
    reduction_attempts_total: u32,
    reduction_successes_total: u32,
    persisted_entry_name: ?[]const u8 = null,
};

/// Aggregate result for one deterministic model session.
pub const ModelRunSummary = struct {
    executed_case_count: u32,
    failed_case: ?ModelCaseResult,
};

pub fn formatFailedCaseSummary(
    comptime TargetError: type,
    buffer: []u8,
    target: ModelTarget(TargetError),
    failed_case: ModelCaseResult,
) ModelRunError![]const u8 {
    assertFailedCaseSummaryInput(failed_case);
    if (buffer.len == 0) return error.NoSpaceLeft;

    var writer = SummaryWriter.init(buffer);
    try writer.print(
        "model failure run={s} case_index={d} run_index={d} seed={s}\n",
        .{
            failed_case.run_identity.run_name,
            failed_case.run_identity.case_index,
            failed_case.run_identity.run_index,
            seed_mod.formatSeed(failed_case.run_identity.seed),
        },
    );
    try writer.print(
        "reduced_actions={d} original_actions={d} trace_events={d}",
        .{
            failed_case.recorded_actions.len,
            failed_case.original_action_count,
            failed_case.trace_metadata.event_count,
        },
    );
    if (failed_case.failing_action_index) |failing_action_index| {
        try writer.print(" first_bad_action={d}", .{failing_action_index});
    } else {
        try writer.writeAll(" first_bad_action=finish");
    }
    if (failed_case.persisted_entry_name) |persisted_entry_name| {
        try writer.print(" persisted={s}", .{persisted_entry_name});
    }
    try writer.print(
        " reductions={d}/{d}\n",
        .{
            failed_case.reduction_successes_total,
            failed_case.reduction_attempts_total,
        },
    );

    if (failed_case.check_result.violations.len != 0) {
        try writer.writeAll("violations:");
        for (failed_case.check_result.violations) |violation| {
            try writer.print(" {s}", .{violation.code});
        }
        try writer.writeAll("\n");
    }

    for (failed_case.recorded_actions, 0..) |action, index| {
        const descriptor = target.describeAction(action);
        std.debug.assert(descriptor.label.len != 0);
        if (failed_case.failing_action_index != null and index == failed_case.failing_action_index.?) {
            try writer.writeAll(">> ");
        } else {
            try writer.writeAll("   ");
        }
        try writer.print(
            "action[{d}] tag={d} value={d} label={s}\n",
            .{ index, action.tag, action.value, descriptor.label },
        );
    }

    return writer.finish();
}

pub const RecordedActionDocumentArtifact = enum(u8) {
    none = 0,
    zon = 1,
};

pub const ModelArtifactSelection = struct {
    action_document_artifact: RecordedActionDocumentArtifact = .zon,
};

pub const RecordedActionDocumentEntry = struct {
    index: u32,
    tag: u32,
    value: u64,
    label: []const u8,
};

pub const RecordedActionDocument = struct {
    action_count: u32,
    actions: []const RecordedActionDocumentEntry,
};

/// Persistence hooks for failing model traces.
pub const ModelPersistence = struct {
    failure_bundle: failure_bundle.FailureBundlePersistence,
    failure_bundle_context: failure_bundle.FailureBundleContext = .{},
    artifact_selection: ModelArtifactSelection = .{},
    action_bytes_buffer: []u8,
    action_document_buffer: []u8 = &.{},
    action_document_entries: []RecordedActionDocumentEntry = &.{},
};

/// Read buffers for persisted recorded-action traces.
pub const RecordedActionReadBuffers = struct {
    actions_buffer: []RecordedAction,
    action_bytes_buffer: []u8,
    action_document_source_buffer: []u8 = &.{},
    action_document_parse_buffer: []u8 = &.{},
};

/// Read-only view over one persisted recorded-action trace.
pub const RecordedActionView = struct {
    actions: []const RecordedAction,
    action_document: ?RecordedActionDocument,
};

pub const ModelRunError = error{
    InvalidInput,
    NoSpaceLeft,
    Overflow,
    CorruptData,
    Unsupported,
    EndOfStream,
};

pub fn ModelTarget(comptime TargetError: type) type {
    return struct {
        context: *anyopaque,
        reset_fn: *const fn (
            context: *anyopaque,
            run_identity: identity.RunIdentity,
        ) TargetError!void,
        next_action_fn: *const fn (
            context: *anyopaque,
            run_identity: identity.RunIdentity,
            action_index: u32,
            action_seed: seed_mod.Seed,
        ) TargetError!RecordedAction,
        step_fn: *const fn (
            context: *anyopaque,
            run_identity: identity.RunIdentity,
            action_index: u32,
            action: RecordedAction,
        ) TargetError!ModelStep,
        finish_fn: *const fn (
            context: *anyopaque,
            run_identity: identity.RunIdentity,
            executed_action_count: u32,
        ) TargetError!checker.CheckResult,
        describe_action_fn: *const fn (
            context: *anyopaque,
            action: RecordedAction,
        ) ActionDescriptor,
        trace_snapshot_fn: ?*const fn (
            context: *anyopaque,
        ) ?trace.TraceSnapshot = null,
        trace_metadata_fn: ?*const fn (
            context: *anyopaque,
        ) ?trace.TraceMetadata = null,

        pub fn reset(
            self: @This(),
            run_identity: identity.RunIdentity,
        ) TargetError!void {
            return self.reset_fn(self.context, run_identity);
        }

        pub fn nextAction(
            self: @This(),
            run_identity: identity.RunIdentity,
            action_index: u32,
            action_seed: seed_mod.Seed,
        ) TargetError!RecordedAction {
            return self.next_action_fn(self.context, run_identity, action_index, action_seed);
        }

        pub fn step(
            self: @This(),
            run_identity: identity.RunIdentity,
            action_index: u32,
            action: RecordedAction,
        ) TargetError!ModelStep {
            return self.step_fn(self.context, run_identity, action_index, action);
        }

        pub fn finish(
            self: @This(),
            run_identity: identity.RunIdentity,
            executed_action_count: u32,
        ) TargetError!checker.CheckResult {
            return self.finish_fn(self.context, run_identity, executed_action_count);
        }

        pub fn describeAction(
            self: @This(),
            action: RecordedAction,
        ) ActionDescriptor {
            return self.describe_action_fn(self.context, action);
        }

        pub fn traceSnapshot(self: @This()) ?trace.TraceSnapshot {
            if (self.trace_snapshot_fn) |trace_snapshot_fn| {
                return trace_snapshot_fn(self.context);
            }
            return null;
        }

        pub fn traceMetadata(self: @This()) ?trace.TraceMetadata {
            if (self.trace_metadata_fn) |trace_metadata_fn| {
                return trace_metadata_fn(self.context);
            }
            return null;
        }
    };
}

pub fn ModelRunner(comptime TargetError: type) type {
    return struct {
        config: ModelConfig,
        target: ModelTarget(TargetError),
        persistence: ?ModelPersistence = null,
        action_storage: []RecordedAction,
        reduction_scratch: []RecordedAction,

        pub fn run(
            self: @This(),
        ) (ModelRunError || failure_bundle.FailureBundleWriteError || TargetError)!ModelRunSummary {
            return runModelCases(TargetError, self);
        }
    };
}

comptime {
    core.errors.assertVocabularySubset(ModelRunError);
    std.debug.assert(actions_format_version == 1);
}

pub fn runModelCases(
    comptime TargetError: type,
    runner: ModelRunner(TargetError),
) (ModelRunError || failure_bundle.FailureBundleWriteError || TargetError)!ModelRunSummary {
    try validateRunnerConfig(runner.config, runner.action_storage, runner.reduction_scratch);

    var executed_case_count: u32 = 0;
    var case_index: u32 = 0;
    while (case_index < runner.config.case_count_max) : (case_index += 1) {
        const case_seed = seed_mod.splitSeed(runner.config.base_seed, case_index);
        const run_identity = makeCaseIdentity(runner.config, case_index, case_seed);
        const initial_execution = try generateAndRunRecordedActions(
            TargetError,
            runner.target,
            run_identity,
            runner.config.action_count_max,
            runner.action_storage,
        );
        executed_case_count += 1;

        if (!initial_execution.check_result.passed) {
            const minimized = try minimizeFailure(
                TargetError,
                runner.target,
                run_identity,
                runner.action_storage,
                runner.reduction_scratch,
                initial_execution.executed_action_count,
                runner.config.reduction_budget,
            );
            const final_actions = runner.action_storage[0..minimized.action_count];
            const persisted_entry_name = try persistFailure(
                TargetError,
                runner.persistence,
                runner.target,
                run_identity,
                minimized.execution,
                final_actions,
            );
            return .{
                .executed_case_count = executed_case_count,
                .failed_case = .{
                    .run_identity = run_identity,
                    .trace_metadata = minimized.execution.trace_metadata,
                    .trace_provenance_summary = minimized.execution.trace_provenance_summary,
                    .check_result = minimized.execution.check_result,
                    .recorded_actions = final_actions,
                    .original_action_count = initial_execution.executed_action_count,
                    .failing_action_index = minimized.execution.failing_action_index,
                    .reduction_attempts_total = minimized.attempts_total,
                    .reduction_successes_total = minimized.successes_total,
                    .persisted_entry_name = persisted_entry_name,
                },
            };
        }
    }

    return .{
        .executed_case_count = executed_case_count,
        .failed_case = null,
    };
}

pub fn replayRecordedActions(
    comptime TargetError: type,
    target: ModelTarget(TargetError),
    run_identity: identity.RunIdentity,
    actions: []const RecordedAction,
) TargetError!ModelReplayExecution {
    try target.reset(run_identity);

    var action_index: u32 = 0;
    while (action_index < actions.len) : (action_index += 1) {
        const step = try target.step(run_identity, action_index, actions[action_index]);
        assertCheckResult(step.check_result);
        if (!step.check_result.passed) {
            const trace_capture = deriveTraceCapture(TargetError, target, action_index + 1);
            return .{
                .trace_metadata = trace_capture.metadata,
                .trace_provenance_summary = trace_capture.provenance_summary,
                .retained_trace_snapshot = trace_capture.retained_trace_snapshot,
                .check_result = step.check_result,
                .executed_action_count = action_index + 1,
                .failing_action_index = action_index,
            };
        }
        if (step.stop_after_step) {
            break;
        }
    }

    const executed_action_count = if (actions.len == 0) 0 else action_index + 0;
    const finish_result = try target.finish(run_identity, executed_action_count);
    assertCheckResult(finish_result);
    const trace_capture = deriveTraceCapture(TargetError, target, executed_action_count);
    return .{
        .trace_metadata = trace_capture.metadata,
        .trace_provenance_summary = trace_capture.provenance_summary,
        .retained_trace_snapshot = trace_capture.retained_trace_snapshot,
        .check_result = finish_result,
        .executed_action_count = executed_action_count,
        .failing_action_index = null,
    };
}

pub fn readRecordedActions(
    io: std.Io,
    dir: std.Io.Dir,
    entry_name: []const u8,
    buffers: RecordedActionReadBuffers,
) (ModelRunError || std.Io.Dir.OpenError || std.Io.Dir.ReadFileError)!RecordedActionView {
    if (entry_name.len == 0) return error.InvalidInput;
    try validateReadBuffers(buffers);

    var bundle_dir = try dir.openDir(io, entry_name, .{});
    defer bundle_dir.close(io);

    const action_bytes = try bundle_dir.readFile(io, actions_bin_file_name, buffers.action_bytes_buffer);
    const actions = try decodeRecordedActions(action_bytes, buffers.actions_buffer);
    const action_document = if (shouldReadActionDocument(buffers))
        readActionDocument(io, bundle_dir, buffers) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        }
    else
        null;
    return .{
        .actions = actions,
        .action_document = action_document,
    };
}

pub fn encodeRecordedActions(
    buffer: []u8,
    actions: []const RecordedAction,
) ModelRunError!usize {
    const encoded_len = try encodedActionsLen(actions.len);
    if (buffer.len < encoded_len) return error.NoSpaceLeft;

    var writer = serial.writer.Writer.init(buffer[0..encoded_len]);
    try writeBytes(&writer, &recorded_actions_magic);
    try writeInt(&writer, actions_format_version);
    try writeInt(&writer, @as(u32, @intCast(actions.len)));
    for (actions) |action| {
        try writeInt(&writer, action.tag);
        try writeInt(&writer, action.value);
    }

    std.debug.assert(writer.position() == encoded_len);
    return encoded_len;
}

pub fn decodeRecordedActions(
    bytes: []const u8,
    actions_buffer: []RecordedAction,
) ModelRunError![]const RecordedAction {
    var reader = serial.reader.Reader.init(bytes);
    const magic = reader.readBytes(recorded_actions_magic.len) catch |err| return mapReaderError(err);
    if (!std.mem.eql(u8, magic, &recorded_actions_magic)) return error.CorruptData;

    const version = try readValue(&reader, u16);
    if (version != actions_format_version) return error.Unsupported;
    const action_count = try readValue(&reader, u32);
    if (action_count > actions_buffer.len) return error.NoSpaceLeft;

    const encoded_len = try encodedActionsLen(action_count);
    if (bytes.len != encoded_len) return error.CorruptData;

    var index: usize = 0;
    while (index < action_count) : (index += 1) {
        actions_buffer[index] = .{
            .tag = try readValue(&reader, u32),
            .value = try readValue(&reader, u64),
        };
    }

    if (reader.remaining() != 0) return error.CorruptData;
    return actions_buffer[0..action_count];
}

fn validateRunnerConfig(
    config: ModelConfig,
    action_storage: []RecordedAction,
    reduction_scratch: []RecordedAction,
) ModelRunError!void {
    if (config.package_name.len == 0) return error.InvalidInput;
    if (config.run_name.len == 0) return error.InvalidInput;
    if (config.case_count_max == 0) return error.InvalidInput;
    if (config.action_count_max == 0) return error.InvalidInput;
    if (config.reduction_budget.max_attempts == 0) return error.InvalidInput;
    if (config.reduction_budget.max_successes == 0) return error.InvalidInput;
    if (action_storage.len < config.action_count_max) return error.InvalidInput;
    if (reduction_scratch.len < config.action_count_max) return error.InvalidInput;
}

fn makeCaseIdentity(
    config: ModelConfig,
    case_index: u32,
    case_seed: seed_mod.Seed,
) identity.RunIdentity {
    return identity.makeRunIdentity(.{
        .package_name = config.package_name,
        .run_name = config.run_name,
        .seed = case_seed,
        .artifact_version = .v1,
        .build_mode = config.build_mode,
        .case_index = case_index,
        .run_index = 0,
    });
}

fn generateAndRunRecordedActions(
    comptime TargetError: type,
    target: ModelTarget(TargetError),
    run_identity: identity.RunIdentity,
    action_count_max: u32,
    action_storage: []RecordedAction,
) TargetError!ModelReplayExecution {
    try target.reset(run_identity);

    var executed_action_count: u32 = 0;
    while (executed_action_count < action_count_max) : (executed_action_count += 1) {
        const action_seed = seed_mod.splitSeed(run_identity.seed, executed_action_count);
        const action = try target.nextAction(run_identity, executed_action_count, action_seed);
        action_storage[executed_action_count] = action;

        const step = try target.step(run_identity, executed_action_count, action);
        assertCheckResult(step.check_result);
        const next_count = executed_action_count + 1;
        if (!step.check_result.passed) {
            const trace_capture = deriveTraceCapture(TargetError, target, next_count);
            return .{
                .trace_metadata = trace_capture.metadata,
                .trace_provenance_summary = trace_capture.provenance_summary,
                .retained_trace_snapshot = trace_capture.retained_trace_snapshot,
                .check_result = step.check_result,
                .executed_action_count = next_count,
                .failing_action_index = executed_action_count,
            };
        }
        if (step.stop_after_step) {
            const finish_result = try target.finish(run_identity, next_count);
            assertCheckResult(finish_result);
            const trace_capture = deriveTraceCapture(TargetError, target, next_count);
            return .{
                .trace_metadata = trace_capture.metadata,
                .trace_provenance_summary = trace_capture.provenance_summary,
                .retained_trace_snapshot = trace_capture.retained_trace_snapshot,
                .check_result = finish_result,
                .executed_action_count = next_count,
                .failing_action_index = null,
            };
        }
    }

    const finish_result = try target.finish(run_identity, executed_action_count);
    assertCheckResult(finish_result);
    const trace_capture = deriveTraceCapture(TargetError, target, executed_action_count);
    return .{
        .trace_metadata = trace_capture.metadata,
        .trace_provenance_summary = trace_capture.provenance_summary,
        .retained_trace_snapshot = trace_capture.retained_trace_snapshot,
        .check_result = finish_result,
        .executed_action_count = executed_action_count,
        .failing_action_index = null,
    };
}

const MinimizationResult = struct {
    action_count: u32,
    execution: ModelReplayExecution,
    attempts_total: u32,
    successes_total: u32,
};

fn minimizeFailure(
    comptime TargetError: type,
    target: ModelTarget(TargetError),
    run_identity: identity.RunIdentity,
    action_storage: []RecordedAction,
    scratch: []RecordedAction,
    failing_action_count: u32,
    budget: reducer.ReductionBudget,
) TargetError!MinimizationResult {
    var current_len: usize = failing_action_count;
    var current_execution = try replayRecordedActions(
        TargetError,
        target,
        run_identity,
        action_storage[0..current_len],
    );
    std.debug.assert(!current_execution.check_result.passed);

    var attempts_total: u32 = 0;
    var successes_total: u32 = 0;
    var granularity: usize = 2;

    while (current_len >= 2 and attempts_total < budget.max_attempts and successes_total < budget.max_successes) {
        var reduced_this_round = false;
        const chunk_size = divCeil(current_len, granularity);
        var chunk_start: usize = 0;
        while (chunk_start < current_len and attempts_total < budget.max_attempts and successes_total < budget.max_successes) {
            const chunk_end = @min(current_len, chunk_start + chunk_size);
            const removed_len = chunk_end - chunk_start;
            const candidate_len = current_len - removed_len;
            if (candidate_len == 0) {
                chunk_start = chunk_end;
                continue;
            }

            copyCandidateWithoutChunk(
                scratch[0..candidate_len],
                action_storage[0..current_len],
                chunk_start,
                chunk_end,
            );
            attempts_total += 1;

            const candidate_execution = try replayRecordedActions(
                TargetError,
                target,
                run_identity,
                scratch[0..candidate_len],
            );
            if (!candidate_execution.check_result.passed) {
                @memcpy(action_storage[0..candidate_len], scratch[0..candidate_len]);
                current_len = candidate_len;
                current_execution = candidate_execution;
                successes_total += 1;
                granularity = if (granularity > 2) granularity - 1 else 2;
                reduced_this_round = true;
                break;
            }

            chunk_start = chunk_end;
        }

        if (!reduced_this_round) {
            if (granularity >= current_len) break;
            granularity = @min(current_len, granularity * 2);
        }
    }

    return .{
        .action_count = @intCast(current_len),
        .execution = current_execution,
        .attempts_total = attempts_total,
        .successes_total = successes_total,
    };
}

fn persistFailure(
    comptime TargetError: type,
    persistence: ?ModelPersistence,
    target: ModelTarget(TargetError),
    run_identity: identity.RunIdentity,
    execution: ModelReplayExecution,
    actions: []const RecordedAction,
) (ModelRunError || failure_bundle.FailureBundleWriteError)!?[]const u8 {
    if (persistence) |persistence_config| {
        var bundle_context = persistence_config.failure_bundle_context;
        if (bundle_context.trace_provenance_summary == null) {
            bundle_context.trace_provenance_summary = execution.trace_provenance_summary;
        }
        if (bundle_context.retained_trace_snapshot == null and
            bundle_context.artifact_selection.writeRetained())
        {
            bundle_context.retained_trace_snapshot = execution.retained_trace_snapshot;
        }
        const bundle_meta = try failure_bundle.writeFailureBundle(
            persistence_config.failure_bundle,
            run_identity,
            execution.trace_metadata,
            execution.check_result,
            bundle_context,
        );
        var bundle_dir = try persistence_config.failure_bundle.dir.openDir(
            persistence_config.failure_bundle.io,
            bundle_meta.entry_name,
            .{},
        );
        defer bundle_dir.close(persistence_config.failure_bundle.io);

        const action_bytes_len = try encodeRecordedActions(
            persistence_config.action_bytes_buffer,
            actions,
        );
        try bundle_dir.writeFile(persistence_config.failure_bundle.io, .{
            .sub_path = actions_bin_file_name,
            .data = persistence_config.action_bytes_buffer[0..action_bytes_len],
            .flags = .{ .exclusive = true },
        });
        if (persistence_config.artifact_selection.action_document_artifact == .zon) {
            const document = try makeRecordedActionDocument(
                TargetError,
                persistence_config.action_document_entries,
                target,
                actions,
            );
            _ = try artifact.document.writeZonFile(
                persistence_config.failure_bundle.io,
                bundle_dir,
                actions_zon_file_name,
                persistence_config.action_document_buffer,
                document,
            );
        }
        return bundle_meta.entry_name;
    }
    return null;
}

fn makeRecordedActionDocument(
    comptime TargetError: type,
    entries_buffer: []RecordedActionDocumentEntry,
    target: ModelTarget(TargetError),
    actions: []const RecordedAction,
) ModelRunError!RecordedActionDocument {
    if (entries_buffer.len < actions.len) return error.NoSpaceLeft;
    for (actions, 0..) |action, index| {
        const descriptor = target.describeAction(action);
        if (descriptor.label.len == 0) return error.InvalidInput;
        entries_buffer[index] = .{
            .index = @intCast(index),
            .tag = action.tag,
            .value = action.value,
            .label = descriptor.label,
        };
    }
    return .{
        .action_count = @intCast(actions.len),
        .actions = entries_buffer[0..actions.len],
    };
}

const TraceCapture = struct {
    metadata: trace.TraceMetadata,
    provenance_summary: ?trace.TraceProvenanceSummary = null,
    retained_trace_snapshot: ?trace.TraceSnapshot = null,
};

fn deriveTraceCapture(
    comptime TargetError: type,
    target: ModelTarget(TargetError),
    action_count: u32,
) TraceCapture {
    if (target.traceSnapshot()) |snapshot| {
        return .{
            .metadata = snapshot.metadata(),
            .provenance_summary = snapshot.provenanceSummary(),
            .retained_trace_snapshot = snapshot,
        };
    }
    if (target.traceMetadata()) |metadata| {
        return .{
            .metadata = metadata,
        };
    }
    return .{
        .metadata = makeTraceMetadata(action_count),
    };
}

fn encodedActionsLen(action_count: usize) ModelRunError!usize {
    const header_len = recorded_actions_magic.len + @sizeOf(u16) + @sizeOf(u32);
    const body_len = std.math.mul(usize, action_count, @sizeOf(u32) + @sizeOf(u64)) catch {
        return error.Overflow;
    };
    return std.math.add(usize, header_len, body_len) catch error.Overflow;
}

fn makeTraceMetadata(action_count: u32) trace.TraceMetadata {
    if (action_count == 0) {
        return .{
            .event_count = 0,
            .truncated = false,
            .has_range = false,
            .first_sequence_no = 0,
            .last_sequence_no = 0,
            .first_timestamp_ns = 0,
            .last_timestamp_ns = 0,
        };
    }

    return .{
        .event_count = action_count,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 0,
        .last_sequence_no = action_count - 1,
        .first_timestamp_ns = 0,
        .last_timestamp_ns = action_count - 1,
    };
}

fn divCeil(lhs: usize, rhs: usize) usize {
    std.debug.assert(rhs != 0);
    return @divFloor(lhs + rhs - 1, rhs);
}

fn copyCandidateWithoutChunk(
    destination: []RecordedAction,
    source: []const RecordedAction,
    chunk_start: usize,
    chunk_end: usize,
) void {
    std.debug.assert(chunk_start <= chunk_end);
    std.debug.assert(chunk_end <= source.len);
    const prefix_len = chunk_start;
    const suffix_len = source.len - chunk_end;
    std.debug.assert(destination.len == prefix_len + suffix_len);
    @memcpy(destination[0..prefix_len], source[0..prefix_len]);
    @memcpy(destination[prefix_len .. prefix_len + suffix_len], source[chunk_end..]);
}

fn assertCheckResult(result: checker.CheckResult) void {
    if (result.passed) {
        std.debug.assert(result.violations.len == 0);
    } else {
        std.debug.assert(result.violations.len > 0);
    }
}

fn assertFailedCaseSummaryInput(failed_case: ModelCaseResult) void {
    std.debug.assert(failed_case.run_identity.package_name.len != 0);
    std.debug.assert(failed_case.run_identity.run_name.len != 0);
    std.debug.assert(!failed_case.check_result.passed);
    std.debug.assert(failed_case.recorded_actions.len != 0);
    std.debug.assert(failed_case.original_action_count >= failed_case.recorded_actions.len);
    if (failed_case.persisted_entry_name) |persisted_entry_name| {
        std.debug.assert(persisted_entry_name.len != 0);
    }
    if (failed_case.failing_action_index) |failing_action_index| {
        std.debug.assert(failing_action_index < failed_case.recorded_actions.len);
    }
}

fn writeBytes(writer: *serial.writer.Writer, bytes: []const u8) ModelRunError!void {
    writer.writeBytes(bytes) catch |err| return mapWriterError(err);
}

fn writeInt(writer: *serial.writer.Writer, value: anytype) ModelRunError!void {
    writer.writeInt(value, .little) catch |err| return mapWriterError(err);
}

fn readValue(reader: *serial.reader.Reader, comptime T: type) ModelRunError!T {
    return reader.readInt(T, .little) catch |err| mapReaderError(err);
}

fn mapWriterError(err: serial.writer.Error) ModelRunError {
    return switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.InvalidInput => error.CorruptData,
        error.Overflow => error.Overflow,
        error.Underflow => error.CorruptData,
    };
}

fn mapReaderError(err: serial.reader.Error) ModelRunError {
    return switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.InvalidInput => error.CorruptData,
        error.Overflow => error.Overflow,
        error.Underflow => error.CorruptData,
        error.CorruptData => error.CorruptData,
    };
}

fn validateReadBuffers(buffers: RecordedActionReadBuffers) ModelRunError!void {
    if ((buffers.action_document_source_buffer.len == 0) != (buffers.action_document_parse_buffer.len == 0)) {
        return error.InvalidInput;
    }
}

fn shouldReadActionDocument(buffers: RecordedActionReadBuffers) bool {
    return buffers.action_document_source_buffer.len != 0;
}

fn readActionDocument(
    io: std.Io,
    bundle_dir: std.Io.Dir,
    buffers: RecordedActionReadBuffers,
) (ModelRunError || std.Io.Dir.ReadFileError)!RecordedActionDocument {
    const zon = try bundle_dir.readFile(io, actions_zon_file_name, buffers.action_document_source_buffer);
    return artifact.document.decodeZon(RecordedActionDocument, zon, .{
        .source_buffer = buffers.action_document_source_buffer,
        .parse_buffer = buffers.action_document_parse_buffer,
    }) catch |err| switch (err) {
        error.InvalidInput => error.InvalidInput,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.CorruptData => error.CorruptData,
        error.Unsupported => error.Unsupported,
        else => unreachable,
    };
}

const SummaryWriter = struct {
    buffer: []u8,
    position: usize = 0,

    fn init(buffer: []u8) SummaryWriter {
        return .{ .buffer = buffer };
    }

    fn writeAll(self: *SummaryWriter, bytes: []const u8) ModelRunError!void {
        if (self.buffer.len - self.position < bytes.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.position .. self.position + bytes.len], bytes);
        self.position += bytes.len;
    }

    fn print(self: *SummaryWriter, comptime format: []const u8, args: anytype) ModelRunError!void {
        const written = std.fmt.bufPrint(self.buffer[self.position..], format, args) catch {
            return error.NoSpaceLeft;
        };
        self.position += written.len;
    }

    fn finish(self: *const SummaryWriter) []const u8 {
        return self.buffer[0..self.position];
    }
};

test "encodeRecordedActions and decodeRecordedActions round-trip" {
    const actions = [_]RecordedAction{
        .{ .tag = 1, .value = 7 },
        .{ .tag = 2, .value = 9 },
    };
    var encoded: [128]u8 = undefined;
    const encoded_len = try encodeRecordedActions(&encoded, &actions);

    var decoded_storage: [4]RecordedAction = undefined;
    const decoded = try decodeRecordedActions(encoded[0..encoded_len], &decoded_storage);
    try std.testing.expectEqualSlices(RecordedAction, &actions, decoded);
}

test "runModelCases rejects invalid config and storage" {
    const Target = ModelTarget(error{});
    const Runner = ModelRunner(error{});
    const Context = struct {
        fn reset(_: *anyopaque, _: identity.RunIdentity) error{}!void {}
        fn nextAction(_: *anyopaque, _: identity.RunIdentity, _: u32, _: seed_mod.Seed) error{}!RecordedAction {
            return .{ .tag = 1 };
        }
        fn step(_: *anyopaque, _: identity.RunIdentity, _: u32, _: RecordedAction) error{}!ModelStep {
            return .{ .check_result = checker.CheckResult.pass(null) };
        }
        fn finish(_: *anyopaque, _: identity.RunIdentity, _: u32) error{}!checker.CheckResult {
            return checker.CheckResult.pass(null);
        }
        fn describe(_: *anyopaque, _: RecordedAction) ActionDescriptor {
            return .{ .label = "noop" };
        }
    };

    var action_storage: [1]RecordedAction = undefined;
    var reduction_scratch: [1]RecordedAction = undefined;
    try std.testing.expectError(error.InvalidInput, runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "invalid",
            .base_seed = .init(1),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = 2,
        },
        .target = Target{
            .context = undefined,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    }));
}

test "runModelCases minimizes and persists failing recorded traces" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const violations = [_]checker.Violation{
        .{ .code = "bad_action", .message = "force-fail action reached the model" },
    };

    const Context = struct {
        stop_after_successes: u32 = 0,

        fn reset(context_ptr: *anyopaque, _: identity.RunIdentity) error{}!void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            context.stop_after_successes = 0;
        }

        fn nextAction(_: *anyopaque, _: identity.RunIdentity, action_index: u32, _: seed_mod.Seed) error{}!RecordedAction {
            return switch (action_index) {
                0 => .{ .tag = 1 },
                1 => .{ .tag = 2 },
                else => .{ .tag = 99 },
            };
        }

        fn step(
            context_ptr: *anyopaque,
            _: identity.RunIdentity,
            _: u32,
            action: RecordedAction,
        ) error{}!ModelStep {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            if (action.tag == 99) {
                return .{
                    .check_result = checker.CheckResult.fail(&violations, null),
                };
            }
            context.stop_after_successes += 1;
            return .{
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn finish(_: *anyopaque, _: identity.RunIdentity, _: u32) error{}!checker.CheckResult {
            return checker.CheckResult.pass(null);
        }

        fn describe(_: *anyopaque, action: RecordedAction) ActionDescriptor {
            return .{
                .label = switch (action.tag) {
                    1 => "set",
                    2 => "reset",
                    99 => "force_fail",
                    else => "unknown",
                },
            };
        }
    };

    const Target = ModelTarget(error{});
    const Runner = ModelRunner(error{});
    var context = Context{};
    var action_storage: [8]RecordedAction = undefined;
    var reduction_scratch: [8]RecordedAction = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    var action_bytes_buffer: [256]u8 = undefined;
    var action_document_buffer: [1024]u8 = undefined;
    var action_document_entries: [8]RecordedActionDocumentEntry = undefined;

    const summary = try runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "model_reduce",
            .base_seed = .init(17),
            .build_mode = .debug,
            .case_count_max = 1,
            .action_count_max = 3,
            .reduction_budget = .{
                .max_attempts = 16,
                .max_successes = 16,
            },
        },
        .target = Target{
            .context = &context,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
        },
        .persistence = .{
            .failure_bundle = .{
                .io = io,
                .dir = tmp_dir.dir,
                .entry_name_buffer = &entry_name_buffer,
                .artifact_buffer = &artifact_buffer,
                .manifest_buffer = &manifest_buffer,
                .trace_buffer = &trace_buffer,
                .violations_buffer = &violations_buffer,
            },
            .action_bytes_buffer = &action_bytes_buffer,
            .action_document_buffer = &action_document_buffer,
            .action_document_entries = &action_document_entries,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    try std.testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try std.testing.expectEqual(@as(u32, 1), failed_case.recorded_actions.len);
    try std.testing.expectEqual(@as(u32, 3), failed_case.original_action_count);
    try std.testing.expectEqual(@as(u32, 99), failed_case.recorded_actions[0].tag);
    try std.testing.expect(failed_case.persisted_entry_name != null);

    var read_action_storage: [8]RecordedAction = undefined;
    var read_action_bytes: [256]u8 = undefined;
    var read_action_document_source: [1024]u8 = undefined;
    var read_action_document_parse: [4096]u8 = undefined;
    const recorded_view = try readRecordedActions(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        .{
            .actions_buffer = &read_action_storage,
            .action_bytes_buffer = &read_action_bytes,
            .action_document_source_buffer = &read_action_document_source,
            .action_document_parse_buffer = &read_action_document_parse,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), recorded_view.actions.len);
    try std.testing.expect(recorded_view.action_document != null);
    try std.testing.expectEqualStrings("force_fail", recorded_view.action_document.?.actions[0].label);

    var summary_buffer: [512]u8 = undefined;
    const summary_text = try formatFailedCaseSummary(error{}, &summary_buffer, Target{
        .context = &context,
        .reset_fn = Context.reset,
        .next_action_fn = Context.nextAction,
        .step_fn = Context.step,
        .finish_fn = Context.finish,
        .describe_action_fn = Context.describe,
    }, failed_case);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "first_bad_action=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "violations: bad_action") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, ">> action[0] tag=99 value=0 label=force_fail") != null);

    const replay_execution = try replayRecordedActions(
        error{},
        Target{
            .context = &context,
            .reset_fn = Context.reset,
            .next_action_fn = Context.nextAction,
            .step_fn = Context.step,
            .finish_fn = Context.finish,
            .describe_action_fn = Context.describe,
        },
        failed_case.run_identity,
        recorded_view.actions,
    );
    try std.testing.expect(!replay_execution.check_result.passed);
    try std.testing.expectEqual(@as(u32, 1), replay_execution.executed_action_count);
}
