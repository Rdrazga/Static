//! Bounded trace event storage for deterministic tests and replay artifacts.
//!
//! `TraceBuffer` stores caller-owned `TraceEvent` values without allocating.
//! Labels are borrowed, not copied. Callers must keep label storage alive for
//! as long as any exported trace JSON needs those labels.

const std = @import("std");
const core = @import("static_core");
const artifact = @import("../artifact/root.zig");
const profile = @import("static_profile");

/// Operating errors surfaced by bounded trace append/export helpers.
pub const TraceAppendError = error{
    InvalidConfig,
    NoSpaceLeft,
};

/// Optional bounded lineage metadata attached to one trace event.
pub const TraceLineage = struct {
    cause_sequence_no: ?u32 = null,
    correlation_id: ?u64 = null,
    surface_label: ?[]const u8 = null,
};

/// High-level trace categories used across deterministic testing surfaces.
pub const TraceCategory = enum(u8) {
    info = 1,
    input = 2,
    decision = 3,
    check = 4,
    bench = 5,
};

/// Caller-supplied trace append input.
pub const TraceAppend = struct {
    timestamp_ns: u64,
    category: TraceCategory,
    label: []const u8,
    value: u64 = 0,
    lineage: TraceLineage = .{},
};

/// One stored trace event with assigned sequence number.
pub const TraceEvent = struct {
    sequence_no: u32,
    timestamp_ns: u64,
    category: TraceCategory,
    label: []const u8,
    value: u64,
    lineage: TraceLineage,
};

/// Trace buffer configuration over caller-owned storage.
pub const TraceBufferConfig = struct {
    max_events: u32,
    start_sequence_no: u32 = 0,
};

/// Stable metadata summary derived from a trace snapshot.
pub const TraceMetadata = struct {
    event_count: u32,
    truncated: bool,
    has_range: bool,
    first_sequence_no: u32,
    last_sequence_no: u32,
    first_timestamp_ns: u64,
    last_timestamp_ns: u64,
};

/// Bounded causal/provenance summary over one trace snapshot.
pub const TraceProvenanceSummary = struct {
    has_provenance: bool,
    caused_event_count: u32,
    root_event_count: u32,
    correlated_event_count: u32,
    surface_labeled_event_count: u32,
    max_causal_depth: u16,
};

pub const retained_trace_record_version: u16 = 1;

pub const RetainedTraceWriteBuffers = struct {
    file_buffer: []u8,
    frame_buffer: []u8,
};

pub const RetainedTraceReadBuffers = struct {
    file_buffer: []u8,
    events_buffer: []TraceEvent,
    label_buffer: []u8,
};

pub const TraceSnapshotCaptureBuffers = struct {
    events_buffer: []TraceEvent,
    label_buffer: []u8,
};

pub const TraceSnapshotCaptureError = error{
    NoSpaceLeft,
};

/// Immutable trace snapshot view.
pub const TraceSnapshot = struct {
    items: []const TraceEvent,
    truncated: bool,

    /// Derive bounded metadata for replay and diagnostics.
    pub fn metadata(self: TraceSnapshot) TraceMetadata {
        if (self.items.len == 0) {
            return .{
                .event_count = 0,
                .truncated = self.truncated,
                .has_range = false,
                .first_sequence_no = 0,
                .last_sequence_no = 0,
                .first_timestamp_ns = 0,
                .last_timestamp_ns = 0,
            };
        }

        const first_event = self.items[0];
        const last_event = self.items[self.items.len - 1];
        return .{
            .event_count = @as(u32, @intCast(self.items.len)),
            .truncated = self.truncated,
            .has_range = true,
            .first_sequence_no = first_event.sequence_no,
            .last_sequence_no = last_event.sequence_no,
            .first_timestamp_ns = first_event.timestamp_ns,
            .last_timestamp_ns = last_event.timestamp_ns,
        };
    }

    /// Derive bounded provenance summary from one trace snapshot.
    pub fn provenanceSummary(self: TraceSnapshot) TraceProvenanceSummary {
        var caused_event_count: u32 = 0;
        var root_event_count: u32 = 0;
        var correlated_event_count: u32 = 0;
        var surface_labeled_event_count: u32 = 0;
        var max_causal_depth: u16 = 0;

        for (self.items) |event| {
            const has_cause = event.lineage.cause_sequence_no != null;
            if (has_cause) {
                caused_event_count += 1;
                const depth = lineageDepth(self.items, event);
                if (depth > max_causal_depth) max_causal_depth = depth;
            } else {
                root_event_count += 1;
            }
            if (event.lineage.correlation_id != null) correlated_event_count += 1;
            if (event.lineage.surface_label != null) surface_labeled_event_count += 1;
        }

        return .{
            .has_provenance = caused_event_count != 0 or correlated_event_count != 0 or surface_labeled_event_count != 0,
            .caused_event_count = caused_event_count,
            .root_event_count = root_event_count,
            .correlated_event_count = correlated_event_count,
            .surface_labeled_event_count = surface_labeled_event_count,
            .max_causal_depth = max_causal_depth,
        };
    }

    /// Export this snapshot as Chrome trace JSON.
    pub fn writeChromeTraceJson(self: TraceSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("[");
        for (self.items, 0..) |event, index| {
            if (index != 0) try writer.writeAll(",");
            try writeChromeTraceEvent(writer, event);
        }
        try writer.writeAll("]");
    }

    /// Export one deterministic plain-text causality summary.
    pub fn writeCausalityText(self: TraceSnapshot, writer: *std.Io.Writer) !void {
        for (self.items, 0..) |event, index| {
            if (index != 0) try writer.writeAll("\n");
            try writer.print("seq={} label={s}", .{ event.sequence_no, event.label });
            if (event.lineage.cause_sequence_no) |cause_sequence_no| {
                try writer.print(" cause_seq={}", .{cause_sequence_no});
            } else {
                try writer.writeAll(" cause_seq=root");
            }
            if (event.lineage.correlation_id) |correlation_id| {
                try writer.print(" correlation_id={}", .{correlation_id});
            }
            if (event.lineage.surface_label) |surface_label| {
                try writer.print(" surface={s}", .{surface_label});
            }
        }
    }
};

/// Copy a borrowed trace snapshot into caller-owned event and label buffers.
pub fn captureSnapshot(
    buffers: TraceSnapshotCaptureBuffers,
    snapshot: TraceSnapshot,
) TraceSnapshotCaptureError!TraceSnapshot {
    if (snapshot.items.len > buffers.events_buffer.len) return error.NoSpaceLeft;

    var label_cursor: usize = 0;
    for (snapshot.items, 0..) |event, index| {
        var copied_event = event;
        copied_event.label = try copyTraceLabel(buffers.label_buffer, &label_cursor, event.label);
        if (event.lineage.surface_label) |surface_label| {
            copied_event.lineage.surface_label = try copyTraceLabel(
                buffers.label_buffer,
                &label_cursor,
                surface_label,
            );
        } else {
            copied_event.lineage.surface_label = null;
        }
        buffers.events_buffer[index] = copied_event;
    }

    return .{
        .items = buffers.events_buffer[0..snapshot.items.len],
        .truncated = snapshot.truncated,
    };
}

pub fn writeRetainedTraceFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: RetainedTraceWriteBuffers,
    snapshot: TraceSnapshot,
) (artifact.record_log.ArtifactRecordLogError || std.Io.Dir.WriteFileError)!usize {
    try validateRetainedTraceWriteInput(sub_path, buffers, snapshot);
    assertTraceSnapshot(snapshot);
    var file_builder = try artifact.record_log.FileBuilder.init(buffers.file_buffer);

    var metadata_frame: [8]u8 = undefined;
    const metadata_payload = try encodeRetainedTraceMetadata(&metadata_frame, snapshot);
    try file_builder.append(metadata_payload);

    for (snapshot.items) |event| {
        const frame = try encodeRetainedTraceEvent(buffers.frame_buffer, event);
        try file_builder.append(frame);
    }

    const bytes = file_builder.finish();
    try dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = bytes,
        .flags = .{ .exclusive = true },
    });
    return @intCast(bytes.len);
}

pub fn readRetainedTraceFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: RetainedTraceReadBuffers,
) (artifact.record_log.ArtifactRecordLogError)!TraceSnapshot {
    try validateRetainedTraceReadInput(sub_path, buffers);

    const file_bytes = try artifact.record_log.readLogFile(io, dir, sub_path, buffers.file_buffer);
    var iter = try artifact.record_log.iterateRecords(file_bytes);
    const metadata_payload = (try iter.next()) orelse return error.CorruptData;
    const metadata = try decodeRetainedTraceMetadata(metadata_payload);
    if (metadata.event_count > buffers.events_buffer.len) return error.NoSpaceLeft;

    var event_count: usize = 0;
    var label_cursor: usize = 0;
    while (try iter.next()) |payload| {
        if (event_count >= metadata.event_count) return error.CorruptData;
        buffers.events_buffer[event_count] = try decodeRetainedTraceEvent(payload, buffers.label_buffer, &label_cursor);
        event_count += 1;
    }
    if (event_count != metadata.event_count) return error.CorruptData;

    return .{
        .items = buffers.events_buffer[0..event_count],
        .truncated = metadata.truncated,
    };
}

/// Fixed-capacity caller-owned trace buffer.
pub const TraceBuffer = struct {
    storage: []TraceEvent,
    max_events: usize,
    start_sequence_no: u32,
    event_count: usize = 0,
    next_sequence_no: u32,
    truncated: bool = false,

    /// Initialize a trace buffer over caller-owned event storage.
    pub fn init(storage: []TraceEvent, config: TraceBufferConfig) TraceAppendError!TraceBuffer {
        if (config.max_events == 0) return error.InvalidConfig;
        if (config.max_events > storage.len) return error.InvalidConfig;
        if (!sequenceRangeFits(config)) return error.InvalidConfig;

        return .{
            .storage = storage[0..config.max_events],
            .max_events = config.max_events,
            .start_sequence_no = config.start_sequence_no,
            .next_sequence_no = config.start_sequence_no,
        };
    }

    /// Append one trace event with the next sequence number.
    pub fn append(self: *TraceBuffer, entry: TraceAppend) TraceAppendError!void {
        std.debug.assert(entry.label.len > 0);
        std.debug.assert(self.event_count <= self.max_events);

        if (self.event_count >= self.max_events) {
            self.truncated = true;
            return error.NoSpaceLeft;
        }

        const sequence_no = self.next_sequence_no;
        self.storage[self.event_count] = .{
            .sequence_no = sequence_no,
            .timestamp_ns = entry.timestamp_ns,
            .category = entry.category,
            .label = entry.label,
            .value = entry.value,
            .lineage = entry.lineage,
        };
        self.event_count += 1;
        if (self.event_count < self.max_events) {
            self.next_sequence_no = std.math.add(u32, sequence_no, 1) catch unreachable;
        } else {
            self.next_sequence_no = sequence_no;
        }
        std.debug.assert(self.event_count <= self.max_events);
    }

    /// Reset event count, sequence number, and truncation state.
    pub fn reset(self: *TraceBuffer) void {
        std.debug.assert(self.max_events > 0);
        self.event_count = 0;
        self.next_sequence_no = self.start_sequence_no;
        self.truncated = false;
    }

    /// Snapshot the currently stored trace prefix.
    pub fn snapshot(self: *const TraceBuffer) TraceSnapshot {
        std.debug.assert(self.event_count <= self.max_events);
        return .{
            .items = self.storage[0..self.event_count],
            .truncated = self.truncated,
        };
    }

    /// Report how many more events can be appended before truncation begins.
    pub fn freeSlots(self: *const TraceBuffer) usize {
        std.debug.assert(self.event_count <= self.max_events);
        return self.max_events - self.event_count;
    }
};

comptime {
    core.errors.assertVocabularySubset(TraceAppendError);
    std.debug.assert(std.meta.fields(TraceCategory).len == 5);
    std.debug.assert(retained_trace_record_version == 1);
}

fn sequenceRangeFits(config: TraceBufferConfig) bool {
    if (config.max_events == 0) return false;
    const max_index = config.max_events - 1;
    return config.start_sequence_no <= std.math.maxInt(u32) - max_index;
}

fn validateRetainedTraceWriteInput(
    sub_path: []const u8,
    buffers: RetainedTraceWriteBuffers,
    snapshot: TraceSnapshot,
) artifact.record_log.ArtifactRecordLogError!void {
    if (sub_path.len == 0) return error.InvalidInput;
    if (buffers.file_buffer.len == 0) return error.InvalidInput;
    if (snapshot.items.len != 0 and buffers.frame_buffer.len == 0) return error.InvalidInput;
}

fn validateRetainedTraceReadInput(
    sub_path: []const u8,
    buffers: RetainedTraceReadBuffers,
) artifact.record_log.ArtifactRecordLogError!void {
    if (sub_path.len == 0) return error.InvalidInput;
    if (buffers.file_buffer.len == 0) return error.InvalidInput;
    if (buffers.events_buffer.len == 0) return error.InvalidInput;
    if (buffers.label_buffer.len == 0) return error.InvalidInput;
}

fn assertTraceSnapshot(snapshot: TraceSnapshot) void {
    if (snapshot.items.len == 0) return;

    var previous_sequence_no = snapshot.items[0].sequence_no;
    for (snapshot.items, 0..) |event, index| {
        assertTraceEvent(event);
        if (index != 0) {
            std.debug.assert(previous_sequence_no < event.sequence_no);
            previous_sequence_no = event.sequence_no;
        }
    }
}

fn assertTraceEvent(event: TraceEvent) void {
    std.debug.assert(event.label.len != 0);
    if (event.lineage.surface_label) |surface_label| {
        std.debug.assert(surface_label.len != 0);
    }
    if (event.lineage.cause_sequence_no) |cause_sequence_no| {
        std.debug.assert(cause_sequence_no < event.sequence_no);
    }
}

fn writeChromeTraceEvent(writer: *std.Io.Writer, event: TraceEvent) !void {
    assertTraceEvent(event);
    const timestamp_us = @divFloor(event.timestamp_ns, std.time.ns_per_us);

    try writer.writeAll("{\"name\":");
    try profile.trace.writeJsonString(writer, event.label);
    try writer.writeAll(",\"cat\":");
    try profile.trace.writeJsonString(writer, @tagName(event.category));
    try writer.writeAll(",\"ph\":\"i\",\"ts\":");
    try writer.print("{}", .{timestamp_us});
    try writer.writeAll(",\"pid\":0,\"tid\":0,\"s\":\"t\",\"args\":{\"seq\":");
    try writer.print("{}", .{event.sequence_no});
    try writer.writeAll(",\"value\":");
    try writer.print("{}", .{event.value});
    if (event.lineage.cause_sequence_no) |cause_sequence_no| {
        try writer.writeAll(",\"cause_seq\":");
        try writer.print("{}", .{cause_sequence_no});
    }
    if (event.lineage.correlation_id) |correlation_id| {
        try writer.writeAll(",\"correlation_id\":");
        try writer.print("{}", .{correlation_id});
    }
    if (event.lineage.surface_label) |surface_label| {
        try writer.writeAll(",\"surface\":");
        try profile.trace.writeJsonString(writer, surface_label);
    }
    try writer.writeAll("}}");
}

fn copyTraceLabel(
    label_buffer: []u8,
    cursor: *usize,
    label: []const u8,
) TraceSnapshotCaptureError![]const u8 {
    if (label_buffer.len - cursor.* < label.len) return error.NoSpaceLeft;
    @memcpy(label_buffer[cursor.* .. cursor.* + label.len], label);
    defer cursor.* += label.len;
    return label_buffer[cursor.* .. cursor.* + label.len];
}

fn lineageDepth(items: []const TraceEvent, event: TraceEvent) u16 {
    var depth: u16 = 0;
    var cursor = event.lineage.cause_sequence_no;
    while (cursor) |sequence_no| {
        depth += 1;
        const parent = findEventBySequence(items, sequence_no) orelse break;
        cursor = parent.lineage.cause_sequence_no;
    }
    return depth;
}

fn findEventBySequence(items: []const TraceEvent, sequence_no: u32) ?TraceEvent {
    for (items) |event| {
        if (event.sequence_no == sequence_no) return event;
    }
    return null;
}

const RetainedTraceMetadata = struct {
    truncated: bool,
    event_count: u32,
};

const retained_trace_metadata_tag: u8 = 1;
const retained_trace_event_tag: u8 = 2;
const retained_trace_flag_has_cause: u8 = 1 << 0;
const retained_trace_flag_has_correlation: u8 = 1 << 1;
const retained_trace_flag_has_surface: u8 = 1 << 2;

fn encodeRetainedTraceMetadata(
    buffer: []u8,
    snapshot: TraceSnapshot,
) artifact.record_log.ArtifactRecordLogError![]const u8 {
    var writer = RetainedTraceBufferWriter.init(buffer);
    try writer.writeInt(u8, retained_trace_metadata_tag);
    try writer.writeInt(u16, retained_trace_record_version);
    try writer.writeInt(u8, if (snapshot.truncated) 1 else 0);
    try writer.writeInt(u32, std.math.cast(u32, snapshot.items.len) orelse return error.Overflow);
    return writer.finish();
}

fn decodeRetainedTraceMetadata(
    payload: []const u8,
) artifact.record_log.ArtifactRecordLogError!RetainedTraceMetadata {
    var reader = RetainedTraceBufferReader.init(payload);
    const tag = try reader.readInt(u8);
    if (tag != retained_trace_metadata_tag) return error.CorruptData;
    const version = try reader.readInt(u16);
    if (version != retained_trace_record_version) return error.Unsupported;
    const truncated = (try reader.readInt(u8)) != 0;
    const event_count = try reader.readInt(u32);
    if (!reader.isDone()) return error.CorruptData;
    return .{
        .truncated = truncated,
        .event_count = event_count,
    };
}

fn encodeRetainedTraceEvent(
    buffer: []u8,
    event: TraceEvent,
) artifact.record_log.ArtifactRecordLogError![]const u8 {
    std.debug.assert(event.label.len > 0);
    var writer = RetainedTraceBufferWriter.init(buffer);
    const flags: u8 =
        (if (event.lineage.cause_sequence_no != null) retained_trace_flag_has_cause else 0) |
        (if (event.lineage.correlation_id != null) retained_trace_flag_has_correlation else 0) |
        (if (event.lineage.surface_label != null) retained_trace_flag_has_surface else 0);
    try writer.writeInt(u8, retained_trace_event_tag);
    try writer.writeInt(u16, retained_trace_record_version);
    try writer.writeInt(u32, event.sequence_no);
    try writer.writeInt(u64, event.timestamp_ns);
    try writer.writeInt(u8, @intFromEnum(event.category));
    try writer.writeInt(u8, flags);
    try writer.writeInt(u64, event.value);
    try writer.writeBytesWithLen(event.label);
    if (event.lineage.cause_sequence_no) |cause_sequence_no| {
        try writer.writeInt(u32, cause_sequence_no);
    }
    if (event.lineage.correlation_id) |correlation_id| {
        try writer.writeInt(u64, correlation_id);
    }
    if (event.lineage.surface_label) |surface_label| {
        try writer.writeBytesWithLen(surface_label);
    }
    return writer.finish();
}

fn decodeRetainedTraceEvent(
    payload: []const u8,
    label_buffer: []u8,
    label_cursor: *usize,
) artifact.record_log.ArtifactRecordLogError!TraceEvent {
    var reader = RetainedTraceBufferReader.init(payload);
    const tag = try reader.readInt(u8);
    if (tag != retained_trace_event_tag) return error.CorruptData;
    const version = try reader.readInt(u16);
    if (version != retained_trace_record_version) return error.Unsupported;
    const sequence_no = try reader.readInt(u32);
    const timestamp_ns = try reader.readInt(u64);
    const category_value = try reader.readInt(u8);
    const category: TraceCategory = switch (category_value) {
        @intFromEnum(TraceCategory.info) => .info,
        @intFromEnum(TraceCategory.input) => .input,
        @intFromEnum(TraceCategory.decision) => .decision,
        @intFromEnum(TraceCategory.check) => .check,
        @intFromEnum(TraceCategory.bench) => .bench,
        else => return error.CorruptData,
    };
    const flags = try reader.readInt(u8);
    const value = try reader.readInt(u64);
    const label = try reader.readBytesWithLen(label_buffer, label_cursor);
    const cause_sequence_no = if ((flags & retained_trace_flag_has_cause) != 0)
        try reader.readInt(u32)
    else
        null;
    const correlation_id = if ((flags & retained_trace_flag_has_correlation) != 0)
        try reader.readInt(u64)
    else
        null;
    const surface_label = if ((flags & retained_trace_flag_has_surface) != 0)
        try reader.readBytesWithLen(label_buffer, label_cursor)
    else
        null;
    if (!reader.isDone()) return error.CorruptData;

    return .{
        .sequence_no = sequence_no,
        .timestamp_ns = timestamp_ns,
        .category = category,
        .label = label,
        .value = value,
        .lineage = .{
            .cause_sequence_no = cause_sequence_no,
            .correlation_id = correlation_id,
            .surface_label = surface_label,
        },
    };
}

const RetainedTraceBufferWriter = struct {
    buffer: []u8,
    position: usize = 0,

    fn init(buffer: []u8) RetainedTraceBufferWriter {
        return .{ .buffer = buffer };
    }

    fn writeInt(self: *RetainedTraceBufferWriter, comptime T: type, value: T) artifact.record_log.ArtifactRecordLogError!void {
        if (self.buffer.len - self.position < @sizeOf(T)) return error.NoSpaceLeft;
        std.mem.writeInt(T, self.buffer[self.position..][0..@sizeOf(T)], value, .little);
        self.position += @sizeOf(T);
    }

    fn writeAll(self: *RetainedTraceBufferWriter, bytes: []const u8) artifact.record_log.ArtifactRecordLogError!void {
        if (self.buffer.len - self.position < bytes.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.position .. self.position + bytes.len], bytes);
        self.position += bytes.len;
    }

    fn writeBytesWithLen(self: *RetainedTraceBufferWriter, bytes: []const u8) artifact.record_log.ArtifactRecordLogError!void {
        try self.writeInt(u16, std.math.cast(u16, bytes.len) orelse return error.Overflow);
        try self.writeAll(bytes);
    }

    fn finish(self: *const RetainedTraceBufferWriter) []const u8 {
        return self.buffer[0..self.position];
    }
};

const RetainedTraceBufferReader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn init(bytes: []const u8) RetainedTraceBufferReader {
        return .{ .bytes = bytes };
    }

    fn readInt(self: *RetainedTraceBufferReader, comptime T: type) artifact.record_log.ArtifactRecordLogError!T {
        if (self.bytes.len - self.position < @sizeOf(T)) return error.CorruptData;
        const value = std.mem.readInt(T, self.bytes[self.position..][0..@sizeOf(T)], .little);
        self.position += @sizeOf(T);
        return value;
    }

    fn readBytesWithLen(
        self: *RetainedTraceBufferReader,
        label_buffer: []u8,
        label_cursor: *usize,
    ) artifact.record_log.ArtifactRecordLogError![]const u8 {
        const len = try self.readInt(u16);
        if (self.bytes.len - self.position < len) return error.CorruptData;
        if (label_buffer.len - label_cursor.* < len) return error.NoSpaceLeft;
        const out = label_buffer[label_cursor.* .. label_cursor.* + len];
        @memcpy(out, self.bytes[self.position .. self.position + len]);
        self.position += len;
        label_cursor.* += len;
        return out;
    }

    fn isDone(self: *const RetainedTraceBufferReader) bool {
        return self.position == self.bytes.len;
    }
};

test "trace buffer appends in order and snapshot metadata matches" {
    var storage: [3]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{ .max_events = 3, .start_sequence_no = 9 });

    try buffer.append(.{
        .timestamp_ns = 1_000,
        .category = .info,
        .label = "boot",
    });
    try buffer.append(.{
        .timestamp_ns = 2_000,
        .category = .decision,
        .label = "step",
        .value = 7,
    });

    const snapshot = buffer.snapshot();
    const metadata = snapshot.metadata();

    try std.testing.expectEqual(@as(u32, 9), snapshot.items[0].sequence_no);
    try std.testing.expectEqual(@as(u32, 10), snapshot.items[1].sequence_no);
    try std.testing.expectEqual(@as(u32, 2), metadata.event_count);
    try std.testing.expect(metadata.has_range);
}

test "trace buffer marks truncation and keeps successful entries unchanged" {
    var storage: [1]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{ .max_events = 1 });

    try buffer.append(.{
        .timestamp_ns = 1,
        .category = .input,
        .label = "first",
    });
    try std.testing.expectError(error.NoSpaceLeft, buffer.append(.{
        .timestamp_ns = 2,
        .category = .input,
        .label = "second",
    }));

    try std.testing.expectEqual(@as(usize, 1), buffer.snapshot().items.len);
    try std.testing.expect(buffer.snapshot().truncated);
}

test "trace buffer reset clears count and truncation" {
    var storage: [2]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{ .max_events = 2, .start_sequence_no = 4 });

    try buffer.append(.{
        .timestamp_ns = 1,
        .category = .check,
        .label = "pre",
    });
    buffer.reset();

    const snapshot = buffer.snapshot();
    try std.testing.expectEqual(@as(usize, 0), snapshot.items.len);
    try std.testing.expect(!snapshot.truncated);
    try std.testing.expectEqual(@as(u32, 4), buffer.next_sequence_no);
}

test "trace snapshot exports deterministic chrome trace json" {
    // Method: Assert the full emitted JSON so field order, timestamp scaling,
    // and value serialization stay stable for external tooling.
    var storage: [1]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{ .max_events = 1 });
    try buffer.append(.{
        .timestamp_ns = 10_000,
        .category = .bench,
        .label = "sample",
        .value = 3,
    });

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try buffer.snapshot().writeChromeTraceJson(&aw.writer);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"sample\",\"cat\":\"bench\",\"ph\":\"i\",\"ts\":10,\"pid\":0,\"tid\":0,\"s\":\"t\",\"args\":{\"seq\":0,\"value\":3}}]",
        out.items,
    );
}

test "captureSnapshot copies labels and lineage into caller-owned buffers" {
    var storage: [2]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{
        .max_events = 2,
        .start_sequence_no = 11,
    });
    try buffer.append(.{
        .timestamp_ns = 5,
        .category = .decision,
        .label = "choose",
        .value = 7,
    });
    try buffer.append(.{
        .timestamp_ns = 6,
        .category = .info,
        .label = "apply",
        .value = 9,
        .lineage = .{
            .cause_sequence_no = 11,
            .correlation_id = 22,
            .surface_label = "lane",
        },
    });

    const original = buffer.snapshot();
    var copied_events: [2]TraceEvent = undefined;
    var copied_labels: [32]u8 = undefined;
    const copied = try captureSnapshot(.{
        .events_buffer = &copied_events,
        .label_buffer = &copied_labels,
    }, original);

    storage[0].label = "mutated";
    storage[1].label = "other";
    storage[1].lineage.surface_label = "changed";

    try std.testing.expectEqual(@as(usize, 2), copied.items.len);
    try std.testing.expectEqualStrings("choose", copied.items[0].label);
    try std.testing.expectEqualStrings("apply", copied.items[1].label);
    try std.testing.expectEqualStrings("lane", copied.items[1].lineage.surface_label.?);
    try std.testing.expectEqual(@as(u32, 11), copied.items[0].sequence_no);
    try std.testing.expectEqual(@as(u32, 12), copied.items[1].sequence_no);
}

test "trace snapshot exports multiple events in insertion order" {
    var storage: [2]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{
        .max_events = 2,
        .start_sequence_no = 9,
    });
    try buffer.append(.{
        .timestamp_ns = 1_000,
        .category = .info,
        .label = "boot",
        .value = 1,
    });
    try buffer.append(.{
        .timestamp_ns = 2_500,
        .category = .decision,
        .label = "choose",
        .value = 7,
    });

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try buffer.snapshot().writeChromeTraceJson(&aw.writer);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"boot\",\"cat\":\"info\",\"ph\":\"i\",\"ts\":1,\"pid\":0,\"tid\":0,\"s\":\"t\",\"args\":{\"seq\":9,\"value\":1}},{\"name\":\"choose\",\"cat\":\"decision\",\"ph\":\"i\",\"ts\":2,\"pid\":0,\"tid\":0,\"s\":\"t\",\"args\":{\"seq\":10,\"value\":7}}]",
        out.items,
    );
}

test "trace snapshot summarizes causal lineage and formats deterministic text" {
    var storage: [3]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{ .max_events = 3, .start_sequence_no = 20 });
    try buffer.append(.{
        .timestamp_ns = 1_000,
        .category = .info,
        .label = "boot",
        .value = 1,
    });
    try buffer.append(.{
        .timestamp_ns = 2_000,
        .category = .decision,
        .label = "choose",
        .value = 22,
        .lineage = .{
            .cause_sequence_no = 20,
            .correlation_id = 99,
            .surface_label = "scheduler",
        },
    });
    try buffer.append(.{
        .timestamp_ns = 3_000,
        .category = .info,
        .label = "deliver",
        .value = 22,
        .lineage = .{
            .cause_sequence_no = 21,
            .correlation_id = 99,
            .surface_label = "mailbox",
        },
    });

    const snapshot = buffer.snapshot();
    const summary = snapshot.provenanceSummary();
    try std.testing.expect(summary.has_provenance);
    try std.testing.expectEqual(@as(u32, 2), summary.caused_event_count);
    try std.testing.expectEqual(@as(u32, 1), summary.root_event_count);
    try std.testing.expectEqual(@as(u32, 2), summary.correlated_event_count);
    try std.testing.expectEqual(@as(u32, 2), summary.surface_labeled_event_count);
    try std.testing.expectEqual(@as(u16, 2), summary.max_causal_depth);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try snapshot.writeCausalityText(&aw.writer);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "seq=20 label=boot cause_seq=root\nseq=21 label=choose cause_seq=20 correlation_id=99 surface=scheduler\nseq=22 label=deliver cause_seq=21 correlation_id=99 surface=mailbox",
        out.items,
    );
}

test "retained trace file preserves bounded events and lineage" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var storage: [2]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{
        .max_events = 2,
        .start_sequence_no = 17,
    });
    try buffer.append(.{
        .timestamp_ns = 100,
        .category = .decision,
        .label = "choose",
        .value = 7,
    });
    try buffer.append(.{
        .timestamp_ns = 130,
        .category = .info,
        .label = "apply",
        .value = 11,
        .lineage = .{
            .cause_sequence_no = 17,
            .correlation_id = 44,
            .surface_label = "mailbox",
        },
    });

    var file_buffer: [1024]u8 = undefined;
    var frame_buffer: [256]u8 = undefined;
    _ = try writeRetainedTraceFile(io, tmp_dir.dir, "trace_events.binlog", .{
        .file_buffer = &file_buffer,
        .frame_buffer = &frame_buffer,
    }, buffer.snapshot());

    var read_file_buffer: [1024]u8 = undefined;
    var read_events: [2]TraceEvent = undefined;
    var read_labels: [256]u8 = undefined;
    const snapshot = try readRetainedTraceFile(io, tmp_dir.dir, "trace_events.binlog", .{
        .file_buffer = &read_file_buffer,
        .events_buffer = &read_events,
        .label_buffer = &read_labels,
    });

    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(@as(u32, 17), snapshot.items[0].sequence_no);
    try std.testing.expectEqualStrings("apply", snapshot.items[1].label);
    try std.testing.expectEqual(@as(?u32, 17), snapshot.items[1].lineage.cause_sequence_no);
    try std.testing.expectEqual(@as(?u64, 44), snapshot.items[1].lineage.correlation_id);
    try std.testing.expectEqualStrings("mailbox", snapshot.items[1].lineage.surface_label.?);
}

test "retained trace file validates bounded path and buffer inputs" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var storage: [1]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{ .max_events = 1 });
    try buffer.append(.{
        .timestamp_ns = 1,
        .category = .info,
        .label = "boot",
    });

    var file_buffer: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidInput, writeRetainedTraceFile(
        io,
        tmp_dir.dir,
        "",
        .{
            .file_buffer = &file_buffer,
            .frame_buffer = &[_]u8{},
        },
        buffer.snapshot(),
    ));

    var read_file_buffer: [256]u8 = undefined;
    var read_labels: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidInput, readRetainedTraceFile(
        io,
        tmp_dir.dir,
        "",
        .{
            .file_buffer = &read_file_buffer,
            .events_buffer = &[_]TraceEvent{},
            .label_buffer = &read_labels,
        },
    ));
}

test "trace buffer validates sequence boundaries and storage bounds" {
    var small_storage: [1]TraceEvent = undefined;
    try std.testing.expectError(error.InvalidConfig, TraceBuffer.init(&small_storage, .{
        .max_events = 0,
    }));
    try std.testing.expectError(error.InvalidConfig, TraceBuffer.init(&small_storage, .{
        .max_events = 2,
    }));

    var boundary_storage: [2]TraceEvent = undefined;
    const boundary = try TraceBuffer.init(&boundary_storage, .{
        .max_events = 1,
        .start_sequence_no = std.math.maxInt(u32),
    });
    try std.testing.expectEqual(std.math.maxInt(u32), boundary.next_sequence_no);

    try std.testing.expectError(error.InvalidConfig, TraceBuffer.init(&boundary_storage, .{
        .max_events = 2,
        .start_sequence_no = std.math.maxInt(u32),
    }));
}

test "trace buffer supports the final valid u32 sequence number without overflow" {
    var storage: [1]TraceEvent = undefined;
    var buffer = try TraceBuffer.init(&storage, .{
        .max_events = 1,
        .start_sequence_no = std.math.maxInt(u32),
    });

    try buffer.append(.{
        .timestamp_ns = 1,
        .category = .info,
        .label = "boundary",
    });

    try std.testing.expectEqual(@as(usize, 0), buffer.freeSlots());
    try std.testing.expectEqual(std.math.maxInt(u32), buffer.snapshot().items[0].sequence_no);
    try std.testing.expectEqual(std.math.maxInt(u32), buffer.next_sequence_no);
    try std.testing.expectError(error.NoSpaceLeft, buffer.append(.{
        .timestamp_ns = 2,
        .category = .info,
        .label = "overflow_guard",
    }));
}
