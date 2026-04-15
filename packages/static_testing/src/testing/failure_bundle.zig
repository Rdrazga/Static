//! Deterministic directory failure bundles over replay artifacts and typed `ZON` sidecars.
//!
//! Bundle layout:
//! - one deterministic directory name;
//! - `manifest.zon` with run and optional runner metadata;
//! - `replay.bin` with the existing replay artifact;
//! - optional `trace.zon` with bounded trace metadata;
//! - optional `trace_events.binlog` with retained causal trace events; and
//! - `violations.zon` with checker result details.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const artifact = @import("../artifact/root.zig");
const checker = @import("checker.zig");
const corpus = @import("corpus.zig");
const identity = @import("identity.zig");
const liveness = @import("liveness.zig");
const replay_artifact = @import("replay_artifact.zig");
const seed_mod = @import("seed.zig");
const trace = @import("trace.zig");

pub const bundle_version: u16 = 3;
pub const manifest_file_name = "manifest.zon";
pub const replay_file_name = "replay.bin";
pub const trace_file_name = "trace.zon";
pub const retained_trace_file_name = "trace_events.binlog";
pub const violations_file_name = "violations.zon";
pub const stdout_file_name = "stdout.txt";
pub const stderr_file_name = "stderr.txt";
pub const recommended_manifest_source_len: usize = 8 * 1024;
pub const recommended_manifest_parse_len: usize = 64 * 1024;
pub const recommended_trace_source_len: usize = 4 * 1024;
pub const recommended_trace_parse_len: usize = 16 * 1024;
pub const recommended_violations_source_len: usize = 8 * 1024;
pub const recommended_violations_parse_len: usize = 32 * 1024;

/// One optional bounded text capture persisted beside a failure bundle.
pub const FailureBundleTextCapture = struct {
    bytes: []const u8,
    truncated: bool = false,
};

pub const FailureBundleTraceArtifact = enum(u8) {
    none = 0,
    summary = 1,
    retained = 2,
    summary_and_retained = 3,
};

pub const FailureBundleArtifactSelection = struct {
    trace_artifact: FailureBundleTraceArtifact = .summary,

    pub fn writeSummary(self: @This()) bool {
        return self.trace_artifact == .summary or self.trace_artifact == .summary_and_retained;
    }

    pub fn writeRetained(self: @This()) bool {
        return self.trace_artifact == .retained or self.trace_artifact == .summary_and_retained;
    }
};

pub const FailureBundleTextCaptureRead = enum(u8) {
    none = 0,
    stdout_only = 1,
    stderr_only = 2,
    both = 3,

    pub fn readStdout(self: @This()) bool {
        return self == .stdout_only or self == .both;
    }

    pub fn readStderr(self: @This()) bool {
        return self == .stderr_only or self == .both;
    }
};

pub const FailureBundleReadSelection = struct {
    trace_artifact: FailureBundleTraceArtifact = .summary,
    text_capture: FailureBundleTextCaptureRead = .none,

    pub fn readSummary(self: @This()) bool {
        return self.trace_artifact == .summary or self.trace_artifact == .summary_and_retained;
    }

    pub fn readRetained(self: @This()) bool {
        return self.trace_artifact == .retained or self.trace_artifact == .summary_and_retained;
    }
};

/// Bundle metadata carried by orchestration layers.
pub const FailureBundleContext = struct {
    artifact_selection: FailureBundleArtifactSelection = .{},
    campaign_profile: ?[]const u8 = null,
    scenario_variant_id: ?u32 = null,
    scenario_variant_label: ?[]const u8 = null,
    base_seed: ?seed_mod.Seed = null,
    seed_lineage_run_index: ?u32 = null,
    schedule_mode: ?[]const u8 = null,
    schedule_seed: ?seed_mod.Seed = null,
    pending_reason: ?liveness.PendingReasonDetail = null,
    trace_provenance_summary: ?trace.TraceProvenanceSummary = null,
    retained_trace_snapshot: ?trace.TraceSnapshot = null,
    stdout_capture: ?FailureBundleTextCapture = null,
    stderr_capture: ?FailureBundleTextCapture = null,
};

pub const ManifestDocument = struct {
    bundle_version: u16,
    replay_file: []const u8,
    trace_file: ?[]const u8 = null,
    retained_trace_file: ?[]const u8 = null,
    violations_file: []const u8,
    package_name: []const u8,
    run_name: []const u8,
    build_mode: identity.BuildMode,
    seed: u64,
    case_index: u32,
    run_index: u32,
    identity_hash: u64,
    campaign_profile: ?[]const u8 = null,
    scenario_variant_id: ?u32 = null,
    scenario_variant_label: ?[]const u8 = null,
    base_seed: ?u64 = null,
    seed_lineage_run_index: ?u32 = null,
    schedule_mode: ?[]const u8 = null,
    schedule_seed: ?u64 = null,
    pending_reason: ?liveness.PendingReasonDetail = null,
    stdout_file: ?[]const u8 = null,
    stdout_truncated: ?bool = null,
    stderr_file: ?[]const u8 = null,
    stderr_truncated: ?bool = null,
};

pub const TraceDocument = struct {
    event_count: u32,
    truncated: bool,
    has_range: bool,
    first_sequence_no: u32,
    last_sequence_no: u32,
    first_timestamp_ns: u64,
    last_timestamp_ns: u64,
    has_provenance: bool,
    caused_event_count: u32,
    root_event_count: u32,
    correlated_event_count: u32,
    surface_labeled_event_count: u32,
    max_causal_depth: u16,
};

pub const DigestDocument = struct {
    upper: u64,
    lower: u64,
};

pub const ViolationsDocument = struct {
    passed: bool,
    checkpoint_digest: ?DigestDocument = null,
    violations: []const checker.Violation,
};

/// Deterministic write configuration over caller-owned buffers.
pub const FailureBundlePersistence = struct {
    io: std.Io,
    dir: std.Io.Dir,
    naming: corpus.CorpusNaming = .{
        .prefix = "bundle",
        .extension = ".bundle",
    },
    entry_name_buffer: []u8,
    artifact_buffer: []u8,
    manifest_buffer: []u8,
    trace_buffer: []u8,
    retained_trace_file_buffer: []u8 = &.{},
    retained_trace_frame_buffer: []u8 = &.{},
    violations_buffer: []u8,
};

/// Write result metadata for one stored bundle.
pub const FailureBundleMeta = struct {
    entry_name: []const u8,
    identity_hash: u64,
    replay_bytes_len: u32,
    manifest_bytes_len: u32,
    trace_bytes_len: u32,
    retained_trace_bytes_len: u32,
    violations_bytes_len: u32,
    stdout_bytes_len: u32,
    stderr_bytes_len: u32,
};

/// Caller-owned buffers for reading one stored bundle.
pub const FailureBundleReadBuffers = struct {
    selection: FailureBundleReadSelection = .{},
    artifact_buffer: []u8,
    manifest_buffer: []u8,
    manifest_parse_buffer: []u8,
    trace_buffer: []u8 = &.{},
    trace_parse_buffer: []u8 = &.{},
    retained_trace_file_buffer: []u8 = &.{},
    retained_trace_events_buffer: []trace.TraceEvent = &.{},
    retained_trace_label_buffer: []u8 = &.{},
    violations_buffer: []u8,
    violations_parse_buffer: []u8,
    stdout_buffer: []u8 = &.{},
    stderr_buffer: []u8 = &.{},
};

/// Read-only view over one stored failure bundle.
pub const FailureBundleView = struct {
    entry_name: []const u8,
    replay_artifact_view: replay_artifact.ReplayArtifactView,
    manifest_document: ManifestDocument,
    trace_document: ?TraceDocument,
    retained_trace: ?trace.TraceSnapshot,
    violations_document: ViolationsDocument,
    stdout_capture: ?[]const u8,
    stderr_capture: ?[]const u8,
};

/// Public errors surfaced by failure-bundle writes.
pub const FailureBundleWriteError = artifact.document.ArtifactDocumentError || replay_artifact.ReplayArtifactError || std.Io.Dir.CreateDirPathOpenError;

pub const FailureBundleReadError = artifact.document.ArtifactDocumentError || replay_artifact.ReplayArtifactError;

comptime {
    @setEvalBranchQuota(5000);
    core.errors.assertVocabularySubset(error{
        InvalidInput,
        NoSpaceLeft,
        Overflow,
    });
    assert(bundle_version == 3);
}

/// Write one deterministic directory bundle for a failing run.
pub fn writeFailureBundle(
    persistence: FailureBundlePersistence,
    run_identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
    check_result: checker.CheckResult,
    context: FailureBundleContext,
) FailureBundleWriteError!FailureBundleMeta {
    assertTraceMetadata(trace_metadata);
    assertCheckResult(check_result);
    try validateContext(context);

    const replay_bytes_len = try replay_artifact.encodeReplayArtifact(
        persistence.artifact_buffer,
        run_identity,
        trace_metadata,
    );
    const entry_name = try persistence.naming.formatEntryName(
        persistence.entry_name_buffer,
        run_identity,
    );
    const artifact_selection = context.artifact_selection;
    const manifest_document = makeManifestDocument(run_identity, context);
    try validateManifestDocument(manifest_document);
    if (artifact_selection.writeRetained() and context.retained_trace_snapshot == null) return error.InvalidInput;
    if (context.retained_trace_snapshot) |snapshot| {
        try validateRetainedTraceSnapshot(snapshot, trace_metadata, context.trace_provenance_summary);
    }
    const effective_provenance_summary =
        context.trace_provenance_summary orelse
        if (context.retained_trace_snapshot) |snapshot| snapshot.provenanceSummary() else null;
    const trace_document = if (artifact_selection.writeSummary())
        makeTraceDocument(trace_metadata, effective_provenance_summary)
    else
        null;
    if (trace_document) |document| try validateTraceDocument(document);
    const violations_document = makeViolationsDocument(check_result);
    try validateViolationsDocument(violations_document);

    var bundle_dir = try persistence.dir.createDirPathOpen(
        persistence.io,
        entry_name,
        .{},
    );
    defer bundle_dir.close(persistence.io);

    try writeBundleFile(bundle_dir, persistence.io, replay_file_name, persistence.artifact_buffer[0..replay_bytes_len]);
    const manifest_bytes_len = try artifact.document.writeZonFile(
        persistence.io,
        bundle_dir,
        manifest_file_name,
        persistence.manifest_buffer,
        manifest_document,
    );
    const trace_bytes_len: usize = if (trace_document) |document|
        try artifact.document.writeZonFile(
            persistence.io,
            bundle_dir,
            trace_file_name,
            persistence.trace_buffer,
            document,
        )
    else
        0;
    const retained_trace_bytes_len: usize = if (artifact_selection.writeRetained())
        try trace.writeRetainedTraceFile(
            persistence.io,
            bundle_dir,
            retained_trace_file_name,
            .{
                .file_buffer = persistence.retained_trace_file_buffer,
                .frame_buffer = persistence.retained_trace_frame_buffer,
            },
            context.retained_trace_snapshot.?,
        )
    else
        0;
    const violations_bytes_len = try artifact.document.writeZonFile(
        persistence.io,
        bundle_dir,
        violations_file_name,
        persistence.violations_buffer,
        violations_document,
    );
    if (context.stdout_capture) |capture| {
        try writeBundleFile(bundle_dir, persistence.io, stdout_file_name, capture.bytes);
    }
    if (context.stderr_capture) |capture| {
        try writeBundleFile(bundle_dir, persistence.io, stderr_file_name, capture.bytes);
    }

    return .{
        .entry_name = entry_name,
        .identity_hash = identity.identityHash(run_identity),
        .replay_bytes_len = @intCast(replay_bytes_len),
        .manifest_bytes_len = @intCast(manifest_bytes_len),
        .trace_bytes_len = @intCast(trace_bytes_len),
        .retained_trace_bytes_len = @intCast(retained_trace_bytes_len),
        .violations_bytes_len = @intCast(violations_bytes_len),
        .stdout_bytes_len = if (context.stdout_capture) |capture| @intCast(capture.bytes.len) else 0,
        .stderr_bytes_len = if (context.stderr_capture) |capture| @intCast(capture.bytes.len) else 0,
    };
}

/// Read one deterministic failure bundle and decode its replay artifact.
pub fn readFailureBundle(
    io: std.Io,
    dir: std.Io.Dir,
    entry_name: []const u8,
    buffers: FailureBundleReadBuffers,
) FailureBundleReadError!FailureBundleView {
    if (entry_name.len == 0) return error.InvalidInput;
    try validateReadSelection(buffers);

    var bundle_dir = try dir.openDir(io, entry_name, .{});
    defer bundle_dir.close(io);

    const artifact_bytes = try bundle_dir.readFile(io, replay_file_name, buffers.artifact_buffer);
    const replay_view = try replay_artifact.decodeReplayArtifact(artifact_bytes);
    const manifest_document = try artifact.document.readZonFile(ManifestDocument, io, bundle_dir, manifest_file_name, .{
        .source_buffer = buffers.manifest_buffer,
        .parse_buffer = buffers.manifest_parse_buffer,
    });
    const trace_document = if (manifest_document.trace_file != null and buffers.selection.readSummary())
        try artifact.document.readZonFile(TraceDocument, io, bundle_dir, manifest_document.trace_file.?, .{
            .source_buffer = buffers.trace_buffer,
            .parse_buffer = buffers.trace_parse_buffer,
        })
    else
        null;
    const retained_trace = if (manifest_document.retained_trace_file != null and buffers.selection.readRetained())
        try trace.readRetainedTraceFile(io, bundle_dir, manifest_document.retained_trace_file.?, .{
            .file_buffer = buffers.retained_trace_file_buffer,
            .events_buffer = buffers.retained_trace_events_buffer,
            .label_buffer = buffers.retained_trace_label_buffer,
        })
    else
        null;
    const violations_document = try artifact.document.readZonFile(ViolationsDocument, io, bundle_dir, violations_file_name, .{
        .source_buffer = buffers.violations_buffer,
        .parse_buffer = buffers.violations_parse_buffer,
    });
    const stdout_capture = if (buffers.selection.text_capture.readStdout())
        readOptionalBundleFile(bundle_dir, io, stdout_file_name, buffers.stdout_buffer) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        }
    else
        null;
    const stderr_capture = if (buffers.selection.text_capture.readStderr())
        readOptionalBundleFile(bundle_dir, io, stderr_file_name, buffers.stderr_buffer) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        }
    else
        null;

    try validateManifestDocument(manifest_document);
    if (trace_document) |document| try validateTraceDocument(document);
    try validateViolationsDocument(violations_document);
    if (retained_trace) |snapshot| {
        const provenance_summary = if (trace_document) |document| trace.TraceProvenanceSummary{
            .has_provenance = document.has_provenance,
            .caused_event_count = document.caused_event_count,
            .root_event_count = document.root_event_count,
            .correlated_event_count = document.correlated_event_count,
            .surface_labeled_event_count = document.surface_labeled_event_count,
            .max_causal_depth = document.max_causal_depth,
        } else null;
        try validateRetainedTraceSnapshot(snapshot, replay_view.trace_metadata, provenance_summary);
    }
    try validateBundleAgainstReplay(manifest_document, trace_document, replay_view);

    return .{
        .entry_name = entry_name,
        .replay_artifact_view = replay_view,
        .manifest_document = manifest_document,
        .trace_document = trace_document,
        .retained_trace = retained_trace,
        .violations_document = violations_document,
        .stdout_capture = stdout_capture,
        .stderr_capture = stderr_capture,
    };
}

fn readOptionalBundleFile(
    bundle_dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    buffer: []u8,
) FailureBundleReadError![]const u8 {
    return bundle_dir.readFile(io, sub_path, buffer);
}

fn writeBundleFile(
    bundle_dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    data: []const u8,
) std.Io.Dir.WriteFileError!void {
    try bundle_dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = data,
        .flags = .{ .exclusive = true },
    });
}

fn makeManifestDocument(
    run_identity: identity.RunIdentity,
    context: FailureBundleContext,
) ManifestDocument {
    return .{
        .bundle_version = bundle_version,
        .replay_file = replay_file_name,
        .trace_file = if (context.artifact_selection.writeSummary()) trace_file_name else null,
        .retained_trace_file = if (context.artifact_selection.writeRetained()) retained_trace_file_name else null,
        .violations_file = violations_file_name,
        .package_name = run_identity.package_name,
        .run_name = run_identity.run_name,
        .build_mode = run_identity.build_mode,
        .seed = run_identity.seed.value,
        .case_index = run_identity.case_index,
        .run_index = run_identity.run_index,
        .identity_hash = identity.identityHash(run_identity),
        .campaign_profile = context.campaign_profile,
        .scenario_variant_id = context.scenario_variant_id,
        .scenario_variant_label = context.scenario_variant_label,
        .base_seed = if (context.base_seed) |seed| seed.value else null,
        .seed_lineage_run_index = context.seed_lineage_run_index,
        .schedule_mode = context.schedule_mode,
        .schedule_seed = if (context.schedule_seed) |seed| seed.value else null,
        .pending_reason = context.pending_reason,
        .stdout_file = if (context.stdout_capture != null) stdout_file_name else null,
        .stdout_truncated = if (context.stdout_capture) |capture| capture.truncated else null,
        .stderr_file = if (context.stderr_capture != null) stderr_file_name else null,
        .stderr_truncated = if (context.stderr_capture) |capture| capture.truncated else null,
    };
}

fn makeTraceDocument(
    metadata: trace.TraceMetadata,
    provenance_summary: ?trace.TraceProvenanceSummary,
) TraceDocument {
    const provenance = provenance_summary orelse trace.TraceProvenanceSummary{
        .has_provenance = false,
        .caused_event_count = 0,
        .root_event_count = metadata.event_count,
        .correlated_event_count = 0,
        .surface_labeled_event_count = 0,
        .max_causal_depth = 0,
    };
    return .{
        .event_count = metadata.event_count,
        .truncated = metadata.truncated,
        .has_range = metadata.has_range,
        .first_sequence_no = metadata.first_sequence_no,
        .last_sequence_no = metadata.last_sequence_no,
        .first_timestamp_ns = metadata.first_timestamp_ns,
        .last_timestamp_ns = metadata.last_timestamp_ns,
        .has_provenance = provenance.has_provenance,
        .caused_event_count = provenance.caused_event_count,
        .root_event_count = provenance.root_event_count,
        .correlated_event_count = provenance.correlated_event_count,
        .surface_labeled_event_count = provenance.surface_labeled_event_count,
        .max_causal_depth = provenance.max_causal_depth,
    };
}

fn makeViolationsDocument(result: checker.CheckResult) ViolationsDocument {
    return .{
        .passed = result.passed,
        .checkpoint_digest = if (result.checkpoint_digest) |digest| .{
            .upper = @as(u64, @truncate(digest.value >> 64)),
            .lower = @as(u64, @truncate(digest.value)),
        } else null,
        .violations = result.violations,
    };
}

fn validateContext(context: FailureBundleContext) FailureBundleWriteError!void {
    if (context.campaign_profile) |profile| {
        if (profile.len == 0) return error.InvalidInput;
    }
    if (context.scenario_variant_label) |label| {
        if (label.len == 0) return error.InvalidInput;
    }
    if (context.schedule_mode) |mode_label| {
        if (mode_label.len == 0) return error.InvalidInput;
    }
    if (context.pending_reason) |detail| {
        if (detail.label) |label| {
            if (label.len == 0) return error.InvalidInput;
        }
    }
    if (context.stdout_capture) |capture| {
        if (capture.bytes.len == 0) return error.InvalidInput;
    }
    if (context.stderr_capture) |capture| {
        if (capture.bytes.len == 0) return error.InvalidInput;
    }
}

fn validateManifestDocument(document: ManifestDocument) FailureBundleReadError!void {
    if (document.bundle_version != bundle_version) return error.Unsupported;
    if (document.replay_file.len == 0) return error.InvalidInput;
    if (document.trace_file) |trace_file| {
        if (trace_file.len == 0) return error.InvalidInput;
    }
    if (document.retained_trace_file) |trace_file| {
        if (trace_file.len == 0) return error.InvalidInput;
    }
    if (document.violations_file.len == 0) return error.InvalidInput;
    if (document.package_name.len == 0) return error.InvalidInput;
    if (document.run_name.len == 0) return error.InvalidInput;
    if (document.stdout_file) |stdout_file| {
        if (stdout_file.len == 0) return error.InvalidInput;
    }
    if (document.stderr_file) |stderr_file| {
        if (stderr_file.len == 0) return error.InvalidInput;
    }
    if (document.pending_reason) |detail| {
        if (detail.label) |label| {
            if (label.len == 0) return error.InvalidInput;
        }
    }
}

fn validateTraceDocument(document: TraceDocument) FailureBundleReadError!void {
    assertTraceMetadata(.{
        .event_count = document.event_count,
        .truncated = document.truncated,
        .has_range = document.has_range,
        .first_sequence_no = document.first_sequence_no,
        .last_sequence_no = document.last_sequence_no,
        .first_timestamp_ns = document.first_timestamp_ns,
        .last_timestamp_ns = document.last_timestamp_ns,
    });
    if (!document.has_provenance) {
        if (document.caused_event_count != 0) return error.InvalidInput;
        if (document.correlated_event_count != 0) return error.InvalidInput;
        if (document.surface_labeled_event_count != 0) return error.InvalidInput;
        if (document.max_causal_depth != 0) return error.InvalidInput;
        if (document.root_event_count != document.event_count) return error.InvalidInput;
        return;
    }
    if (document.root_event_count > document.event_count) return error.InvalidInput;
    if (document.caused_event_count > document.event_count) return error.InvalidInput;
    if (document.root_event_count + document.caused_event_count != document.event_count) return error.InvalidInput;
    if (document.correlated_event_count > document.event_count) return error.InvalidInput;
    if (document.surface_labeled_event_count > document.event_count) return error.InvalidInput;
}

fn validateRetainedTraceSnapshot(
    snapshot: trace.TraceSnapshot,
    metadata: trace.TraceMetadata,
    provenance_summary: ?trace.TraceProvenanceSummary,
) FailureBundleReadError!void {
    if (!std.meta.eql(snapshot.metadata(), metadata)) return error.CorruptData;
    if (provenance_summary) |summary| {
        if (!std.meta.eql(snapshot.provenanceSummary(), summary)) return error.CorruptData;
    }
}

fn validateReadSelection(buffers: FailureBundleReadBuffers) FailureBundleReadError!void {
    if (buffers.artifact_buffer.len == 0) return error.InvalidInput;
    if (buffers.manifest_buffer.len == 0 or buffers.manifest_parse_buffer.len == 0) return error.InvalidInput;
    if (buffers.selection.readSummary()) {
        if (buffers.trace_buffer.len == 0 or buffers.trace_parse_buffer.len == 0) return error.InvalidInput;
    }
    if (buffers.selection.readRetained()) {
        if (buffers.retained_trace_file_buffer.len == 0) return error.InvalidInput;
        if (buffers.retained_trace_events_buffer.len == 0) return error.InvalidInput;
        if (buffers.retained_trace_label_buffer.len == 0) return error.InvalidInput;
    }
    if (buffers.violations_buffer.len == 0 or buffers.violations_parse_buffer.len == 0) return error.InvalidInput;
    if (buffers.selection.text_capture.readStdout() and buffers.stdout_buffer.len == 0) return error.InvalidInput;
    if (buffers.selection.text_capture.readStderr() and buffers.stderr_buffer.len == 0) return error.InvalidInput;
}

fn validateViolationsDocument(document: ViolationsDocument) FailureBundleReadError!void {
    const checkpoint_digest = if (document.checkpoint_digest) |digest| checker.CheckpointDigest.init(
        (@as(u128, digest.upper) << 64) | @as(u128, digest.lower),
    ) else null;
    const result = if (document.passed)
        checker.CheckResult.pass(checkpoint_digest)
    else
        checker.CheckResult.fail(
            document.violations,
            checkpoint_digest,
        );
    assertCheckResult(result);
}

fn validateBundleAgainstReplay(
    manifest_document: ManifestDocument,
    trace_document: ?TraceDocument,
    replay_view: replay_artifact.ReplayArtifactView,
) FailureBundleReadError!void {
    if (!std.mem.eql(u8, manifest_document.replay_file, replay_file_name)) return error.CorruptData;
    if (manifest_document.trace_file) |trace_file| {
        if (!std.mem.eql(u8, trace_file, trace_file_name)) return error.CorruptData;
    }
    if (manifest_document.retained_trace_file) |trace_file| {
        if (!std.mem.eql(u8, trace_file, retained_trace_file_name)) return error.CorruptData;
    }
    if (!std.mem.eql(u8, manifest_document.violations_file, violations_file_name)) return error.CorruptData;
    if (!std.mem.eql(u8, manifest_document.package_name, replay_view.identity.package_name)) return error.CorruptData;
    if (!std.mem.eql(u8, manifest_document.run_name, replay_view.identity.run_name)) return error.CorruptData;
    if (manifest_document.build_mode != replay_view.identity.build_mode) return error.CorruptData;
    if (manifest_document.seed != replay_view.identity.seed.value) return error.CorruptData;
    if (manifest_document.case_index != replay_view.identity.case_index) return error.CorruptData;
    if (manifest_document.run_index != replay_view.identity.run_index) return error.CorruptData;
    if (manifest_document.identity_hash != identity.identityHash(replay_view.identity)) return error.CorruptData;
    if (trace_document) |document| {
        if (document.event_count != replay_view.trace_metadata.event_count) return error.CorruptData;
        if (document.truncated != replay_view.trace_metadata.truncated) return error.CorruptData;
        if (document.has_range != replay_view.trace_metadata.has_range) return error.CorruptData;
        if (document.first_sequence_no != replay_view.trace_metadata.first_sequence_no) return error.CorruptData;
        if (document.last_sequence_no != replay_view.trace_metadata.last_sequence_no) return error.CorruptData;
        if (document.first_timestamp_ns != replay_view.trace_metadata.first_timestamp_ns) return error.CorruptData;
        if (document.last_timestamp_ns != replay_view.trace_metadata.last_timestamp_ns) return error.CorruptData;
    }
}

fn assertTraceMetadata(metadata: trace.TraceMetadata) void {
    if (metadata.event_count == 0) {
        assert(!metadata.has_range);
        assert(metadata.first_sequence_no == 0);
        assert(metadata.last_sequence_no == 0);
        assert(metadata.first_timestamp_ns == 0);
        assert(metadata.last_timestamp_ns == 0);
    } else {
        assert(metadata.has_range);
        assert(metadata.first_sequence_no <= metadata.last_sequence_no);
        assert(metadata.first_timestamp_ns <= metadata.last_timestamp_ns);
    }
}

fn assertCheckResult(result: checker.CheckResult) void {
    if (result.passed) {
        assert(result.violations.len == 0);
    } else {
        assert(result.violations.len > 0);
    }
}

test "writeFailureBundle and readFailureBundle preserve replay artifact and sidecars" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const violations = [_]checker.Violation{
        .{ .code = "failed", .message = "bundle failure" },
    };
    const stdout_capture = "stdout sample";
    const stderr_capture = "stderr sample";
    const provenance_summary: trace.TraceProvenanceSummary = .{
        .has_provenance = true,
        .caused_event_count = 1,
        .root_event_count = 1,
        .correlated_event_count = 1,
        .surface_labeled_event_count = 1,
        .max_causal_depth = 1,
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "failure_bundle_roundtrip",
        .seed = .{ .value = 99 },
        .build_mode = .debug,
        .case_index = 7,
        .run_index = 3,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 2,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 4,
        .last_sequence_no = 5,
        .first_timestamp_ns = 10,
        .last_timestamp_ns = 11,
    };
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;

    const written = try writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "phase2_bundle", .extension = ".bundle" },
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, checker.CheckResult.fail(
        &violations,
        checker.CheckpointDigest.init(42),
    ), .{
        .campaign_profile = "stress",
        .scenario_variant_id = 5,
        .scenario_variant_label = "same_tick_seeded",
        .base_seed = .init(7),
        .seed_lineage_run_index = 3,
        .schedule_mode = "seeded",
        .schedule_seed = .init(9),
        .pending_reason = .{
            .reason = .reply_sequence_gap,
            .count = 2,
            .value = 17,
            .label = "reply_window",
        },
        .trace_provenance_summary = provenance_summary,
        .stdout_capture = .{
            .bytes = stdout_capture,
            .truncated = true,
        },
        .stderr_capture = .{
            .bytes = stderr_capture,
            .truncated = false,
        },
    });

    try testing.expect(std.mem.endsWith(u8, written.entry_name, ".bundle"));
    try testing.expect(written.manifest_bytes_len > 0);
    try testing.expectEqual(@as(u32, stdout_capture.len), written.stdout_bytes_len);
    try testing.expectEqual(@as(u32, stderr_capture.len), written.stderr_bytes_len);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [recommended_trace_parse_len]u8 = undefined;
    var read_violations_source: [recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [recommended_violations_parse_len]u8 = undefined;
    var read_stdout_buffer: [256]u8 = undefined;
    var read_stderr_buffer: [256]u8 = undefined;
    const bundle = try readFailureBundle(io, tmp_dir.dir, written.entry_name, .{
        .selection = .{
            .trace_artifact = .summary,
            .text_capture = .both,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
        .stdout_buffer = &read_stdout_buffer,
        .stderr_buffer = &read_stderr_buffer,
    });

    try testing.expectEqual(run_identity.seed.value, bundle.replay_artifact_view.identity.seed.value);
    try testing.expectEqualStrings("stress", bundle.manifest_document.campaign_profile.?);
    try testing.expectEqual(@as(u32, 5), bundle.manifest_document.scenario_variant_id.?);
    try testing.expectEqualStrings("seeded", bundle.manifest_document.schedule_mode.?);
    try testing.expectEqual(@as(u64, 9), bundle.manifest_document.schedule_seed.?);
    try testing.expect(bundle.manifest_document.pending_reason != null);
    try testing.expectEqual(liveness.PendingReason.reply_sequence_gap, bundle.manifest_document.pending_reason.?.reason);
    try testing.expectEqual(@as(u32, 2), bundle.manifest_document.pending_reason.?.count);
    try testing.expectEqual(@as(u64, 17), bundle.manifest_document.pending_reason.?.value);
    try testing.expectEqualStrings("reply_window", bundle.manifest_document.pending_reason.?.label.?);
    try testing.expectEqualStrings(stdout_file_name, bundle.manifest_document.stdout_file.?);
    try testing.expectEqual(true, bundle.manifest_document.stdout_truncated.?);
    try testing.expectEqualStrings(stderr_file_name, bundle.manifest_document.stderr_file.?);
    try testing.expect(bundle.trace_document != null);
    try testing.expectEqual(@as(u32, 2), bundle.trace_document.?.event_count);
    try testing.expect(bundle.trace_document.?.has_provenance);
    try testing.expectEqual(@as(u32, 1), bundle.trace_document.?.caused_event_count);
    try testing.expectEqual(@as(u16, 1), bundle.trace_document.?.max_causal_depth);
    try testing.expectEqualStrings("failed", bundle.violations_document.violations[0].code);
    try testing.expect(bundle.stdout_capture != null);
    try testing.expect(bundle.stderr_capture != null);
    try testing.expectEqualStrings(stdout_capture, bundle.stdout_capture.?);
    try testing.expectEqualStrings(stderr_capture, bundle.stderr_capture.?);
}

test "writeFailureBundle preserves full-width checkpoint digests" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const violations = [_]checker.Violation{
        .{ .code = "failed", .message = "bundle failure" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "failure_bundle_full_width_digest",
        .seed = .{ .value = 29 },
        .build_mode = .debug,
        .case_index = 4,
        .run_index = 2,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 11,
        .last_sequence_no = 11,
        .first_timestamp_ns = 100,
        .last_timestamp_ns = 100,
    };
    const expected_digest = checker.CheckpointDigest.init(0xfedc_ba98_7654_3210_0123_4567_89ab_cdef);

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [512]u8 = undefined;

    const written = try writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, checker.CheckResult.fail(
        &violations,
        expected_digest,
    ), .{});

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [recommended_trace_parse_len]u8 = undefined;
    var read_violations_source: [recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [recommended_violations_parse_len]u8 = undefined;
    const bundle = try readFailureBundle(io, tmp_dir.dir, written.entry_name, .{
        .selection = .{
            .trace_artifact = .summary,
            .text_capture = .none,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try testing.expect(bundle.violations_document.checkpoint_digest != null);
    const actual_digest = bundle.violations_document.checkpoint_digest.?;
    try testing.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), actual_digest.upper);
    try testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), actual_digest.lower);
}

test "writeFailureBundle can omit the trace summary when callers select replay-only retention" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const violations = [_]checker.Violation{
        .{ .code = "failed", .message = "bundle failure" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "failure_bundle_trace_optional",
        .seed = .{ .value = 13 },
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 2,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 2,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 4,
        .last_sequence_no = 5,
        .first_timestamp_ns = 10,
        .last_timestamp_ns = 11,
    };
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;

    const written = try writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "phase2_bundle", .extension = ".bundle" },
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, checker.CheckResult.fail(
        &violations,
        checker.CheckpointDigest.init(42),
    ), .{
        .artifact_selection = .{ .trace_artifact = .none },
    });

    try testing.expectEqual(@as(u32, 0), written.trace_bytes_len);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [recommended_manifest_parse_len]u8 = undefined;
    var read_violations_source: [recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [recommended_violations_parse_len]u8 = undefined;
    const bundle = try readFailureBundle(io, tmp_dir.dir, written.entry_name, .{
        .selection = .{
            .trace_artifact = .none,
            .text_capture = .none,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try testing.expect(bundle.trace_document == null);
    try testing.expect(bundle.manifest_document.trace_file == null);
    try testing.expectEqualStrings("failed", bundle.violations_document.violations[0].code);
}

test "writeFailureBundle can retain binary trace events beside the summary" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const violations = [_]checker.Violation{
        .{ .code = "failed", .message = "bundle failure" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "failure_bundle_retained_trace",
        .seed = .{ .value = 21 },
        .build_mode = .debug,
        .case_index = 2,
        .run_index = 4,
    });

    var trace_storage: [2]trace.TraceEvent = undefined;
    var trace_buffer_state = try trace.TraceBuffer.init(&trace_storage, .{
        .max_events = 2,
        .start_sequence_no = 30,
    });
    try trace_buffer_state.append(.{
        .timestamp_ns = 100,
        .category = .decision,
        .label = "choose",
        .value = 1,
    });
    try trace_buffer_state.append(.{
        .timestamp_ns = 120,
        .category = .info,
        .label = "apply",
        .value = 2,
        .lineage = .{
            .cause_sequence_no = 30,
            .correlation_id = 9,
            .surface_label = "mailbox",
        },
    });
    const retained_snapshot = trace_buffer_state.snapshot();
    const trace_metadata = retained_snapshot.metadata();

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var retained_trace_file_buffer: [1024]u8 = undefined;
    var retained_trace_frame_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;

    const written = try writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "phase2_bundle", .extension = ".bundle" },
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .retained_trace_file_buffer = &retained_trace_file_buffer,
        .retained_trace_frame_buffer = &retained_trace_frame_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, checker.CheckResult.fail(
        &violations,
        null,
    ), .{
        .artifact_selection = .{ .trace_artifact = .summary_and_retained },
        .retained_trace_snapshot = retained_snapshot,
    });

    try testing.expect(written.trace_bytes_len > 0);
    try testing.expect(written.retained_trace_bytes_len > 0);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [1024]u8 = undefined;
    var read_retained_events: [2]trace.TraceEvent = undefined;
    var read_retained_labels: [256]u8 = undefined;
    var read_violations_source: [recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [recommended_violations_parse_len]u8 = undefined;
    const bundle = try readFailureBundle(io, tmp_dir.dir, written.entry_name, .{
        .selection = .{
            .trace_artifact = .summary_and_retained,
            .text_capture = .none,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .retained_trace_file_buffer = &read_retained_trace_file,
        .retained_trace_events_buffer = &read_retained_events,
        .retained_trace_label_buffer = &read_retained_labels,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try testing.expectEqualStrings(retained_trace_file_name, bundle.manifest_document.retained_trace_file.?);
    try testing.expect(bundle.retained_trace != null);
    try testing.expectEqual(@as(usize, 2), bundle.retained_trace.?.items.len);
    try testing.expectEqual(@as(?u32, 30), bundle.retained_trace.?.items[1].lineage.cause_sequence_no);
    try testing.expectEqualStrings("mailbox", bundle.retained_trace.?.items[1].lineage.surface_label.?);
}

test "readFailureBundle selection can skip optional sidecars" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const violations = [_]checker.Violation{
        .{ .code = "failed", .message = "bundle failure" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "failure_bundle_read_selection",
        .seed = .{ .value = 31 },
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 1,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 7,
        .last_sequence_no = 7,
        .first_timestamp_ns = 100,
        .last_timestamp_ns = 100,
    };
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;

    const written = try writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, checker.CheckResult.fail(&violations, null), .{
        .artifact_selection = .{ .trace_artifact = .summary },
    });

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [recommended_manifest_parse_len]u8 = undefined;
    var read_violations_source: [recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [recommended_violations_parse_len]u8 = undefined;
    const bundle = try readFailureBundle(io, tmp_dir.dir, written.entry_name, .{
        .selection = .{
            .trace_artifact = .none,
            .text_capture = .none,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try testing.expect(bundle.trace_document == null);
    try testing.expect(bundle.retained_trace == null);
    try testing.expectEqualStrings("failed", bundle.violations_document.violations[0].code);
}

test "readFailureBundle rejects unsupported manifest version" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const violations = [_]checker.Violation{
        .{ .code = "failed", .message = "bundle failure" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "failure_bundle_unsupported_version",
        .seed = .{ .value = 41 },
        .build_mode = .debug,
        .case_index = 2,
        .run_index = 3,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 9,
        .last_sequence_no = 9,
        .first_timestamp_ns = 100,
        .last_timestamp_ns = 100,
    };

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;

    const written = try writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .entry_name_buffer = &entry_name_buffer,
        .artifact_buffer = &artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, checker.CheckResult.fail(&violations, null), .{});

    var bundle_dir = try tmp_dir.dir.openDir(io, written.entry_name, .{});
    defer bundle_dir.close(io);

    var invalid_manifest = makeManifestDocument(run_identity, .{});
    invalid_manifest.bundle_version = bundle_version + 1;
    _ = try artifact.document.writeZonFile(
        io,
        bundle_dir,
        manifest_file_name,
        &manifest_buffer,
        invalid_manifest,
    );

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [recommended_trace_parse_len]u8 = undefined;
    var read_violations_source: [recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [recommended_violations_parse_len]u8 = undefined;

    try testing.expectError(error.Unsupported, readFailureBundle(io, tmp_dir.dir, written.entry_name, .{
        .selection = .{
            .trace_artifact = .summary,
            .text_capture = .none,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    }));
}
