//! Bounded schedule-exploration control plane over deterministic simulation primitives.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const artifact = @import("../../artifact/root.zig");
const checker = @import("../checker.zig");
const seed_mod = @import("../seed.zig");
const trace = @import("../trace.zig");
const scheduler = @import("scheduler.zig");

/// Public operating errors surfaced by exploration orchestration.
pub const ExplorationError = error{
    InvalidInput,
    NoSpaceLeft,
    Overflow,
    CorruptData,
    Unsupported,
} || std.Io.Dir.WriteFileError || std.Io.Dir.ReadFileError || std.Io.Dir.OpenError;

pub const exploration_record_version: u16 = 2;

/// Exploration modes intentionally kept narrow for the MVP.
pub const ExplorationMode = enum(u8) {
    portfolio = 1,
    pct_bias = 2,
};

/// Bounded portfolio exploration configuration.
pub const ExplorationConfig = struct {
    mode: ExplorationMode = .portfolio,
    base_seed: seed_mod.Seed,
    schedules_max: u32,
};

/// One deterministic schedule candidate emitted by the portfolio runner.
pub const ExplorationCandidate = struct {
    schedule_index: u32,
    scheduler_config: scheduler.SchedulerConfig,
    scheduler_seed: seed_mod.Seed,
    schedule_metadata: scheduler.ScheduleMetadata,
};

/// One scenario input prepared by the exploration runner.
pub const ExplorationScenarioInput = struct {
    candidate: ExplorationCandidate,
};

/// One scenario result returned to the exploration runner.
pub const ExplorationScenarioExecution = struct {
    check_result: checker.CheckResult,
    recorded_decisions: []const scheduler.ScheduleDecision,
    trace_metadata: ?trace.TraceMetadata = null,
    trace_provenance_summary: ?trace.TraceProvenanceSummary = null,
};

/// Caller-owned storage for retaining the first failing decision stream.
pub const ExplorationFailureStorage = struct {
    decision_buffer: []scheduler.ScheduleDecision,
};

/// Caller-owned buffers for retained exploration-record reads.
pub const ExplorationRecordReadBuffers = struct {
    selection: ExplorationRecordReadSelection = .{},
    file_buffer: []u8,
    mode_buffer: []u8,
    decision_buffer: []scheduler.ScheduleDecision = &.{},
};

pub const ExplorationDecisionArtifactRead = enum(u8) {
    metadata_only = 0,
    decisions = 1,
};

pub const ExplorationRecordReadSelection = struct {
    decision_artifact: ExplorationDecisionArtifactRead = .decisions,

    pub fn readDecisions(self: @This()) bool {
        return self.decision_artifact == .decisions;
    }
};

/// Caller-owned buffers for retained exploration-record appends.
pub const ExplorationRecordAppendBuffers = struct {
    existing_file_buffer: []u8,
    record_buffer: []u8,
    frame_buffer: []u8,
    output_file_buffer: []u8,
};

/// One retained failing exploration record.
pub const ExplorationFailureRecord = struct {
    schedule_index: u32,
    schedule_mode: []const u8,
    schedule_seed: ?seed_mod.Seed,
    recorded_decision_count: u32,
    recorded_decisions: []const scheduler.ScheduleDecision,
    trace_metadata: ?trace.TraceMetadata = null,
    trace_provenance_summary: ?trace.TraceProvenanceSummary = null,
};

/// Aggregate result for one exploration campaign.
pub const ExplorationSummary = struct {
    executed_schedule_count: u32,
    failed_schedule_count: u32,
    first_failure: ?ExplorationFailureRecord,
};

/// Deterministic scenario callback contract for exploration.
pub fn ExplorationScenario(comptime ScenarioError: type) type {
    return struct {
        context: *const anyopaque,
        run_fn: *const fn (
            context: *const anyopaque,
            input: ExplorationScenarioInput,
        ) ScenarioError!ExplorationScenarioExecution,

        pub fn run(
            self: @This(),
            input: ExplorationScenarioInput,
        ) ScenarioError!ExplorationScenarioExecution {
            return self.run_fn(self.context, input);
        }
    };
}

/// Execute one bounded portfolio exploration campaign.
pub fn runExploration(
    comptime ScenarioError: type,
    config: ExplorationConfig,
    scenario: ExplorationScenario(ScenarioError),
    failure_storage: ?ExplorationFailureStorage,
) (ExplorationError || ScenarioError)!ExplorationSummary {
    try validateConfig(config);

    var summary: ExplorationSummary = .{
        .executed_schedule_count = 0,
        .failed_schedule_count = 0,
        .first_failure = null,
    };
    var schedule_index: u32 = 0;
    while (schedule_index < config.schedules_max) : (schedule_index += 1) {
        const candidate = makeCandidate(config, schedule_index);
        const execution = try scenario.run(.{ .candidate = candidate });
        assertExecution(execution);

        summary.executed_schedule_count += 1;
        if (execution.check_result.passed) continue;

        summary.failed_schedule_count += 1;
        if (summary.first_failure == null and failure_storage != null) {
            summary.first_failure = try retainFailure(candidate, execution, failure_storage.?);
        }
    }

    return summary;
}

/// Format one deterministic plain-text exploration summary.
pub fn formatExplorationSummary(
    buffer: []u8,
    summary: ExplorationSummary,
) ExplorationError![]const u8 {
    if (buffer.len == 0) return error.NoSpaceLeft;

    if (summary.first_failure) |first_failure| {
        return std.fmt.bufPrint(
            buffer,
            "executed={d} failed={d} first_mode={s} first_schedule={d} first_decisions={d}",
            .{
                summary.executed_schedule_count,
                summary.failed_schedule_count,
                first_failure.schedule_mode,
                first_failure.schedule_index,
                first_failure.recorded_decision_count,
            },
        ) catch return error.NoSpaceLeft;
    }

    return std.fmt.bufPrint(
        buffer,
        "executed={d} failed={d} first_mode=none",
        .{
            summary.executed_schedule_count,
            summary.failed_schedule_count,
        },
    ) catch return error.NoSpaceLeft;
}

/// Encode one retained exploration failure record to the shared binary format.
pub fn encodeFailureRecordBinary(
    buffer: []u8,
    record: ExplorationFailureRecord,
) ExplorationError![]const u8 {
    try validateFailureRecord(record);

    var writer = BufferWriter.init(buffer);
    try writer.writeInt(u16, exploration_record_version);
    try writer.writeInt(u32, record.schedule_index);
    try writer.writeString(record.schedule_mode);
    try writer.writeOptionalSeed(record.schedule_seed);
    try writer.writeInt(u32, std.math.cast(u32, record.recorded_decisions.len) orelse return error.Overflow);
    try writer.writeTraceSummary(record.trace_metadata, record.trace_provenance_summary);
    for (record.recorded_decisions) |decision| {
        try writer.writeInt(u32, decision.step_index);
        try writer.writeInt(u32, decision.chosen_index);
        try writer.writeInt(u32, decision.ready_len);
        try writer.writeInt(u32, decision.chosen_id);
        try writer.writeInt(u64, decision.chosen_value);
    }
    return writer.finish();
}

/// Decode one retained exploration failure record from the shared binary format.
pub fn decodeFailureRecordBinary(
    bytes: []const u8,
    mode_buffer: []u8,
    decision_buffer: []scheduler.ScheduleDecision,
) ExplorationError!ExplorationFailureRecord {
    var reader = BufferReader.init(bytes, mode_buffer);
    const version = try reader.readInt(u16);
    if (version != exploration_record_version) return error.Unsupported;

    const schedule_index = try reader.readInt(u32);
    const schedule_mode = try reader.readString();
    const schedule_seed = try reader.readOptionalSeed();
    const decision_count = try reader.readInt(u32);
    const trace_summary = try reader.readTraceSummary();
    const include_decisions = decision_buffer.len != 0;
    if (include_decisions and decision_count > decision_buffer.len) return error.NoSpaceLeft;

    var decision_index: usize = 0;
    while (decision_index < decision_count) : (decision_index += 1) {
        const decision: scheduler.ScheduleDecision = .{
            .step_index = try reader.readInt(u32),
            .chosen_index = try reader.readInt(u32),
            .ready_len = try reader.readInt(u32),
            .chosen_id = try reader.readInt(u32),
            .chosen_value = try reader.readInt(u64),
        };
        if (include_decisions) {
            decision_buffer[decision_index] = decision;
        }
    }
    try reader.finish();

    const record: ExplorationFailureRecord = .{
        .schedule_index = schedule_index,
        .schedule_mode = schedule_mode,
        .schedule_seed = schedule_seed,
        .recorded_decision_count = decision_count,
        .recorded_decisions = if (include_decisions) decision_buffer[0..decision_count] else &.{},
        .trace_metadata = trace_summary.metadata,
        .trace_provenance_summary = trace_summary.provenance_summary,
    };
    try validateFailureRecord(record);
    return record;
}

/// Append one retained exploration failure record to the shared binary record log.
pub fn appendFailureRecordFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: ExplorationRecordAppendBuffers,
    max_records: usize,
    record: ExplorationFailureRecord,
) ExplorationError![]const u8 {
    const encoded = try encodeFailureRecordBinary(buffers.record_buffer, record);
    return artifact.record_log.appendRecordFile(
        io,
        dir,
        sub_path,
        .{
            .existing_file_buffer = buffers.existing_file_buffer,
            .frame_buffer = buffers.frame_buffer,
            .output_file_buffer = buffers.output_file_buffer,
        },
        max_records,
        encoded,
    );
}

/// Read the most recent retained exploration failure record from the shared binary record log.
pub fn readMostRecentFailureRecord(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: ExplorationRecordReadBuffers,
) ExplorationError!?ExplorationFailureRecord {
    const file_bytes = try artifact.record_log.readLogFile(io, dir, sub_path, buffers.file_buffer);
    var iter = try artifact.record_log.iterateRecords(file_bytes);

    var latest_payload: ?[]const u8 = null;
    while (try iter.next()) |payload| latest_payload = payload;
    if (latest_payload) |payload| {
        if (buffers.selection.readDecisions() and buffers.decision_buffer.len == 0) return error.InvalidInput;
        return try decodeFailureRecordBinary(
            payload,
            buffers.mode_buffer,
            if (buffers.selection.readDecisions()) buffers.decision_buffer else &.{},
        );
    }
    return null;
}

fn validateConfig(config: ExplorationConfig) ExplorationError!void {
    if (config.schedules_max == 0) return error.InvalidInput;
}

fn validateFailureRecord(record: ExplorationFailureRecord) ExplorationError!void {
    if (record.schedule_mode.len == 0) return error.InvalidInput;
    if (record.schedule_seed == null and !std.mem.eql(u8, record.schedule_mode, "first")) return error.InvalidInput;
    if (record.trace_provenance_summary != null and record.trace_metadata == null) return error.InvalidInput;
    for (record.recorded_decisions, 0..) |decision, decision_index| {
        if (decision.step_index != decision_index) return error.InvalidInput;
        if (decision.chosen_index >= decision.ready_len) return error.InvalidInput;
    }
}

fn makeCandidate(
    config: ExplorationConfig,
    schedule_index: u32,
) ExplorationCandidate {
    return switch (config.mode) {
        .portfolio => makePortfolioCandidate(config.base_seed, schedule_index),
        .pct_bias => makePctBiasCandidate(config.base_seed, schedule_index),
    };
}

fn makePortfolioCandidate(
    base_seed: seed_mod.Seed,
    schedule_index: u32,
) ExplorationCandidate {
    if (schedule_index == 0) {
        const scheduler_config: scheduler.SchedulerConfig = .{ .strategy = .first };
        return .{
            .schedule_index = schedule_index,
            .scheduler_config = scheduler_config,
            .scheduler_seed = base_seed,
            .schedule_metadata = scheduler.describeSchedule(base_seed, scheduler_config),
        };
    }

    const scheduler_seed = seed_mod.splitSeed(base_seed, schedule_index);
    const scheduler_config: scheduler.SchedulerConfig = .{ .strategy = .seeded };
    return .{
        .schedule_index = schedule_index,
        .scheduler_config = scheduler_config,
        .scheduler_seed = scheduler_seed,
        .schedule_metadata = scheduler.describeSchedule(scheduler_seed, scheduler_config),
    };
}

fn makePctBiasCandidate(
    base_seed: seed_mod.Seed,
    schedule_index: u32,
) ExplorationCandidate {
    const scheduler_seed = seed_mod.splitSeed(base_seed, schedule_index);
    const scheduler_config: scheduler.SchedulerConfig = .{
        .strategy = .pct_bias,
        .pct_preemption_step = schedule_index,
    };
    return .{
        .schedule_index = schedule_index,
        .scheduler_config = scheduler_config,
        .scheduler_seed = scheduler_seed,
        .schedule_metadata = scheduler.describeSchedule(scheduler_seed, scheduler_config),
    };
}

fn assertExecution(execution: ExplorationScenarioExecution) void {
    if (execution.check_result.passed) {
        assert(execution.check_result.violations.len == 0);
    } else {
        assert(execution.check_result.violations.len > 0);
    }
    if (execution.trace_provenance_summary != null) {
        assert(execution.trace_metadata != null);
    }
}

fn retainFailure(
    candidate: ExplorationCandidate,
    execution: ExplorationScenarioExecution,
    failure_storage: ExplorationFailureStorage,
) ExplorationError!ExplorationFailureRecord {
    const recorded_decisions = execution.recorded_decisions;
    if (recorded_decisions.len > failure_storage.decision_buffer.len) return error.NoSpaceLeft;

    @memcpy(failure_storage.decision_buffer[0..recorded_decisions.len], recorded_decisions);
    return .{
        .schedule_index = candidate.schedule_index,
        .schedule_mode = candidate.schedule_metadata.mode_label,
        .schedule_seed = candidate.schedule_metadata.schedule_seed,
        .recorded_decision_count = @intCast(recorded_decisions.len),
        .recorded_decisions = failure_storage.decision_buffer[0..recorded_decisions.len],
        .trace_metadata = execution.trace_metadata,
        .trace_provenance_summary = execution.trace_provenance_summary,
    };
}

const null_seed_tag = std.math.maxInt(u64);

const BufferWriter = struct {
    buffer: []u8,
    position: usize = 0,

    fn init(buffer: []u8) BufferWriter {
        return .{ .buffer = buffer };
    }

    fn writeInt(self: *BufferWriter, comptime T: type, value: T) ExplorationError!void {
        if (self.buffer.len - self.position < @sizeOf(T)) return error.NoSpaceLeft;
        std.mem.writeInt(T, self.buffer[self.position..][0..@sizeOf(T)], value, .little);
        self.position += @sizeOf(T);
    }

    fn writeString(self: *BufferWriter, text: []const u8) ExplorationError!void {
        try self.writeInt(u32, std.math.cast(u32, text.len) orelse return error.Overflow);
        if (self.buffer.len - self.position < text.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.position .. self.position + text.len], text);
        self.position += text.len;
    }

    fn writeOptionalSeed(self: *BufferWriter, seed: ?seed_mod.Seed) ExplorationError!void {
        try self.writeInt(u64, if (seed) |value| value.value else null_seed_tag);
    }

    fn writeTraceSummary(
        self: *BufferWriter,
        metadata: ?trace.TraceMetadata,
        provenance_summary: ?trace.TraceProvenanceSummary,
    ) ExplorationError!void {
        const flags: u8 = @intFromBool(metadata != null) | (@as(u8, @intFromBool(provenance_summary != null)) << 1);
        try self.writeInt(u8, flags);
        if (metadata) |value| {
            try self.writeTraceMetadata(value);
        }
        if (provenance_summary) |value| {
            try self.writeTraceProvenanceSummary(value);
        }
    }

    fn writeTraceMetadata(self: *BufferWriter, metadata: trace.TraceMetadata) ExplorationError!void {
        try self.writeInt(u32, metadata.event_count);
        try self.writeInt(u8, @intFromBool(metadata.truncated));
        try self.writeInt(u8, @intFromBool(metadata.has_range));
        try self.writeInt(u32, metadata.first_sequence_no);
        try self.writeInt(u32, metadata.last_sequence_no);
        try self.writeInt(u64, metadata.first_timestamp_ns);
        try self.writeInt(u64, metadata.last_timestamp_ns);
    }

    fn writeTraceProvenanceSummary(
        self: *BufferWriter,
        summary: trace.TraceProvenanceSummary,
    ) ExplorationError!void {
        try self.writeInt(u8, @intFromBool(summary.has_provenance));
        try self.writeInt(u32, summary.caused_event_count);
        try self.writeInt(u32, summary.root_event_count);
        try self.writeInt(u32, summary.correlated_event_count);
        try self.writeInt(u32, summary.surface_labeled_event_count);
        try self.writeInt(u16, summary.max_causal_depth);
    }

    fn finish(self: *const BufferWriter) []const u8 {
        return self.buffer[0..self.position];
    }
};

const BufferReader = struct {
    bytes: []const u8,
    index: usize = 0,
    mode_buffer: []u8,
    mode_buffer_len: usize = 0,

    fn init(bytes: []const u8, mode_buffer: []u8) BufferReader {
        return .{
            .bytes = bytes,
            .mode_buffer = mode_buffer,
        };
    }

    fn readInt(self: *BufferReader, comptime T: type) ExplorationError!T {
        if (self.bytes.len - self.index < @sizeOf(T)) return error.CorruptData;
        const value = std.mem.readInt(T, self.bytes[self.index..][0..@sizeOf(T)], .little);
        self.index += @sizeOf(T);
        return value;
    }

    fn readString(self: *BufferReader) ExplorationError![]const u8 {
        const len = try self.readInt(u32);
        const text_len: usize = len;
        if (self.bytes.len - self.index < text_len) return error.CorruptData;
        if (self.mode_buffer.len - self.mode_buffer_len < text_len) return error.NoSpaceLeft;
        const start = self.mode_buffer_len;
        @memcpy(
            self.mode_buffer[start .. start + text_len],
            self.bytes[self.index .. self.index + text_len],
        );
        self.index += text_len;
        self.mode_buffer_len += text_len;
        return self.mode_buffer[start .. start + text_len];
    }

    fn readOptionalSeed(self: *BufferReader) ExplorationError!?seed_mod.Seed {
        const raw = try self.readInt(u64);
        if (raw == null_seed_tag) return null;
        return .init(raw);
    }

    fn readTraceSummary(self: *BufferReader) ExplorationError!struct {
        metadata: ?trace.TraceMetadata,
        provenance_summary: ?trace.TraceProvenanceSummary,
    } {
        const flags = try self.readInt(u8);
        return .{
            .metadata = if ((flags & 0b01) != 0) try self.readTraceMetadata() else null,
            .provenance_summary = if ((flags & 0b10) != 0) try self.readTraceProvenanceSummary() else null,
        };
    }

    fn readTraceMetadata(self: *BufferReader) ExplorationError!trace.TraceMetadata {
        return .{
            .event_count = try self.readInt(u32),
            .truncated = (try self.readInt(u8)) != 0,
            .has_range = (try self.readInt(u8)) != 0,
            .first_sequence_no = try self.readInt(u32),
            .last_sequence_no = try self.readInt(u32),
            .first_timestamp_ns = try self.readInt(u64),
            .last_timestamp_ns = try self.readInt(u64),
        };
    }

    fn readTraceProvenanceSummary(self: *BufferReader) ExplorationError!trace.TraceProvenanceSummary {
        return .{
            .has_provenance = (try self.readInt(u8)) != 0,
            .caused_event_count = try self.readInt(u32),
            .root_event_count = try self.readInt(u32),
            .correlated_event_count = try self.readInt(u32),
            .surface_labeled_event_count = try self.readInt(u32),
            .max_causal_depth = try self.readInt(u16),
        };
    }

    fn finish(self: *const BufferReader) ExplorationError!void {
        if (self.index != self.bytes.len) return error.CorruptData;
    }
};

test "runExploration rejects zero schedules" {
    const Context = struct {
        fn run(_: *const anyopaque, _: ExplorationScenarioInput) error{}!ExplorationScenarioExecution {
            unreachable;
        }
    };
    const scenario = ExplorationScenario(error{}){
        .context = undefined,
        .run_fn = Context.run,
    };

    try testing.expectError(error.InvalidInput, runExploration(error{}, .{
        .base_seed = .init(1),
        .schedules_max = 0,
    }, scenario, null));
}

test "portfolio candidate starts with first and then seeded schedules" {
    const config: ExplorationConfig = .{
        .base_seed = .init(7),
        .schedules_max = 3,
    };

    const first_candidate = makeCandidate(config, 0);
    const seeded_candidate = makeCandidate(config, 1);

    try testing.expectEqualStrings("first", first_candidate.schedule_metadata.mode_label);
    try testing.expect(first_candidate.schedule_metadata.schedule_seed == null);
    try testing.expectEqualStrings("seeded", seeded_candidate.schedule_metadata.mode_label);
    try testing.expect(seeded_candidate.schedule_metadata.schedule_seed != null);
    try testing.expectEqual(@as(u64, seeded_candidate.scheduler_seed.value), seeded_candidate.schedule_metadata.schedule_seed.?.value);
}

test "pct bias candidate carries deterministic preemption metadata in the scheduler config" {
    const config: ExplorationConfig = .{
        .mode = .pct_bias,
        .base_seed = .init(11),
        .schedules_max = 3,
    };

    const candidate = makeCandidate(config, 2);

    try testing.expectEqual(@as(u32, 2), candidate.schedule_index);
    try testing.expectEqual(scheduler.SchedulerStrategy.pct_bias, candidate.scheduler_config.strategy);
    try testing.expectEqual(@as(u32, 2), candidate.scheduler_config.pct_preemption_step);
    try testing.expectEqualStrings("pct_bias", candidate.schedule_metadata.mode_label);
    try testing.expect(candidate.schedule_metadata.schedule_seed != null);
    try testing.expectEqual(candidate.scheduler_seed.value, candidate.schedule_metadata.schedule_seed.?.value);
}

test "runExploration retains the first failing decision stream" {
    const Context = struct {
        const violations = [_]checker.Violation{
            .{ .code = "explore.failed", .message = "seeded mode is retained" },
        };
        const decisions = [_]scheduler.ScheduleDecision{
            .{
                .step_index = 0,
                .chosen_index = 0,
                .ready_len = 2,
                .chosen_id = 22,
                .chosen_value = 1,
            },
        };

        fn run(_: *const anyopaque, input: ExplorationScenarioInput) error{}!ExplorationScenarioExecution {
            return .{
                .check_result = if (std.mem.eql(u8, input.candidate.schedule_metadata.mode_label, "seeded"))
                    checker.CheckResult.fail(&violations, null)
                else
                    checker.CheckResult.pass(null),
                .recorded_decisions = &decisions,
                .trace_metadata = .{
                    .event_count = 2,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = 1,
                    .last_sequence_no = 2,
                    .first_timestamp_ns = 10,
                    .last_timestamp_ns = 11,
                },
                .trace_provenance_summary = .{
                    .has_provenance = true,
                    .caused_event_count = 1,
                    .root_event_count = 1,
                    .correlated_event_count = 1,
                    .surface_labeled_event_count = 1,
                    .max_causal_depth = 1,
                },
            };
        }
    };
    const scenario = ExplorationScenario(error{}){
        .context = undefined,
        .run_fn = Context.run,
    };
    var decision_buffer: [4]scheduler.ScheduleDecision = undefined;

    const summary = try runExploration(error{}, .{
        .base_seed = .init(9),
        .schedules_max = 3,
    }, scenario, .{
        .decision_buffer = &decision_buffer,
    });

    try testing.expectEqual(@as(u32, 3), summary.executed_schedule_count);
    try testing.expectEqual(@as(u32, 2), summary.failed_schedule_count);
    try testing.expect(summary.first_failure != null);
    try testing.expectEqualStrings("seeded", summary.first_failure.?.schedule_mode);
    try testing.expectEqual(@as(u32, 1), summary.first_failure.?.schedule_index);
    try testing.expectEqual(@as(u32, 1), summary.first_failure.?.recorded_decision_count);
    try testing.expectEqual(@as(usize, 1), summary.first_failure.?.recorded_decisions.len);
    try testing.expectEqual(@as(u32, 22), summary.first_failure.?.recorded_decisions[0].chosen_id);
    try testing.expect(summary.first_failure.?.trace_metadata != null);
    try testing.expect(summary.first_failure.?.trace_provenance_summary != null);
}

test "formatExplorationSummary produces stable plain text" {
    var buffer: [160]u8 = undefined;
    const decisions = [_]scheduler.ScheduleDecision{
        .{
            .step_index = 0,
            .chosen_index = 1,
            .ready_len = 2,
            .chosen_id = 22,
            .chosen_value = 2,
        },
    };
    const summary: ExplorationSummary = .{
        .executed_schedule_count = 4,
        .failed_schedule_count = 1,
        .first_failure = .{
            .schedule_index = 1,
            .schedule_mode = "seeded",
            .schedule_seed = .init(5),
            .recorded_decision_count = 1,
            .recorded_decisions = &decisions,
        },
    };

    const text = try formatExplorationSummary(&buffer, summary);
    try testing.expectEqualStrings(
        "executed=4 failed=1 first_mode=seeded first_schedule=1 first_decisions=1",
        text,
    );
}

test "failure record binary round-trips through shared storage format" {
    const decisions = [_]scheduler.ScheduleDecision{
        .{
            .step_index = 0,
            .chosen_index = 1,
            .ready_len = 2,
            .chosen_id = 22,
            .chosen_value = 2,
        },
        .{
            .step_index = 1,
            .chosen_index = 0,
            .ready_len = 1,
            .chosen_id = 11,
            .chosen_value = 1,
        },
    };
    var buffer: [256]u8 = undefined;
    const encoded = try encodeFailureRecordBinary(&buffer, .{
        .schedule_index = 3,
        .schedule_mode = "seeded",
        .schedule_seed = .init(19),
        .recorded_decision_count = 2,
        .recorded_decisions = &decisions,
        .trace_metadata = .{
            .event_count = 2,
            .truncated = false,
            .has_range = true,
            .first_sequence_no = 4,
            .last_sequence_no = 5,
            .first_timestamp_ns = 20,
            .last_timestamp_ns = 21,
        },
        .trace_provenance_summary = .{
            .has_provenance = true,
            .caused_event_count = 1,
            .root_event_count = 1,
            .correlated_event_count = 1,
            .surface_labeled_event_count = 1,
            .max_causal_depth = 1,
        },
    });

    var mode_buffer: [32]u8 = undefined;
    var decoded_decisions: [4]scheduler.ScheduleDecision = undefined;
    const decoded = try decodeFailureRecordBinary(encoded, &mode_buffer, &decoded_decisions);
    try testing.expectEqual(@as(u32, 3), decoded.schedule_index);
    try testing.expectEqualStrings("seeded", decoded.schedule_mode);
    try testing.expect(decoded.schedule_seed != null);
    try testing.expectEqual(@as(u64, 19), decoded.schedule_seed.?.value);
    try testing.expectEqual(@as(u32, 2), decoded.recorded_decision_count);
    try testing.expectEqual(@as(usize, 2), decoded.recorded_decisions.len);
    try testing.expectEqual(@as(u32, 22), decoded.recorded_decisions[0].chosen_id);
    try testing.expect(decoded.trace_metadata != null);
    try testing.expect(decoded.trace_provenance_summary != null);
    try testing.expect(decoded.trace_provenance_summary.?.has_provenance);
}

test "failure record binary rejects unsupported version" {
    const decisions = [_]scheduler.ScheduleDecision{
        .{
            .step_index = 0,
            .chosen_index = 0,
            .ready_len = 1,
            .chosen_id = 11,
            .chosen_value = 1,
        },
    };

    var encoded_buffer: [256]u8 = undefined;
    const encoded = try encodeFailureRecordBinary(&encoded_buffer, .{
        .schedule_index = 1,
        .schedule_mode = "seeded",
        .schedule_seed = .init(55),
        .recorded_decision_count = 1,
        .recorded_decisions = &decisions,
    });
    std.mem.writeInt(u16, encoded_buffer[0..@sizeOf(u16)], exploration_record_version + 1, .little);

    var mode_buffer: [16]u8 = undefined;
    var decoded_decisions: [1]scheduler.ScheduleDecision = undefined;
    try testing.expectError(
        error.Unsupported,
        decodeFailureRecordBinary(encoded[0..encoded.len], &mode_buffer, &decoded_decisions),
    );
}

test "failure record log retains bounded latest record" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const decisions = [_]scheduler.ScheduleDecision{
        .{
            .step_index = 0,
            .chosen_index = 0,
            .ready_len = 1,
            .chosen_id = 11,
            .chosen_value = 1,
        },
    };

    var existing_file_buffer: [512]u8 = undefined;
    var record_buffer: [256]u8 = undefined;
    var frame_buffer: [256]u8 = undefined;
    var output_file_buffer: [512]u8 = undefined;
    const append_buffers: ExplorationRecordAppendBuffers = .{
        .existing_file_buffer = &existing_file_buffer,
        .record_buffer = &record_buffer,
        .frame_buffer = &frame_buffer,
        .output_file_buffer = &output_file_buffer,
    };

    _ = try appendFailureRecordFile(io, tmp_dir.dir, "exploration_failures.binlog", append_buffers, 2, .{
        .schedule_index = 1,
        .schedule_mode = "seeded",
        .schedule_seed = .init(7),
        .recorded_decision_count = 1,
        .recorded_decisions = &decisions,
    });
    _ = try appendFailureRecordFile(io, tmp_dir.dir, "exploration_failures.binlog", append_buffers, 2, .{
        .schedule_index = 2,
        .schedule_mode = "seeded",
        .schedule_seed = .init(9),
        .recorded_decision_count = 1,
        .recorded_decisions = &decisions,
    });
    _ = try appendFailureRecordFile(io, tmp_dir.dir, "exploration_failures.binlog", append_buffers, 2, .{
        .schedule_index = 3,
        .schedule_mode = "seeded",
        .schedule_seed = .init(11),
        .recorded_decision_count = 1,
        .recorded_decisions = &decisions,
    });

    var file_buffer: [512]u8 = undefined;
    var mode_buffer: [32]u8 = undefined;
    var decision_buffer: [2]scheduler.ScheduleDecision = undefined;
    const latest = (try readMostRecentFailureRecord(io, tmp_dir.dir, "exploration_failures.binlog", .{
        .file_buffer = &file_buffer,
        .mode_buffer = &mode_buffer,
        .decision_buffer = &decision_buffer,
    })).?;

    try testing.expectEqual(@as(u32, 3), latest.schedule_index);
    try testing.expectEqual(@as(u64, 11), latest.schedule_seed.?.value);
    try testing.expectEqual(@as(u32, 1), latest.recorded_decision_count);
    try testing.expect(latest.trace_metadata == null);

    const stored = try artifact.record_log.readLogFile(io, tmp_dir.dir, "exploration_failures.binlog", &file_buffer);
    var iter = try artifact.record_log.iterateRecords(stored);
    var count: usize = 0;
    while (try iter.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}

test "readMostRecentFailureRecord can skip decision decoding explicitly" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const decisions = [_]scheduler.ScheduleDecision{
        .{
            .step_index = 0,
            .chosen_index = 0,
            .ready_len = 1,
            .chosen_id = 11,
            .chosen_value = 1,
        },
    };

    var existing_file_buffer: [512]u8 = undefined;
    var record_buffer: [256]u8 = undefined;
    var frame_buffer: [256]u8 = undefined;
    var output_file_buffer: [512]u8 = undefined;
    _ = try appendFailureRecordFile(io, tmp_dir.dir, "exploration_failures.binlog", .{
        .existing_file_buffer = &existing_file_buffer,
        .record_buffer = &record_buffer,
        .frame_buffer = &frame_buffer,
        .output_file_buffer = &output_file_buffer,
    }, 1, .{
        .schedule_index = 4,
        .schedule_mode = "seeded",
        .schedule_seed = .init(15),
        .recorded_decision_count = 1,
        .recorded_decisions = &decisions,
    });

    var file_buffer: [512]u8 = undefined;
    var mode_buffer: [32]u8 = undefined;
    const latest = (try readMostRecentFailureRecord(io, tmp_dir.dir, "exploration_failures.binlog", .{
        .selection = .{ .decision_artifact = .metadata_only },
        .file_buffer = &file_buffer,
        .mode_buffer = &mode_buffer,
    })).?;

    try testing.expectEqual(@as(u32, 4), latest.schedule_index);
    try testing.expectEqual(@as(u32, 1), latest.recorded_decision_count);
    try testing.expectEqual(@as(usize, 0), latest.recorded_decisions.len);
    try testing.expect(latest.trace_provenance_summary == null);
}
