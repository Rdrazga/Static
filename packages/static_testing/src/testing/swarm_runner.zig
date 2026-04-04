//! Deterministic swarm runner over bounded simulation seeds and variants.
//!
//! The swarm runner stays in the testing control plane:
//! - it enumerates seeds and weighted scenario variants;
//! - it executes one deterministic scenario per run;
//! - it persists bounded replay artifacts for retained failures; and
//! - it keeps simulation primitives in `testing.sim` out of orchestration code.

const std = @import("std");
const artifact = @import("../artifact/root.zig");
const core = @import("static_core");
const checker = @import("checker.zig");
const corpus = @import("corpus.zig");
const failure_bundle = @import("failure_bundle.zig");
const identity = @import("identity.zig");
const liveness = @import("liveness.zig");
const seed_mod = @import("seed.zig");
const trace = @import("trace.zig");

/// Operating errors surfaced by swarm execution setup and orchestration.
pub const SwarmRunError = error{
    InvalidInput,
    NoSpaceLeft,
    OutOfMemory,
    WouldBlock,
    Unsupported,
};

/// Named swarm profiles for bounded campaign policy.
pub const SwarmProfile = enum(u8) {
    smoke = 1,
    stress = 2,
    soak = 3,
};

/// Stop behavior after one failing run.
pub const SwarmStopPolicy = enum(u8) {
    stop_on_first_failure = 1,
    collect_failures = 2,
};

/// Bounded deterministic swarm runner configuration.
pub const SwarmConfig = struct {
    package_name: []const u8,
    run_name: []const u8,
    base_seed: seed_mod.Seed,
    build_mode: identity.BuildMode,
    profile: SwarmProfile = .smoke,
    shard_index: u32 = 0,
    shard_count: u32 = 1,
    seed_count_max: u32,
    steps_per_seed_max: u32,
    failure_retention_max: u32 = 1,
    stop_policy: SwarmStopPolicy = .stop_on_first_failure,
    progress_every_n_runs: u32 = 0,
};

pub const swarm_campaign_record_version: u16 = 1;
pub const swarm_parallel_lane_count_max: usize = 16;

pub const SwarmCampaignResumeMode = enum(u8) {
    fresh = 0,
    resume_if_present = 1,
};

/// Stable scenario variant metadata chosen per run.
pub const SwarmVariant = struct {
    variant_id: u32,
    variant_weight: u32,
    label: []const u8,
};

/// One deterministic scenario input prepared by the runner.
pub const SwarmScenarioInput = struct {
    run_identity: identity.RunIdentity,
    profile: SwarmProfile,
    variant: SwarmVariant,
    steps_per_seed_max: u32,
};

/// One deterministic scenario execution result.
pub const SwarmScenarioExecution = struct {
    steps_executed: u32,
    trace_metadata: trace.TraceMetadata,
    trace_provenance_summary: ?trace.TraceProvenanceSummary = null,
    retained_trace_snapshot: ?trace.TraceSnapshot = null,
    check_result: checker.CheckResult,
    pending_reason: ?liveness.PendingReasonDetail = null,
    schedule_mode: ?[]const u8 = null,
    schedule_seed: ?seed_mod.Seed = null,
};

/// One retained swarm failure or first-failure summary.
pub const SwarmExecution = struct {
    run_identity: identity.RunIdentity,
    profile: SwarmProfile,
    variant_id: u32,
    steps_executed: u32,
    trace_metadata: trace.TraceMetadata,
    check_result: checker.CheckResult,
    persisted_entry_name_len: u16 = 0,
    persisted_entry_name_storage: [std.Io.Dir.max_name_bytes]u8 =
        [_]u8{0} ** std.Io.Dir.max_name_bytes,

    /// View the retained corpus entry name when one artifact was persisted.
    pub fn persistedEntryName(self: *const SwarmExecution) ?[]const u8 {
        if (self.persisted_entry_name_len == 0) return null;
        return self.persisted_entry_name_storage[0..self.persisted_entry_name_len];
    }
};

/// Aggregate result for one deterministic swarm campaign.
pub const SwarmSummary = struct {
    shard_index: u32 = 0,
    shard_count: u32 = 1,
    resume_from_run_index: u32 = 0,
    executed_run_count: u32,
    failed_run_count: u32,
    retained_failure_count: u32,
    first_failure: ?SwarmExecution,
};

/// One deterministic progress snapshot emitted on configured run intervals.
pub const SwarmProgress = struct {
    profile: SwarmProfile,
    seed_count_max: u32,
    shard_index: u32 = 0,
    shard_count: u32 = 1,
    resume_from_run_index: u32 = 0,
    completed_run_count: u32,
    failed_run_count: u32,
    retained_failure_count: u32,
    latest_run_index: u32,
    latest_variant_id: u32,
    latest_failed: bool,
};

pub const SwarmCampaignRecord = struct {
    run_index: u32,
    seed: seed_mod.Seed,
    variant_id: u32,
    passed: bool,
    retained_failure: bool,
    persisted_entry_name: ?[]const u8 = null,
};

pub const SwarmCampaignRecordAppendBuffers = struct {
    existing_file_buffer: []u8,
    record_buffer: []u8,
    frame_buffer: []u8,
    output_file_buffer: []u8,
};

pub const SwarmCampaignRecordReadBuffers = struct {
    file_buffer: []u8,
    entry_name_buffer: []u8 = &.{},
};

pub const SwarmCampaignPersistence = struct {
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8 = "swarm_campaign.binlog",
    resume_mode: SwarmCampaignResumeMode = .fresh,
    max_records: usize = 1024,
    append_buffers: SwarmCampaignRecordAppendBuffers,
    read_buffers: SwarmCampaignRecordReadBuffers,
};

pub const SwarmCampaignVariantSummary = struct {
    variant_id: u32,
    run_count: u32,
    failed_run_count: u32,
    retained_failure_count: u32,
    first_failed_run_index: ?u32 = null,
    last_run_index: u32,
};

pub const SwarmRetainedSeedSuggestion = struct {
    variant_id: u32,
    run_index: u32,
    seed: seed_mod.Seed,
};

pub const SwarmCampaignSummaryBuffers = struct {
    file_buffer: []u8,
    entry_name_buffer: []u8 = &.{},
    variant_summaries_buffer: []SwarmCampaignVariantSummary,
    retained_seed_suggestions_buffer: []SwarmRetainedSeedSuggestion,
};

pub const SwarmCampaignSummary = struct {
    total_run_count: u32,
    failed_run_count: u32,
    retained_failure_count: u32,
    first_run_index: ?u32 = null,
    last_run_index: ?u32 = null,
    variant_summaries: []const SwarmCampaignVariantSummary,
    retained_seed_suggestions: []const SwarmRetainedSeedSuggestion,
};

/// Persistence hooks for retained swarm failures.
pub const SwarmPersistence = struct {
    io: std.Io,
    dir: std.Io.Dir,
    naming: corpus.CorpusNaming = .{ .prefix = "swarm" },
    artifact_buffer: []u8,
    entry_name_buffer: []u8,
};

/// Failure-bundle persistence hooks for retained swarm failures.
pub const SwarmFailureBundlePersistence = struct {
    io: std.Io,
    dir: std.Io.Dir,
    naming: corpus.CorpusNaming = .{
        .prefix = "swarm_bundle",
        .extension = ".bundle",
    },
    entry_name_buffer: []u8,
    artifact_buffer: []u8,
    manifest_buffer: []u8,
    trace_buffer: []u8,
    retained_trace_file_buffer: []u8 = &.{},
    retained_trace_frame_buffer: []u8 = &.{},
    violations_buffer: []u8,
    context: failure_bundle.FailureBundleContext = .{},
};

/// Deterministic progress reporting callback contract.
pub const SwarmProgressReporter = struct {
    context: *const anyopaque,
    report_fn: *const fn (context: *const anyopaque, progress: SwarmProgress) void,

    pub fn report(self: SwarmProgressReporter, progress: SwarmProgress) void {
        self.report_fn(self.context, progress);
    }
};

/// Deterministic swarm scenario callback contract.
pub fn SwarmScenario(comptime ScenarioError: type) type {
    return struct {
        context: *const anyopaque,
        run_fn: *const fn (
            context: *const anyopaque,
            input: SwarmScenarioInput,
        ) ScenarioError!SwarmScenarioExecution,

        pub fn run(
            self: @This(),
            input: SwarmScenarioInput,
        ) ScenarioError!SwarmScenarioExecution {
            return self.run_fn(self.context, input);
        }
    };
}

/// Deterministic swarm runner configuration bundle.
pub fn SwarmRunner(comptime ScenarioError: type) type {
    return struct {
        config: SwarmConfig,
        scenario: SwarmScenario(ScenarioError),
        variants: []const SwarmVariant,
        parallel_scenarios: ?[]const SwarmScenario(ScenarioError) = null,
        persistence: ?SwarmPersistence = null,
        failure_bundle_persistence: ?SwarmFailureBundlePersistence = null,
        campaign_persistence: ?SwarmCampaignPersistence = null,
        progress: ?SwarmProgressReporter = null,

        pub fn run(
            self: @This(),
        ) (SwarmRunError || corpus.CorpusWriteError || failure_bundle.FailureBundleWriteError || artifact.record_log.ArtifactRecordLogError || ScenarioError)!SwarmSummary {
            return runSwarm(ScenarioError, self);
        }
    };
}

comptime {
    core.errors.assertVocabularySubset(SwarmRunError);
    std.debug.assert(std.meta.fields(SwarmProfile).len == 3);
    std.debug.assert(std.meta.fields(SwarmStopPolicy).len == 2);
}

/// Execute a bounded deterministic swarm campaign.
pub fn runSwarm(
    comptime ScenarioError: type,
    runner: SwarmRunner(ScenarioError),
) (SwarmRunError || corpus.CorpusWriteError || failure_bundle.FailureBundleWriteError || artifact.record_log.ArtifactRecordLogError || ScenarioError)!SwarmSummary {
    try validateRunnerConfig(runner.config, runner.variants);
    try validateParallelScenarios(ScenarioError, runner.config, runner.parallel_scenarios);
    try validateCampaignPersistence(runner.campaign_persistence);
    if (runner.parallel_scenarios != null) {
        return runSwarmHostThreaded(ScenarioError, runner);
    }
    return runSwarmSingleThreaded(ScenarioError, runner);
}

fn runSwarmSingleThreaded(
    comptime ScenarioError: type,
    runner: SwarmRunner(ScenarioError),
) (SwarmRunError || corpus.CorpusWriteError || failure_bundle.FailureBundleWriteError || artifact.record_log.ArtifactRecordLogError || ScenarioError)!SwarmSummary {
    const resume_from_run_index = try resolveResumeFromRunIndex(runner.campaign_persistence);

    var summary: SwarmSummary = .{
        .shard_index = runner.config.shard_index,
        .shard_count = runner.config.shard_count,
        .resume_from_run_index = resume_from_run_index,
        .executed_run_count = 0,
        .failed_run_count = 0,
        .retained_failure_count = 0,
        .first_failure = null,
    };
    var run_index = nextOwnedRunIndex(runner.config, resume_from_run_index) orelse return summary;
    while (run_index < runner.config.seed_count_max) {
        const variant = try chooseVariant(runner.config.base_seed, run_index, runner.variants);
        const run_identity = makeRunIdentity(runner.config, variant, run_index);
        const scenario_execution = try runner.scenario.run(.{
            .run_identity = run_identity,
            .profile = runner.config.profile,
            .variant = variant,
            .steps_per_seed_max = runner.config.steps_per_seed_max,
        });
        assertScenarioExecution(scenario_execution, runner.config.steps_per_seed_max);
        summary.executed_run_count += 1;

        if (!scenario_execution.check_result.passed) {
            summary.failed_run_count += 1;
            const failed_execution = try retainFailure(
                runner.persistence,
                runner.failure_bundle_persistence,
                runner.config,
                variant,
                run_identity,
                scenario_execution,
                summary.retained_failure_count,
            );
            if (failed_execution.persistedEntryName() != null) {
                summary.retained_failure_count += 1;
            }
            if (summary.first_failure == null) {
                summary.first_failure = failed_execution;
            }
            try persistCampaignRecord(
                runner.campaign_persistence,
                run_identity,
                variant,
                false,
                failed_execution.persistedEntryName() != null,
                failed_execution.persistedEntryName(),
            );
            if (runner.config.stop_policy == .stop_on_first_failure) {
                return summary;
            }
        } else {
            try persistCampaignRecord(
                runner.campaign_persistence,
                run_identity,
                variant,
                true,
                false,
                null,
            );
        }
        maybeReportProgress(runner.progress, runner.config, summary, run_index, variant, scenario_execution.check_result.passed);
        run_index = nextOwnedRunIndex(runner.config, run_index + 1) orelse break;
    }

    return summary;
}

fn runSwarmHostThreaded(
    comptime ScenarioError: type,
    runner: SwarmRunner(ScenarioError),
) (SwarmRunError || corpus.CorpusWriteError || failure_bundle.FailureBundleWriteError || artifact.record_log.ArtifactRecordLogError || ScenarioError)!SwarmSummary {
    const parallel_scenarios = runner.parallel_scenarios.?;
    const lane_count = parallel_scenarios.len;
    std.debug.assert(lane_count != 0);
    std.debug.assert(lane_count <= swarm_parallel_lane_count_max);

    const resume_from_run_index = try resolveResumeFromRunIndex(runner.campaign_persistence);
    var summary: SwarmSummary = .{
        .shard_index = runner.config.shard_index,
        .shard_count = runner.config.shard_count,
        .resume_from_run_index = resume_from_run_index,
        .executed_run_count = 0,
        .failed_run_count = 0,
        .retained_failure_count = 0,
        .first_failure = null,
    };
    var next_run_index = nextOwnedRunIndex(runner.config, resume_from_run_index) orelse return summary;
    var lane_states: [swarm_parallel_lane_count_max]ParallelLaneState(ScenarioError) = undefined;

    while (next_run_index < runner.config.seed_count_max) {
        var batch_count: usize = 0;
        while (batch_count < lane_count and next_run_index < runner.config.seed_count_max) {
            const variant = try chooseVariant(runner.config.base_seed, next_run_index, runner.variants);
            const run_identity = makeRunIdentity(runner.config, variant, next_run_index);
            lane_states[batch_count] = .{
                .scenario = parallel_scenarios[batch_count],
                .input = .{
                    .run_identity = run_identity,
                    .profile = runner.config.profile,
                    .variant = variant,
                    .steps_per_seed_max = runner.config.steps_per_seed_max,
                },
                .result = null,
            };
            lane_states[batch_count].thread = try spawnParallelLane(ScenarioError, &lane_states[batch_count]);
            batch_count += 1;
            next_run_index = nextOwnedRunIndex(runner.config, next_run_index + 1) orelse runner.config.seed_count_max;
        }

        var lane_index: usize = 0;
        while (lane_index < batch_count) : (lane_index += 1) {
            lane_states[lane_index].thread.?.join();
        }

        lane_index = 0;
        while (lane_index < batch_count) : (lane_index += 1) {
            const lane_state = &lane_states[lane_index];
            const scenario_execution = try lane_state.result.?;
            assertScenarioExecution(scenario_execution, runner.config.steps_per_seed_max);
            summary.executed_run_count += 1;

            if (!scenario_execution.check_result.passed) {
                summary.failed_run_count += 1;
                const failed_execution = try retainFailure(
                    runner.persistence,
                    runner.failure_bundle_persistence,
                    runner.config,
                    lane_state.input.variant,
                    lane_state.input.run_identity,
                    scenario_execution,
                    summary.retained_failure_count,
                );
                if (failed_execution.persistedEntryName() != null) {
                    summary.retained_failure_count += 1;
                }
                if (summary.first_failure == null) {
                    summary.first_failure = failed_execution;
                }
                try persistCampaignRecord(
                    runner.campaign_persistence,
                    lane_state.input.run_identity,
                    lane_state.input.variant,
                    false,
                    failed_execution.persistedEntryName() != null,
                    failed_execution.persistedEntryName(),
                );
            } else {
                try persistCampaignRecord(
                    runner.campaign_persistence,
                    lane_state.input.run_identity,
                    lane_state.input.variant,
                    true,
                    false,
                    null,
                );
            }
            maybeReportProgress(
                runner.progress,
                runner.config,
                summary,
                lane_state.input.run_identity.run_index,
                lane_state.input.variant,
                scenario_execution.check_result.passed,
            );
        }
    }

    return summary;
}

/// Format one deterministic progress line for local or CI logs.
pub fn formatProgressSummary(
    buffer: []u8,
    progress: SwarmProgress,
) SwarmRunError![]const u8 {
    if (buffer.len == 0) return error.NoSpaceLeft;

    return std.fmt.bufPrint(
        buffer,
        "profile={s} shard={d}/{d} resume_from={d} completed={d}/{d} failed={d} retained={d} latest_run={d} latest_variant={d} latest_failed={s}",
        .{
            @tagName(progress.profile),
            progress.shard_index,
            progress.shard_count,
            progress.resume_from_run_index,
            progress.completed_run_count,
            progress.seed_count_max,
            progress.failed_run_count,
            progress.retained_failure_count,
            progress.latest_run_index,
            progress.latest_variant_id,
            if (progress.latest_failed) "true" else "false",
        },
    ) catch return error.NoSpaceLeft;
}

fn validateRunnerConfig(config: SwarmConfig, variants: []const SwarmVariant) SwarmRunError!void {
    if (config.package_name.len == 0) return error.InvalidInput;
    if (config.run_name.len == 0) return error.InvalidInput;
    if (config.shard_count == 0) return error.InvalidInput;
    if (config.shard_index >= config.shard_count) return error.InvalidInput;
    if (config.seed_count_max == 0) return error.InvalidInput;
    if (config.steps_per_seed_max == 0) return error.InvalidInput;
    if (variants.len == 0) return error.InvalidInput;
    try validateVariants(variants);
}

fn validateParallelScenarios(
    comptime ScenarioError: type,
    config: SwarmConfig,
    parallel_scenarios: ?[]const SwarmScenario(ScenarioError),
) SwarmRunError!void {
    if (parallel_scenarios) |scenarios| {
        if (scenarios.len == 0) return error.InvalidInput;
        if (scenarios.len > swarm_parallel_lane_count_max) return error.InvalidInput;
        if (config.stop_policy != .collect_failures) return error.InvalidInput;
    }
}

fn validateCampaignPersistence(
    campaign_persistence: ?SwarmCampaignPersistence,
) (SwarmRunError || artifact.record_log.ArtifactRecordLogError)!void {
    if (campaign_persistence) |persistence| {
        if (persistence.sub_path.len == 0) return error.InvalidInput;
        if (persistence.max_records == 0) return error.InvalidInput;
        if (persistence.append_buffers.existing_file_buffer.len == 0) return error.InvalidInput;
        if (persistence.append_buffers.record_buffer.len == 0) return error.InvalidInput;
        if (persistence.append_buffers.frame_buffer.len == 0) return error.InvalidInput;
        if (persistence.append_buffers.output_file_buffer.len == 0) return error.InvalidInput;
        if (persistence.read_buffers.file_buffer.len == 0) return error.InvalidInput;
    }
}

fn spawnParallelLane(
    comptime ScenarioError: type,
    lane_state: *ParallelLaneState(ScenarioError),
) SwarmRunError!std.Thread {
    return std.Thread.spawn(.{}, ParallelLaneState(ScenarioError).run, .{lane_state}) catch |err| switch (err) {
        error.ThreadQuotaExceeded => error.WouldBlock,
        error.LockedMemoryLimitExceeded => error.WouldBlock,
        error.SystemResources => error.OutOfMemory,
        error.OutOfMemory => error.OutOfMemory,
        error.Unexpected => error.Unsupported,
    };
}

fn resolveResumeFromRunIndex(
    campaign_persistence: ?SwarmCampaignPersistence,
) artifact.record_log.ArtifactRecordLogError!u32 {
    if (campaign_persistence == null) return 0;
    const persistence = campaign_persistence.?;
    if (persistence.resume_mode == .fresh) return 0;
    const latest = try readMostRecentCampaignRecord(
        persistence.io,
        persistence.dir,
        persistence.sub_path,
        persistence.read_buffers,
    );
    if (latest) |record| {
        return record.run_index + 1;
    }
    return 0;
}

fn ownsRunIndex(config: SwarmConfig, run_index: u32) bool {
    return (run_index % config.shard_count) == config.shard_index;
}

fn nextOwnedRunIndex(config: SwarmConfig, start_run_index: u32) ?u32 {
    var run_index = start_run_index;
    while (run_index < config.seed_count_max) : (run_index += 1) {
        if (ownsRunIndex(config, run_index)) return run_index;
    }
    return null;
}

fn validateVariants(variants: []const SwarmVariant) SwarmRunError!void {
    var total_weight: u64 = 0;
    for (variants) |variant| {
        if (variant.variant_weight == 0) return error.InvalidInput;
        if (variant.label.len == 0) return error.InvalidInput;
        total_weight = std.math.add(u64, total_weight, variant.variant_weight) catch return error.InvalidInput;
    }
    if (total_weight == 0) return error.InvalidInput;
}

fn chooseVariant(
    base_seed: seed_mod.Seed,
    run_index: u32,
    variants: []const SwarmVariant,
) SwarmRunError!SwarmVariant {
    try validateVariants(variants);

    const run_seed = seed_mod.splitSeed(base_seed, run_index);
    const total_weight = totalVariantWeight(variants);
    std.debug.assert(total_weight > 0);
    const threshold = run_seed.value % total_weight;
    return selectVariantForThreshold(variants, threshold);
}

fn totalVariantWeight(variants: []const SwarmVariant) u64 {
    var total_weight: u64 = 0;
    for (variants) |variant| {
        total_weight += variant.variant_weight;
    }
    std.debug.assert(total_weight > 0);
    return total_weight;
}

fn selectVariantForThreshold(
    variants: []const SwarmVariant,
    threshold: u64,
) SwarmVariant {
    var cumulative_weight: u64 = 0;
    for (variants) |variant| {
        cumulative_weight += variant.variant_weight;
        if (threshold < cumulative_weight) {
            return variant;
        }
    }
    unreachable;
}

fn makeRunIdentity(
    config: SwarmConfig,
    variant: SwarmVariant,
    run_index: u32,
) identity.RunIdentity {
    return identity.makeRunIdentity(.{
        .package_name = config.package_name,
        .run_name = config.run_name,
        .seed = seed_mod.splitSeed(config.base_seed, run_index),
        .artifact_version = .v1,
        .build_mode = config.build_mode,
        .case_index = variant.variant_id,
        .run_index = run_index,
    });
}

fn assertScenarioExecution(
    execution: SwarmScenarioExecution,
    steps_per_seed_max: u32,
) void {
    std.debug.assert(execution.steps_executed <= steps_per_seed_max);
    assertTraceMetadata(execution.trace_metadata);
    assertCheckResult(execution.check_result);
    if (execution.retained_trace_snapshot) |snapshot| {
        const snapshot_metadata = snapshot.metadata();
        std.debug.assert(snapshot_metadata.event_count == execution.trace_metadata.event_count);
        std.debug.assert(snapshot_metadata.truncated == execution.trace_metadata.truncated);
        std.debug.assert(snapshot_metadata.has_range == execution.trace_metadata.has_range);
        if (execution.trace_provenance_summary) |provenance_summary| {
            const snapshot_provenance = snapshot.provenanceSummary();
            std.debug.assert(snapshot_provenance.has_provenance == provenance_summary.has_provenance);
            std.debug.assert(snapshot_provenance.caused_event_count == provenance_summary.caused_event_count);
            std.debug.assert(snapshot_provenance.root_event_count == provenance_summary.root_event_count);
            std.debug.assert(snapshot_provenance.correlated_event_count == provenance_summary.correlated_event_count);
            std.debug.assert(snapshot_provenance.surface_labeled_event_count == provenance_summary.surface_labeled_event_count);
            std.debug.assert(snapshot_provenance.max_causal_depth == provenance_summary.max_causal_depth);
        }
    }
    if (execution.pending_reason) |detail| {
        if (detail.label) |label| {
            std.debug.assert(label.len > 0);
        }
    }
    if (execution.schedule_mode) |mode_label| {
        std.debug.assert(mode_label.len > 0);
    }
}

fn assertTraceMetadata(metadata: trace.TraceMetadata) void {
    if (metadata.event_count == 0) {
        std.debug.assert(!metadata.has_range);
        std.debug.assert(metadata.first_sequence_no == 0);
        std.debug.assert(metadata.last_sequence_no == 0);
        std.debug.assert(metadata.first_timestamp_ns == 0);
        std.debug.assert(metadata.last_timestamp_ns == 0);
        return;
    }

    std.debug.assert(metadata.has_range);
    std.debug.assert(metadata.first_sequence_no <= metadata.last_sequence_no);
    std.debug.assert(metadata.first_timestamp_ns <= metadata.last_timestamp_ns);
}

fn assertCheckResult(result: checker.CheckResult) void {
    if (result.passed) {
        std.debug.assert(result.violations.len == 0);
    } else {
        std.debug.assert(result.violations.len > 0);
    }
}

fn retainFailure(
    persistence: ?SwarmPersistence,
    failure_bundle_persistence: ?SwarmFailureBundlePersistence,
    config: SwarmConfig,
    variant: SwarmVariant,
    run_identity: identity.RunIdentity,
    scenario_execution: SwarmScenarioExecution,
    retained_failure_count: u32,
) (SwarmRunError || corpus.CorpusWriteError || failure_bundle.FailureBundleWriteError)!SwarmExecution {
    var failed_execution: SwarmExecution = .{
        .run_identity = run_identity,
        .profile = config.profile,
        .variant_id = variant.variant_id,
        .steps_executed = scenario_execution.steps_executed,
        .trace_metadata = scenario_execution.trace_metadata,
        .check_result = scenario_execution.check_result,
    };
    if (retained_failure_count >= config.failure_retention_max) {
        return failed_execution;
    }
    if (failure_bundle_persistence) |bundle_persistence| {
        const bundle_context = makeFailureBundleContext(
            bundle_persistence.context,
            config,
            variant,
            run_identity,
            scenario_execution,
        );
        const written = try failure_bundle.writeFailureBundle(.{
            .io = bundle_persistence.io,
            .dir = bundle_persistence.dir,
            .naming = bundle_persistence.naming,
            .entry_name_buffer = bundle_persistence.entry_name_buffer,
            .artifact_buffer = bundle_persistence.artifact_buffer,
            .manifest_buffer = bundle_persistence.manifest_buffer,
            .trace_buffer = bundle_persistence.trace_buffer,
            .retained_trace_file_buffer = bundle_persistence.retained_trace_file_buffer,
            .retained_trace_frame_buffer = bundle_persistence.retained_trace_frame_buffer,
            .violations_buffer = bundle_persistence.violations_buffer,
        }, run_identity, scenario_execution.trace_metadata, scenario_execution.check_result, bundle_context);
        try setPersistedEntryName(&failed_execution, written.entry_name);
        return failed_execution;
    }
    if (persistence) |persistence_config| {
        const written = try corpus.writeCorpusEntry(
            persistence_config.io,
            persistence_config.dir,
            persistence_config.naming,
            persistence_config.entry_name_buffer,
            persistence_config.artifact_buffer,
            run_identity,
            scenario_execution.trace_metadata,
        );
        try setPersistedEntryName(&failed_execution, written.entry_name);
    }
    return failed_execution;
}

fn setPersistedEntryName(
    execution: *SwarmExecution,
    entry_name: []const u8,
) SwarmRunError!void {
    if (entry_name.len == 0) return error.InvalidInput;
    if (entry_name.len > execution.persisted_entry_name_storage.len) return error.NoSpaceLeft;

    @memcpy(execution.persisted_entry_name_storage[0..entry_name.len], entry_name);
    execution.persisted_entry_name_len = @intCast(entry_name.len);
}

pub fn encodeCampaignRecordBinary(
    buffer: []u8,
    record: SwarmCampaignRecord,
) artifact.record_log.ArtifactRecordLogError![]const u8 {
    try validateCampaignRecord(record);

    var writer = CampaignBufferWriter.init(buffer);
    try writer.writeInt(u16, swarm_campaign_record_version);
    try writer.writeInt(u32, record.run_index);
    try writer.writeInt(u64, record.seed.value);
    try writer.writeInt(u32, record.variant_id);
    try writer.writeInt(u8, @intFromBool(record.passed));
    try writer.writeInt(u8, @intFromBool(record.retained_failure));
    try writer.writeOptionalString(record.persisted_entry_name);
    return writer.finish();
}

pub fn decodeCampaignRecordBinary(
    bytes: []const u8,
    entry_name_buffer: []u8,
) artifact.record_log.ArtifactRecordLogError!SwarmCampaignRecord {
    var reader = CampaignBufferReader.init(bytes, entry_name_buffer);
    const version = try reader.readInt(u16);
    if (version != swarm_campaign_record_version) return error.Unsupported;

    const record: SwarmCampaignRecord = .{
        .run_index = try reader.readInt(u32),
        .seed = .init(try reader.readInt(u64)),
        .variant_id = try reader.readInt(u32),
        .passed = (try reader.readInt(u8)) != 0,
        .retained_failure = (try reader.readInt(u8)) != 0,
        .persisted_entry_name = try reader.readOptionalString(),
    };
    try reader.finish();
    try validateCampaignRecord(record);
    return record;
}

pub fn appendCampaignRecordFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    max_records: usize,
    buffers: SwarmCampaignRecordAppendBuffers,
    record: SwarmCampaignRecord,
) artifact.record_log.ArtifactRecordLogError![]const u8 {
    const encoded = try encodeCampaignRecordBinary(buffers.record_buffer, record);
    return artifact.record_log.appendRecordFile(io, dir, sub_path, .{
        .existing_file_buffer = buffers.existing_file_buffer,
        .frame_buffer = buffers.frame_buffer,
        .output_file_buffer = buffers.output_file_buffer,
    }, max_records, encoded);
}

pub fn readMostRecentCampaignRecord(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: SwarmCampaignRecordReadBuffers,
) artifact.record_log.ArtifactRecordLogError!?SwarmCampaignRecord {
    const file_bytes = dir.readFile(io, sub_path, buffers.file_buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var iter = try artifact.record_log.iterateRecords(file_bytes);
    var latest_payload: ?[]const u8 = null;
    while (try iter.next()) |payload| latest_payload = payload;
    if (latest_payload) |payload| {
        return try decodeCampaignRecordBinary(payload, buffers.entry_name_buffer);
    }
    return null;
}

pub fn summarizeCampaignRecords(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: SwarmCampaignSummaryBuffers,
) artifact.record_log.ArtifactRecordLogError!?SwarmCampaignSummary {
    const file_bytes = dir.readFile(io, sub_path, buffers.file_buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var iter = try artifact.record_log.iterateRecords(file_bytes);

    var total_run_count: u32 = 0;
    var failed_run_count: u32 = 0;
    var retained_failure_count: u32 = 0;
    var first_run_index: ?u32 = null;
    var last_run_index: ?u32 = null;
    var variant_summary_count: usize = 0;
    var suggestion_count: usize = 0;

    while (try iter.next()) |payload| {
        const record = try decodeCampaignRecordBinary(payload, buffers.entry_name_buffer);
        total_run_count += 1;
        if (!record.passed) failed_run_count += 1;
        if (record.retained_failure) retained_failure_count += 1;
        if (first_run_index == null) first_run_index = record.run_index;
        last_run_index = record.run_index;

        const variant_summary = try findOrAppendVariantSummary(
            buffers.variant_summaries_buffer,
            &variant_summary_count,
            record.variant_id,
            record.run_index,
        );
        variant_summary.run_count += 1;
        variant_summary.last_run_index = record.run_index;
        if (!record.passed) {
            variant_summary.failed_run_count += 1;
            if (variant_summary.first_failed_run_index == null) {
                variant_summary.first_failed_run_index = record.run_index;
            }
        }
        if (record.retained_failure) {
            variant_summary.retained_failure_count += 1;
        }

        try updateRetentionSuggestion(
            buffers.retained_seed_suggestions_buffer,
            &suggestion_count,
            record,
        );
    }

    if (total_run_count == 0) return null;
    return .{
        .total_run_count = total_run_count,
        .failed_run_count = failed_run_count,
        .retained_failure_count = retained_failure_count,
        .first_run_index = first_run_index,
        .last_run_index = last_run_index,
        .variant_summaries = buffers.variant_summaries_buffer[0..variant_summary_count],
        .retained_seed_suggestions = buffers.retained_seed_suggestions_buffer[0..suggestion_count],
    };
}

pub fn formatCampaignSummary(
    buffer: []u8,
    summary: SwarmCampaignSummary,
) SwarmRunError![]const u8 {
    if (buffer.len == 0) return error.NoSpaceLeft;
    var used: usize = 0;
    used += (std.fmt.bufPrint(
        buffer[used..],
        "campaign runs={d} failed={d} retained={d} variants={d}",
        .{
            summary.total_run_count,
            summary.failed_run_count,
            summary.retained_failure_count,
            summary.variant_summaries.len,
        },
    ) catch return error.NoSpaceLeft).len;
    if (summary.first_run_index) |first_run_index| {
        used += (std.fmt.bufPrint(
            buffer[used..],
            " run_range={d}..{d}",
            .{ first_run_index, summary.last_run_index.? },
        ) catch return error.NoSpaceLeft).len;
    }
    for (summary.variant_summaries) |variant_summary| {
        used += (std.fmt.bufPrint(
            buffer[used..],
            "\nvariant={d} runs={d} failed={d} retained={d}",
            .{
                variant_summary.variant_id,
                variant_summary.run_count,
                variant_summary.failed_run_count,
                variant_summary.retained_failure_count,
            },
        ) catch return error.NoSpaceLeft).len;
        if (variant_summary.first_failed_run_index) |first_failed_run_index| {
            used += (std.fmt.bufPrint(
                buffer[used..],
                " first_failed_run={d}",
                .{first_failed_run_index},
            ) catch return error.NoSpaceLeft).len;
        }
    }
    for (summary.retained_seed_suggestions) |suggestion| {
        used += (std.fmt.bufPrint(
            buffer[used..],
            "\nsuggest variant={d} run={d} seed={s}",
            .{
                suggestion.variant_id,
                suggestion.run_index,
                seed_mod.formatSeed(suggestion.seed),
            },
        ) catch return error.NoSpaceLeft).len;
    }
    return buffer[0..used];
}

fn validateCampaignRecord(record: SwarmCampaignRecord) artifact.record_log.ArtifactRecordLogError!void {
    if (record.variant_id == 0) return error.InvalidInput;
    if (record.retained_failure and record.persisted_entry_name == null) return error.InvalidInput;
    if (record.persisted_entry_name) |entry_name| {
        if (entry_name.len == 0) return error.InvalidInput;
    }
}

fn findOrAppendVariantSummary(
    buffer: []SwarmCampaignVariantSummary,
    count: *usize,
    variant_id: u32,
    run_index: u32,
) artifact.record_log.ArtifactRecordLogError!*SwarmCampaignVariantSummary {
    for (buffer[0..count.*]) |*summary| {
        if (summary.variant_id == variant_id) return summary;
    }
    if (count.* >= buffer.len) return error.NoSpaceLeft;
    buffer[count.*] = .{
        .variant_id = variant_id,
        .run_count = 0,
        .failed_run_count = 0,
        .retained_failure_count = 0,
        .first_failed_run_index = null,
        .last_run_index = run_index,
    };
    count.* += 1;
    return &buffer[count.* - 1];
}

fn updateRetentionSuggestion(
    buffer: []SwarmRetainedSeedSuggestion,
    count: *usize,
    record: SwarmCampaignRecord,
) artifact.record_log.ArtifactRecordLogError!void {
    if (record.passed) return;

    var existing: ?*SwarmRetainedSeedSuggestion = null;
    for (buffer[0..count.*]) |*suggestion| {
        if (suggestion.variant_id == record.variant_id) {
            existing = suggestion;
            break;
        }
    }

    if (existing) |suggestion| {
        if (record.retained_failure) {
            suggestion.* = .{
                .variant_id = record.variant_id,
                .run_index = record.run_index,
                .seed = record.seed,
            };
        }
        return;
    }

    if (count.* >= buffer.len) return error.NoSpaceLeft;
    buffer[count.*] = .{
        .variant_id = record.variant_id,
        .run_index = record.run_index,
        .seed = record.seed,
    };
    count.* += 1;
}

fn persistCampaignRecord(
    campaign_persistence: ?SwarmCampaignPersistence,
    run_identity: identity.RunIdentity,
    variant: SwarmVariant,
    passed: bool,
    retained_failure: bool,
    persisted_entry_name: ?[]const u8,
) artifact.record_log.ArtifactRecordLogError!void {
    if (campaign_persistence) |persistence| {
        _ = try appendCampaignRecordFile(
            persistence.io,
            persistence.dir,
            persistence.sub_path,
            persistence.max_records,
            persistence.append_buffers,
            .{
                .run_index = run_identity.run_index,
                .seed = run_identity.seed,
                .variant_id = variant.variant_id,
                .passed = passed,
                .retained_failure = retained_failure,
                .persisted_entry_name = persisted_entry_name,
            },
        );
    }
}

fn makeFailureBundleContext(
    base_context: failure_bundle.FailureBundleContext,
    config: SwarmConfig,
    variant: SwarmVariant,
    run_identity: identity.RunIdentity,
    scenario_execution: SwarmScenarioExecution,
) failure_bundle.FailureBundleContext {
    var context = base_context;
    context.campaign_profile = @tagName(config.profile);
    context.scenario_variant_id = variant.variant_id;
    context.scenario_variant_label = variant.label;
    context.base_seed = config.base_seed;
    context.seed_lineage_run_index = run_identity.run_index;
    context.schedule_mode = scenario_execution.schedule_mode;
    context.schedule_seed = scenario_execution.schedule_seed;
    context.pending_reason = scenario_execution.pending_reason;
    if (context.trace_provenance_summary == null) {
        context.trace_provenance_summary = scenario_execution.trace_provenance_summary;
    }
    if (context.retained_trace_snapshot == null) {
        context.retained_trace_snapshot = scenario_execution.retained_trace_snapshot;
    }
    return context;
}

fn maybeReportProgress(
    progress: ?SwarmProgressReporter,
    config: SwarmConfig,
    summary: SwarmSummary,
    run_index: u32,
    variant: SwarmVariant,
    passed: bool,
) void {
    if (progress == null) return;
    if (config.progress_every_n_runs == 0) return;
    const local_completed_run_count = summary.executed_run_count;
    std.debug.assert(local_completed_run_count > 0);
    if ((local_completed_run_count % config.progress_every_n_runs) != 0) return;
    const completed_run_count = summary.resume_from_run_index + local_completed_run_count;

    progress.?.report(.{
        .profile = config.profile,
        .seed_count_max = config.seed_count_max,
        .shard_index = config.shard_index,
        .shard_count = config.shard_count,
        .resume_from_run_index = summary.resume_from_run_index,
        .completed_run_count = completed_run_count,
        .failed_run_count = summary.failed_run_count,
        .retained_failure_count = summary.retained_failure_count,
        .latest_run_index = run_index,
        .latest_variant_id = variant.variant_id,
        .latest_failed = !passed,
    });
}

fn ParallelLaneState(comptime ScenarioError: type) type {
    return struct {
        scenario: SwarmScenario(ScenarioError),
        input: SwarmScenarioInput,
        thread: ?std.Thread = null,
        result: ?(ScenarioError!SwarmScenarioExecution) = null,

        fn run(self: *@This()) void {
            self.result = self.scenario.run(self.input);
        }
    };
}

const CampaignBufferWriter = struct {
    buffer: []u8,
    index: usize = 0,

    fn init(buffer: []u8) CampaignBufferWriter {
        return .{ .buffer = buffer };
    }

    fn writeInt(self: *CampaignBufferWriter, comptime T: type, value: T) artifact.record_log.ArtifactRecordLogError!void {
        if (self.buffer.len - self.index < @sizeOf(T)) return error.NoSpaceLeft;
        std.mem.writeInt(T, self.buffer[self.index..][0..@sizeOf(T)], value, .little);
        self.index += @sizeOf(T);
    }

    fn writeOptionalString(self: *CampaignBufferWriter, value: ?[]const u8) artifact.record_log.ArtifactRecordLogError!void {
        const len: u16 = if (value) |text|
            std.math.cast(u16, text.len) orelse return error.Overflow
        else
            0;
        try self.writeInt(u16, len);
        if (value) |text| {
            if (self.buffer.len - self.index < text.len) return error.NoSpaceLeft;
            @memcpy(self.buffer[self.index .. self.index + text.len], text);
            self.index += text.len;
        }
    }

    fn finish(self: *const CampaignBufferWriter) []const u8 {
        return self.buffer[0..self.index];
    }
};

const CampaignBufferReader = struct {
    bytes: []const u8,
    index: usize = 0,
    entry_name_buffer: []u8,
    entry_name_len: usize = 0,

    fn init(bytes: []const u8, entry_name_buffer: []u8) CampaignBufferReader {
        return .{
            .bytes = bytes,
            .entry_name_buffer = entry_name_buffer,
        };
    }

    fn readInt(self: *CampaignBufferReader, comptime T: type) artifact.record_log.ArtifactRecordLogError!T {
        if (self.bytes.len - self.index < @sizeOf(T)) return error.CorruptData;
        const value = std.mem.readInt(T, self.bytes[self.index..][0..@sizeOf(T)], .little);
        self.index += @sizeOf(T);
        return value;
    }

    fn readOptionalString(self: *CampaignBufferReader) artifact.record_log.ArtifactRecordLogError!?[]const u8 {
        const len = try self.readInt(u16);
        if (len == 0) return null;
        if (self.bytes.len - self.index < len) return error.CorruptData;
        if (self.entry_name_buffer.len < len) return error.NoSpaceLeft;
        @memcpy(self.entry_name_buffer[0..len], self.bytes[self.index .. self.index + len]);
        self.index += len;
        self.entry_name_len = len;
        return self.entry_name_buffer[0..len];
    }

    fn finish(self: *const CampaignBufferReader) artifact.record_log.ArtifactRecordLogError!void {
        if (self.index != self.bytes.len) return error.CorruptData;
    }
};

test "runSwarm rejects invalid configs" {
    const variants = [_]SwarmVariant{
        .{ .variant_id = 1, .variant_weight = 1, .label = "default" },
    };
    const Scenario = SwarmScenario(error{});
    const Runner = SwarmRunner(error{});
    const Context = struct {
        fn run(_: *const anyopaque, _: SwarmScenarioInput) error{}!SwarmScenarioExecution {
            return .{
                .steps_executed = 1,
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = 1,
                    .last_sequence_no = 1,
                    .first_timestamp_ns = 1,
                    .last_timestamp_ns = 1,
                },
                .check_result = checker.CheckResult.pass(null),
            };
        }
    };
    const scenario = Scenario{
        .context = undefined,
        .run_fn = Context.run,
    };

    try std.testing.expectError(error.InvalidInput, runSwarm(error{}, Runner{
        .config = .{
            .package_name = "",
            .run_name = "invalid",
            .base_seed = seed_mod.Seed.init(1),
            .build_mode = .debug,
            .seed_count_max = 1,
            .steps_per_seed_max = 1,
        },
        .scenario = scenario,
        .variants = &variants,
    }));
    try std.testing.expectError(error.InvalidInput, runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "invalid",
            .base_seed = seed_mod.Seed.init(1),
            .build_mode = .debug,
            .seed_count_max = 1,
            .steps_per_seed_max = 1,
        },
        .scenario = scenario,
        .variants = &.{},
    }));
    try std.testing.expectError(error.InvalidInput, runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "invalid",
            .base_seed = seed_mod.Seed.init(1),
            .build_mode = .debug,
            .shard_count = 0,
            .seed_count_max = 1,
            .steps_per_seed_max = 1,
        },
        .scenario = scenario,
        .variants = &variants,
    }));
    try std.testing.expectError(error.InvalidInput, runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "invalid",
            .base_seed = seed_mod.Seed.init(1),
            .build_mode = .debug,
            .shard_index = 1,
            .shard_count = 1,
            .seed_count_max = 1,
            .steps_per_seed_max = 1,
        },
        .scenario = scenario,
        .variants = &variants,
    }));
    try std.testing.expectError(error.InvalidInput, runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "invalid",
            .base_seed = seed_mod.Seed.init(1),
            .build_mode = .debug,
            .seed_count_max = 1,
            .steps_per_seed_max = 1,
            .stop_policy = .stop_on_first_failure,
        },
        .scenario = scenario,
        .parallel_scenarios = &[_]Scenario{scenario},
        .variants = &variants,
    }));
    try std.testing.expectError(error.InvalidInput, runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "invalid",
            .base_seed = seed_mod.Seed.init(1),
            .build_mode = .debug,
            .seed_count_max = 1,
            .steps_per_seed_max = 1,
            .stop_policy = .collect_failures,
        },
        .scenario = scenario,
        .parallel_scenarios = &[_]Scenario{},
        .variants = &variants,
    }));
}

test "chooseVariant is deterministic for the same seed and run index" {
    const variants = [_]SwarmVariant{
        .{ .variant_id = 10, .variant_weight = 1, .label = "alpha" },
        .{ .variant_id = 20, .variant_weight = 3, .label = "beta" },
    };

    const first = try chooseVariant(seed_mod.Seed.init(55), 4, &variants);
    const second = try chooseVariant(seed_mod.Seed.init(55), 4, &variants);
    const third = try chooseVariant(seed_mod.Seed.init(55), 5, &variants);

    try std.testing.expectEqual(first.variant_id, second.variant_id);
    try std.testing.expectEqualStrings(first.label, second.label);
    try std.testing.expect(first.variant_id != 0);
    try std.testing.expect(third.variant_id != 0);
}

test "runSwarm stops on the first failure and persists one retained artifact" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const variants = [_]SwarmVariant{
        .{ .variant_id = 7, .variant_weight = 1, .label = "default" },
    };
    const Context = struct {
        const Self = @This();
        const violations = [_]checker.Violation{
            .{ .code = "failed", .message = "scenario failed" },
        };

        run_count: u32 = 0,

        fn run(context: *const anyopaque, input: SwarmScenarioInput) error{}!SwarmScenarioExecution {
            const typed_context: *Self = @ptrCast(@alignCast(@constCast(context)));
            typed_context.run_count += 1;
            _ = input;
            return .{
                .steps_executed = 2,
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = 2,
                    .last_sequence_no = 2,
                    .first_timestamp_ns = 10,
                    .last_timestamp_ns = 10,
                },
                .check_result = checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(9)),
            };
        }
    };
    var context: Context = .{};
    var artifact_buffer: [256]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    const Runner = SwarmRunner(error{});

    const summary = try runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_stop_first",
            .base_seed = seed_mod.Seed.init(5),
            .build_mode = .debug,
            .seed_count_max = 4,
            .steps_per_seed_max = 3,
            .failure_retention_max = 1,
            .stop_policy = .stop_on_first_failure,
        },
        .scenario = .{
            .context = &context,
            .run_fn = Context.run,
        },
        .variants = &variants,
        .failure_bundle_persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .entry_name_buffer = &entry_name_buffer,
            .artifact_buffer = &artifact_buffer,
            .manifest_buffer = &manifest_buffer,
            .trace_buffer = &trace_buffer,
            .violations_buffer = &violations_buffer,
        },
    });

    try std.testing.expectEqual(@as(u32, 1), context.run_count);
    try std.testing.expectEqual(@as(u32, 1), summary.executed_run_count);
    try std.testing.expectEqual(@as(u32, 1), summary.failed_run_count);
    try std.testing.expectEqual(@as(u32, 1), summary.retained_failure_count);
    try std.testing.expect(summary.first_failure != null);
    const first_failure = summary.first_failure.?;
    try std.testing.expectEqual(@as(u32, 7), first_failure.variant_id);
    try std.testing.expect(first_failure.persistedEntryName() != null);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse_buffer: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const entry = try failure_bundle.readFailureBundle(
        io,
        tmp_dir.dir,
        first_failure.persistedEntryName().?,
        .{
            .artifact_buffer = &read_artifact_buffer,
            .manifest_buffer = &read_manifest_buffer,
            .manifest_parse_buffer = &read_manifest_parse_buffer,
            .trace_buffer = &read_trace_buffer,
            .trace_parse_buffer = &read_trace_parse_buffer,
            .violations_buffer = &read_violations_buffer,
            .violations_parse_buffer = &read_violations_parse_buffer,
        },
    );
    try std.testing.expectEqual(first_failure.run_identity.seed.value, entry.replay_artifact_view.identity.seed.value);
    try std.testing.expectEqualStrings("smoke", entry.manifest_document.campaign_profile.?);
}

test "runSwarm can collect failures without losing the first retained name" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const variants = [_]SwarmVariant{
        .{ .variant_id = 1, .variant_weight = 1, .label = "alpha" },
        .{ .variant_id = 2, .variant_weight = 1, .label = "beta" },
    };
    const Context = struct {
        const violations = [_]checker.Violation{
            .{ .code = "failed", .message = "scenario failed" },
        };

        fn run(_: *const anyopaque, input: SwarmScenarioInput) error{}!SwarmScenarioExecution {
            const should_fail = input.run_identity.run_index == 1 or input.run_identity.run_index == 3;
            return .{
                .steps_executed = input.steps_per_seed_max,
                .trace_metadata = if (should_fail) .{
                    .event_count = 2,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = input.run_identity.run_index,
                    .last_sequence_no = input.run_identity.run_index + 1,
                    .first_timestamp_ns = input.run_identity.run_index,
                    .last_timestamp_ns = input.run_identity.run_index + 1,
                } else .{
                    .event_count = 0,
                    .truncated = false,
                    .has_range = false,
                    .first_sequence_no = 0,
                    .last_sequence_no = 0,
                    .first_timestamp_ns = 0,
                    .last_timestamp_ns = 0,
                },
                .check_result = if (should_fail)
                    checker.CheckResult.fail(&violations, checker.CheckpointDigest.init(1))
                else
                    checker.CheckResult.pass(checker.CheckpointDigest.init(2)),
            };
        }
    };
    var artifact_buffer: [256]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    const Runner = SwarmRunner(error{});

    const summary = try runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_collect",
            .base_seed = seed_mod.Seed.init(9),
            .build_mode = .debug,
            .profile = .stress,
            .seed_count_max = 5,
            .steps_per_seed_max = 4,
            .failure_retention_max = 2,
            .stop_policy = .collect_failures,
        },
        .scenario = .{
            .context = undefined,
            .run_fn = Context.run,
        },
        .variants = &variants,
        .failure_bundle_persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .entry_name_buffer = &entry_name_buffer,
            .artifact_buffer = &artifact_buffer,
            .manifest_buffer = &manifest_buffer,
            .trace_buffer = &trace_buffer,
            .violations_buffer = &violations_buffer,
        },
    });

    try std.testing.expectEqual(@as(u32, 5), summary.executed_run_count);
    try std.testing.expectEqual(@as(u32, 2), summary.failed_run_count);
    try std.testing.expectEqual(@as(u32, 2), summary.retained_failure_count);
    try std.testing.expect(summary.first_failure != null);
    const first_failure = summary.first_failure.?;
    try std.testing.expectEqual(@as(u32, 1), first_failure.run_identity.run_index);
    try std.testing.expect(first_failure.persistedEntryName() != null);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse_buffer: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const entry = try failure_bundle.readFailureBundle(
        io,
        tmp_dir.dir,
        first_failure.persistedEntryName().?,
        .{
            .artifact_buffer = &read_artifact_buffer,
            .manifest_buffer = &read_manifest_buffer,
            .manifest_parse_buffer = &read_manifest_parse_buffer,
            .trace_buffer = &read_trace_buffer,
            .trace_parse_buffer = &read_trace_parse_buffer,
            .violations_buffer = &read_violations_buffer,
            .violations_parse_buffer = &read_violations_parse_buffer,
        },
    );
    try std.testing.expectEqual(@as(u32, 1), entry.replay_artifact_view.identity.run_index);
    try std.testing.expectEqualStrings("stress", entry.manifest_document.campaign_profile.?);
}

test "runSwarm forwards caller-selected failure-bundle artifact policy" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const variants = [_]SwarmVariant{
        .{ .variant_id = 3, .variant_weight = 1, .label = "trimmed" },
    };
    const Context = struct {
        const violations = [_]checker.Violation{
            .{ .code = "failed", .message = "scenario failed" },
        };

        fn run(_: *const anyopaque, input: SwarmScenarioInput) error{}!SwarmScenarioExecution {
            _ = input;
            return .{
                .steps_executed = 1,
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = 9,
                    .last_sequence_no = 9,
                    .first_timestamp_ns = 9,
                    .last_timestamp_ns = 9,
                },
                .check_result = checker.CheckResult.fail(&violations, null),
            };
        }
    };
    var artifact_buffer: [256]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    const Runner = SwarmRunner(error{});

    const summary = try runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_trace_optional",
            .base_seed = seed_mod.Seed.init(13),
            .build_mode = .debug,
            .seed_count_max = 1,
            .steps_per_seed_max = 2,
            .failure_retention_max = 1,
            .stop_policy = .stop_on_first_failure,
        },
        .scenario = .{
            .context = undefined,
            .run_fn = Context.run,
        },
        .variants = &variants,
        .failure_bundle_persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .entry_name_buffer = &entry_name_buffer,
            .artifact_buffer = &artifact_buffer,
            .manifest_buffer = &manifest_buffer,
            .trace_buffer = &trace_buffer,
            .violations_buffer = &violations_buffer,
            .context = .{
                .artifact_selection = .{
                    .trace_artifact = .none,
                },
            },
        },
    });

    try std.testing.expect(summary.first_failure != null);
    const first_failure = summary.first_failure.?;
    try std.testing.expect(first_failure.persistedEntryName() != null);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse_buffer: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse_buffer: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse_buffer: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const entry = try failure_bundle.readFailureBundle(
        io,
        tmp_dir.dir,
        first_failure.persistedEntryName().?,
        .{
            .artifact_buffer = &read_artifact_buffer,
            .manifest_buffer = &read_manifest_buffer,
            .manifest_parse_buffer = &read_manifest_parse_buffer,
            .trace_buffer = &read_trace_buffer,
            .trace_parse_buffer = &read_trace_parse_buffer,
            .violations_buffer = &read_violations_buffer,
            .violations_parse_buffer = &read_violations_parse_buffer,
        },
    );
    try std.testing.expect(entry.manifest_document.trace_file == null);
    try std.testing.expect(entry.trace_document == null);
}

test "runSwarm reports deterministic progress on configured cadence" {
    const variants = [_]SwarmVariant{
        .{ .variant_id = 1, .variant_weight = 1, .label = "alpha" },
    };
    const Context = struct {
        const Self = @This();

        progress_count: u32 = 0,
        last_progress: ?SwarmProgress = null,

        fn run(_: *const anyopaque, input: SwarmScenarioInput) error{}!SwarmScenarioExecution {
            return .{
                .steps_executed = input.steps_per_seed_max,
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = input.run_identity.run_index,
                    .last_sequence_no = input.run_identity.run_index,
                    .first_timestamp_ns = input.run_identity.run_index,
                    .last_timestamp_ns = input.run_identity.run_index,
                },
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn report(context: *const anyopaque, progress: SwarmProgress) void {
            const typed_context: *Self = @ptrCast(@alignCast(@constCast(context)));
            typed_context.progress_count += 1;
            typed_context.last_progress = progress;
        }
    };
    var context: Context = .{};
    const Runner = SwarmRunner(error{});

    const summary = try runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_progress",
            .base_seed = seed_mod.Seed.init(2),
            .build_mode = .debug,
            .seed_count_max = 5,
            .steps_per_seed_max = 3,
            .progress_every_n_runs = 2,
            .stop_policy = .collect_failures,
        },
        .scenario = .{
            .context = undefined,
            .run_fn = Context.run,
        },
        .variants = &variants,
        .progress = .{
            .context = &context,
            .report_fn = Context.report,
        },
    });

    try std.testing.expectEqual(@as(u32, 5), summary.executed_run_count);
    try std.testing.expectEqual(@as(u32, 2), context.progress_count);
    try std.testing.expect(context.last_progress != null);
    try std.testing.expectEqual(@as(u32, 0), context.last_progress.?.shard_index);
    try std.testing.expectEqual(@as(u32, 1), context.last_progress.?.shard_count);
    try std.testing.expectEqual(@as(u32, 4), context.last_progress.?.completed_run_count);
    try std.testing.expectEqual(@as(u32, 0), context.last_progress.?.resume_from_run_index);
    try std.testing.expectEqual(@as(u32, 3), context.last_progress.?.latest_run_index);
}

test "formatProgressSummary produces stable plain text" {
    var buffer: [160]u8 = undefined;
    const summary = try formatProgressSummary(&buffer, .{
        .profile = .stress,
        .seed_count_max = 10,
        .shard_index = 0,
        .shard_count = 1,
        .resume_from_run_index = 0,
        .completed_run_count = 4,
        .failed_run_count = 1,
        .retained_failure_count = 1,
        .latest_run_index = 3,
        .latest_variant_id = 9,
        .latest_failed = true,
    });

    try std.testing.expectEqualStrings(
        "profile=stress shard=0/1 resume_from=0 completed=4/10 failed=1 retained=1 latest_run=3 latest_variant=9 latest_failed=true",
        summary,
    );
}

test "runSwarm executes only the configured deterministic shard" {
    const variants = [_]SwarmVariant{
        .{ .variant_id = 9, .variant_weight = 1, .label = "shard" },
    };
    const Context = struct {
        const Self = @This();

        run_indices: [3]u32 = .{ 999, 999, 999 },
        run_count: usize = 0,

        fn run(context: *const anyopaque, input: SwarmScenarioInput) error{}!SwarmScenarioExecution {
            const typed_context: *Self = @ptrCast(@alignCast(@constCast(context)));
            typed_context.run_indices[typed_context.run_count] = input.run_identity.run_index;
            typed_context.run_count += 1;
            return .{
                .steps_executed = input.steps_per_seed_max,
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = input.run_identity.run_index,
                    .last_sequence_no = input.run_identity.run_index,
                    .first_timestamp_ns = input.run_identity.run_index,
                    .last_timestamp_ns = input.run_identity.run_index,
                },
                .check_result = checker.CheckResult.pass(null),
            };
        }
    };
    var context: Context = .{};
    const Runner = SwarmRunner(error{});

    const summary = try runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_shard",
            .base_seed = seed_mod.Seed.init(3),
            .build_mode = .debug,
            .shard_index = 1,
            .shard_count = 2,
            .seed_count_max = 6,
            .steps_per_seed_max = 2,
            .stop_policy = .collect_failures,
        },
        .scenario = .{
            .context = &context,
            .run_fn = Context.run,
        },
        .variants = &variants,
    });

    try std.testing.expectEqual(@as(u32, 1), summary.shard_index);
    try std.testing.expectEqual(@as(u32, 2), summary.shard_count);
    try std.testing.expectEqual(@as(u32, 3), summary.executed_run_count);
    try std.testing.expectEqual(@as(usize, 3), context.run_count);
    try std.testing.expectEqual(@as(u32, 1), context.run_indices[0]);
    try std.testing.expectEqual(@as(u32, 3), context.run_indices[1]);
    try std.testing.expectEqual(@as(u32, 5), context.run_indices[2]);
}

test "runSwarm host-thread lanes commit failures in deterministic run order" {
    const variants = [_]SwarmVariant{
        .{ .variant_id = 4, .variant_weight = 1, .label = "parallel" },
    };
    const Scenario = SwarmScenario(error{});
    const Runner = SwarmRunner(error{});
    const LaneContext = struct {
        run_count: u32 = 0,
        seen_runs: [2]u32 = .{ 999, 999 },

        fn run(context: *const anyopaque, input: SwarmScenarioInput) error{}!SwarmScenarioExecution {
            const typed_context: *@This() = @ptrCast(@alignCast(@constCast(context)));
            typed_context.seen_runs[typed_context.run_count] = input.run_identity.run_index;
            typed_context.run_count += 1;
            return .{
                .steps_executed = input.steps_per_seed_max,
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = input.run_identity.run_index,
                    .last_sequence_no = input.run_identity.run_index,
                    .first_timestamp_ns = input.run_identity.run_index,
                    .last_timestamp_ns = input.run_identity.run_index,
                },
                .check_result = if (input.run_identity.run_index == 1)
                    checker.CheckResult.fail(
                        &[_]checker.Violation{
                            .{ .code = "parallel.failure", .message = "deterministic first failure" },
                        },
                        null,
                    )
                else
                    checker.CheckResult.pass(null),
            };
        }
    };
    var lane_a: LaneContext = .{};
    var lane_b: LaneContext = .{};
    const lanes = [_]Scenario{
        .{
            .context = &lane_a,
            .run_fn = LaneContext.run,
        },
        .{
            .context = &lane_b,
            .run_fn = LaneContext.run,
        },
    };

    const summary = try runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_parallel",
            .base_seed = seed_mod.Seed.init(23),
            .build_mode = .debug,
            .seed_count_max = 4,
            .steps_per_seed_max = 3,
            .stop_policy = .collect_failures,
        },
        .scenario = lanes[0],
        .parallel_scenarios = &lanes,
        .variants = &variants,
    });

    try std.testing.expectEqual(@as(u32, 4), summary.executed_run_count);
    try std.testing.expectEqual(@as(u32, 1), summary.failed_run_count);
    try std.testing.expect(summary.first_failure != null);
    try std.testing.expectEqual(@as(u32, 1), summary.first_failure.?.run_identity.run_index);
    try std.testing.expectEqual(@as(u32, 2), lane_a.run_count);
    try std.testing.expectEqual(@as(u32, 2), lane_b.run_count);
    try std.testing.expectEqual(@as(u32, 0), lane_a.seen_runs[0]);
    try std.testing.expectEqual(@as(u32, 2), lane_a.seen_runs[1]);
    try std.testing.expectEqual(@as(u32, 1), lane_b.seen_runs[0]);
    try std.testing.expectEqual(@as(u32, 3), lane_b.seen_runs[1]);
}

test "campaign record binary round-trips through shared storage format" {
    var buffer: [256]u8 = undefined;
    const encoded = try encodeCampaignRecordBinary(&buffer, .{
        .run_index = 7,
        .seed = seed_mod.Seed.init(41),
        .variant_id = 3,
        .passed = false,
        .retained_failure = true,
        .persisted_entry_name = "swarm_bundle-7.bundle",
    });

    var entry_name_buffer: [64]u8 = undefined;
    const decoded = try decodeCampaignRecordBinary(encoded, &entry_name_buffer);
    try std.testing.expectEqual(@as(u32, 7), decoded.run_index);
    try std.testing.expectEqual(@as(u64, 41), decoded.seed.value);
    try std.testing.expectEqual(@as(u32, 3), decoded.variant_id);
    try std.testing.expect(!decoded.passed);
    try std.testing.expect(decoded.retained_failure);
    try std.testing.expectEqualStrings("swarm_bundle-7.bundle", decoded.persisted_entry_name.?);
}

test "runSwarm resumes from the latest campaign record" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const variants = [_]SwarmVariant{
        .{ .variant_id = 5, .variant_weight = 1, .label = "resume" },
    };
    const Context = struct {
        const Self = @This();

        run_count: u32 = 0,
        first_run_index: ?u32 = null,

        fn run(context: *const anyopaque, input: SwarmScenarioInput) error{}!SwarmScenarioExecution {
            const typed_context: *Self = @ptrCast(@alignCast(@constCast(context)));
            typed_context.run_count += 1;
            if (typed_context.first_run_index == null) {
                typed_context.first_run_index = input.run_identity.run_index;
            }
            return .{
                .steps_executed = input.steps_per_seed_max,
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = input.run_identity.run_index,
                    .last_sequence_no = input.run_identity.run_index,
                    .first_timestamp_ns = input.run_identity.run_index,
                    .last_timestamp_ns = input.run_identity.run_index,
                },
                .check_result = checker.CheckResult.pass(null),
            };
        }
    };

    var existing_file_buffer: [1024]u8 = undefined;
    var record_buffer: [256]u8 = undefined;
    var frame_buffer: [256]u8 = undefined;
    var output_file_buffer: [1024]u8 = undefined;
    _ = try appendCampaignRecordFile(
        io,
        tmp_dir.dir,
        "swarm_campaign.binlog",
        8,
        .{
            .existing_file_buffer = &existing_file_buffer,
            .record_buffer = &record_buffer,
            .frame_buffer = &frame_buffer,
            .output_file_buffer = &output_file_buffer,
        },
        .{
            .run_index = 1,
            .seed = seed_mod.Seed.init(99),
            .variant_id = 5,
            .passed = true,
            .retained_failure = false,
        },
    );

    var read_file_buffer: [1024]u8 = undefined;
    var read_entry_name_buffer: [64]u8 = undefined;
    var context: Context = .{};
    const Runner = SwarmRunner(error{});

    const summary = try runSwarm(error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "swarm_resume",
            .base_seed = seed_mod.Seed.init(17),
            .build_mode = .debug,
            .seed_count_max = 4,
            .steps_per_seed_max = 2,
            .stop_policy = .collect_failures,
        },
        .scenario = .{
            .context = &context,
            .run_fn = Context.run,
        },
        .variants = &variants,
        .campaign_persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .resume_mode = .resume_if_present,
            .max_records = 8,
            .append_buffers = .{
                .existing_file_buffer = &existing_file_buffer,
                .record_buffer = &record_buffer,
                .frame_buffer = &frame_buffer,
                .output_file_buffer = &output_file_buffer,
            },
            .read_buffers = .{
                .file_buffer = &read_file_buffer,
                .entry_name_buffer = &read_entry_name_buffer,
            },
        },
    });

    try std.testing.expectEqual(@as(u32, 2), summary.resume_from_run_index);
    try std.testing.expectEqual(@as(u32, 2), summary.executed_run_count);
    try std.testing.expectEqual(@as(u32, 2), context.first_run_index.?);
    try std.testing.expectEqual(@as(u32, 2), context.run_count);

    const latest = (try readMostRecentCampaignRecord(io, tmp_dir.dir, "swarm_campaign.binlog", .{
        .file_buffer = &read_file_buffer,
        .entry_name_buffer = &read_entry_name_buffer,
    })).?;
    try std.testing.expectEqual(@as(u32, 3), latest.run_index);
    try std.testing.expect(latest.passed);
}

test "summarizeCampaignRecords groups variants and prefers retained failures" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var existing_file_buffer: [2048]u8 = undefined;
    var record_buffer: [256]u8 = undefined;
    var frame_buffer: [256]u8 = undefined;
    var output_file_buffer: [2048]u8 = undefined;
    var read_file_buffer: [2048]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    var variant_summaries_buffer: [4]SwarmCampaignVariantSummary = undefined;
    var retained_seed_suggestions_buffer: [4]SwarmRetainedSeedSuggestion = undefined;

    _ = try appendCampaignRecordFile(
        io,
        tmp_dir.dir,
        "swarm_campaign.binlog",
        16,
        .{
            .existing_file_buffer = &existing_file_buffer,
            .record_buffer = &record_buffer,
            .frame_buffer = &frame_buffer,
            .output_file_buffer = &output_file_buffer,
        },
        .{
            .run_index = 0,
            .seed = seed_mod.Seed.init(10),
            .variant_id = 1,
            .passed = true,
            .retained_failure = false,
        },
    );
    _ = try appendCampaignRecordFile(
        io,
        tmp_dir.dir,
        "swarm_campaign.binlog",
        16,
        .{
            .existing_file_buffer = &existing_file_buffer,
            .record_buffer = &record_buffer,
            .frame_buffer = &frame_buffer,
            .output_file_buffer = &output_file_buffer,
        },
        .{
            .run_index = 1,
            .seed = seed_mod.Seed.init(11),
            .variant_id = 2,
            .passed = false,
            .retained_failure = false,
        },
    );
    _ = try appendCampaignRecordFile(
        io,
        tmp_dir.dir,
        "swarm_campaign.binlog",
        16,
        .{
            .existing_file_buffer = &existing_file_buffer,
            .record_buffer = &record_buffer,
            .frame_buffer = &frame_buffer,
            .output_file_buffer = &output_file_buffer,
        },
        .{
            .run_index = 2,
            .seed = seed_mod.Seed.init(12),
            .variant_id = 1,
            .passed = false,
            .retained_failure = true,
            .persisted_entry_name = "swarm_bundle-2.bundle",
        },
    );
    _ = try appendCampaignRecordFile(
        io,
        tmp_dir.dir,
        "swarm_campaign.binlog",
        16,
        .{
            .existing_file_buffer = &existing_file_buffer,
            .record_buffer = &record_buffer,
            .frame_buffer = &frame_buffer,
            .output_file_buffer = &output_file_buffer,
        },
        .{
            .run_index = 3,
            .seed = seed_mod.Seed.init(13),
            .variant_id = 2,
            .passed = false,
            .retained_failure = true,
            .persisted_entry_name = "swarm_bundle-3.bundle",
        },
    );

    const summary = (try summarizeCampaignRecords(
        io,
        tmp_dir.dir,
        "swarm_campaign.binlog",
        .{
            .file_buffer = &read_file_buffer,
            .entry_name_buffer = &entry_name_buffer,
            .variant_summaries_buffer = &variant_summaries_buffer,
            .retained_seed_suggestions_buffer = &retained_seed_suggestions_buffer,
        },
    )).?;

    try std.testing.expectEqual(@as(u32, 4), summary.total_run_count);
    try std.testing.expectEqual(@as(u32, 3), summary.failed_run_count);
    try std.testing.expectEqual(@as(u32, 2), summary.retained_failure_count);
    try std.testing.expectEqual(@as(?u32, 0), summary.first_run_index);
    try std.testing.expectEqual(@as(?u32, 3), summary.last_run_index);
    try std.testing.expectEqual(@as(usize, 2), summary.variant_summaries.len);
    try std.testing.expectEqual(@as(u32, 1), summary.variant_summaries[0].variant_id);
    try std.testing.expectEqual(@as(u32, 2), summary.variant_summaries[0].run_count);
    try std.testing.expectEqual(@as(u32, 1), summary.variant_summaries[0].failed_run_count);
    try std.testing.expectEqual(@as(u32, 1), summary.variant_summaries[0].retained_failure_count);
    try std.testing.expectEqual(@as(?u32, 2), summary.variant_summaries[0].first_failed_run_index);
    try std.testing.expectEqual(@as(u32, 2), summary.variant_summaries[0].last_run_index);
    try std.testing.expectEqual(@as(u32, 2), summary.variant_summaries[1].variant_id);
    try std.testing.expectEqual(@as(u32, 2), summary.variant_summaries[1].run_count);
    try std.testing.expectEqual(@as(u32, 2), summary.variant_summaries[1].failed_run_count);
    try std.testing.expectEqual(@as(u32, 1), summary.variant_summaries[1].retained_failure_count);
    try std.testing.expectEqual(@as(?u32, 1), summary.variant_summaries[1].first_failed_run_index);
    try std.testing.expectEqual(@as(u32, 3), summary.variant_summaries[1].last_run_index);
    try std.testing.expectEqual(@as(usize, 2), summary.retained_seed_suggestions.len);
    try std.testing.expectEqual(@as(u32, 2), summary.retained_seed_suggestions[0].variant_id);
    try std.testing.expectEqual(@as(u32, 3), summary.retained_seed_suggestions[0].run_index);
    try std.testing.expectEqual(@as(u64, 13), summary.retained_seed_suggestions[0].seed.value);
    try std.testing.expectEqual(@as(u32, 1), summary.retained_seed_suggestions[1].variant_id);
    try std.testing.expectEqual(@as(u32, 2), summary.retained_seed_suggestions[1].run_index);
    try std.testing.expectEqual(@as(u64, 12), summary.retained_seed_suggestions[1].seed.value);
}

test "formatCampaignSummary produces stable plain text" {
    var buffer: [512]u8 = undefined;
    const summary = try formatCampaignSummary(&buffer, .{
        .total_run_count = 4,
        .failed_run_count = 3,
        .retained_failure_count = 2,
        .first_run_index = 0,
        .last_run_index = 3,
        .variant_summaries = &.{
            .{
                .variant_id = 1,
                .run_count = 2,
                .failed_run_count = 1,
                .retained_failure_count = 1,
                .first_failed_run_index = 2,
                .last_run_index = 2,
            },
            .{
                .variant_id = 2,
                .run_count = 2,
                .failed_run_count = 2,
                .retained_failure_count = 1,
                .first_failed_run_index = 1,
                .last_run_index = 3,
            },
        },
        .retained_seed_suggestions = &.{
            .{ .variant_id = 1, .run_index = 2, .seed = seed_mod.Seed.init(12) },
            .{ .variant_id = 2, .run_index = 3, .seed = seed_mod.Seed.init(13) },
        },
    });

    try std.testing.expectEqualStrings(
        "campaign runs=4 failed=3 retained=2 variants=2 run_range=0..3\n" ++
            "variant=1 runs=2 failed=1 retained=1 first_failed_run=2\n" ++
            "variant=2 runs=2 failed=2 retained=1 first_failed_run=1\n" ++
            "suggest variant=1 run=2 seed=0x000000000000000c\n" ++
            "suggest variant=2 run=3 seed=0x000000000000000d",
        summary,
    );
}
