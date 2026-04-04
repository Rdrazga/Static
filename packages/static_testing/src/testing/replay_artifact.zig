//! Versioned replay artifact encoding for phase-1 identity and trace metadata.
//!
//! Phase 1 intentionally persists trace metadata rather than full trace payloads.
//! This is enough to exercise:
//! - stable identity wiring;
//! - explicit format versioning;
//! - file-boundary round-trips; and
//! - later mismatch detection against richer replay artifacts.

const std = @import("std");
const core = @import("static_core");
const serial = @import("static_serial");
const identity = @import("identity.zig");
const trace = @import("trace.zig");

/// Operating errors surfaced by replay artifact encode/decode.
pub const ReplayArtifactError = error{
    NoSpaceLeft,
    EndOfStream,
    CorruptData,
    Unsupported,
    Overflow,
};

/// Fixed artifact magic for replay metadata files.
pub const artifact_magic = [_]u8{ 'S', 'T', 'T', 'A', 'R', 'T', 'F', '1' };
/// Flag bit indicating that the source trace was truncated.
pub const trace_flag_truncated: u16 = 1 << 0;
/// Flag bit indicating that first/last sequence and timestamp ranges are present.
pub const trace_flag_has_range: u16 = 1 << 1;
const trace_flags_known_mask: u16 = trace_flag_truncated | trace_flag_has_range;
/// Encoded header width before variable-length strings.
pub const header_fixed_size_bytes: usize = computeHeaderFixedSizeBytes();

/// Fixed-width decoded replay artifact header.
pub const ReplayArtifactHeader = struct {
    version: identity.ArtifactVersion,
    flags: u16,
    bytes_total: u32,
    trace_event_count: u32,
    package_name_len: u16,
    run_name_len: u16,
    build_mode: identity.BuildMode,
    case_index: u32,
    run_index: u32,
    seed_value: u64,
    first_sequence_no: u32,
    last_sequence_no: u32,
    first_timestamp_ns: u64,
    last_timestamp_ns: u64,

    /// Report whether the truncated-trace flag is set.
    pub fn traceTruncated(self: ReplayArtifactHeader) bool {
        return (self.flags & trace_flag_truncated) != 0;
    }

    /// Report whether the trace-range flag is set.
    pub fn traceHasRange(self: ReplayArtifactHeader) bool {
        return (self.flags & trace_flag_has_range) != 0;
    }
};

/// Fully decoded replay artifact view over caller-owned bytes.
pub const ReplayArtifactView = struct {
    bytes: []const u8,
    header: ReplayArtifactHeader,
    identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
};

/// Convenience wrapper for encoding into caller-owned storage.
pub const ReplayArtifactWriter = struct {
    buffer: []u8,

    /// Bind one caller-owned output buffer.
    pub fn init(buffer: []u8) ReplayArtifactWriter {
        return .{ .buffer = buffer };
    }

    /// Encode one replay artifact into the bound buffer.
    pub fn encode(
        self: *ReplayArtifactWriter,
        run_identity: identity.RunIdentity,
        trace_metadata: trace.TraceMetadata,
    ) ReplayArtifactError!usize {
        return encodeReplayArtifact(self.buffer, run_identity, trace_metadata);
    }
};

comptime {
    core.errors.assertVocabularySubset(ReplayArtifactError);
    std.debug.assert(artifact_magic.len == 8);
    std.debug.assert(@intFromEnum(identity.ArtifactVersion.v1) == 1);
    std.debug.assert(header_fixed_size_bytes == 66);
}

/// Encode one replay artifact into caller-owned storage.
pub fn encodeReplayArtifact(
    buffer: []u8,
    run_identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
) ReplayArtifactError!usize {
    std.debug.assert(run_identity.package_name.len > 0);
    std.debug.assert(run_identity.run_name.len > 0);
    assertValidTraceMetadata(trace_metadata);

    const encoded_len = try encodedLen(run_identity);
    if (buffer.len < encoded_len) return error.NoSpaceLeft;

    const header = makeHeader(run_identity, trace_metadata, encoded_len);
    var writer = serial.writer.Writer.init(buffer[0..encoded_len]);

    try writeBytes(&writer, &artifact_magic);
    try writeInt(&writer, @intFromEnum(header.version));
    try writeInt(&writer, header.flags);
    try writeInt(&writer, header.bytes_total);
    try writeInt(&writer, header.trace_event_count);
    try writeInt(&writer, header.package_name_len);
    try writeInt(&writer, header.run_name_len);
    try writeInt(&writer, @intFromEnum(header.build_mode));
    try writeInt(&writer, @as(u8, 0));
    try writeInt(&writer, header.case_index);
    try writeInt(&writer, header.run_index);
    try writeInt(&writer, header.seed_value);
    try writeInt(&writer, header.first_sequence_no);
    try writeInt(&writer, header.last_sequence_no);
    try writeInt(&writer, header.first_timestamp_ns);
    try writeInt(&writer, header.last_timestamp_ns);
    try writeBytes(&writer, run_identity.package_name);
    try writeBytes(&writer, run_identity.run_name);

    std.debug.assert(writer.position() == encoded_len);
    return encoded_len;
}

/// Decode one replay artifact from caller-owned bytes.
pub fn decodeReplayArtifact(bytes: []const u8) ReplayArtifactError!ReplayArtifactView {
    var reader = serial.reader.Reader.init(bytes);
    const magic = reader.readBytes(artifact_magic.len) catch |err| return mapReaderError(err);
    if (!std.mem.eql(u8, magic, &artifact_magic)) return error.CorruptData;

    const version_raw = try readValue(&reader, u16);
    const version = decodeVersion(version_raw) catch return error.Unsupported;
    const flags = try readValue(&reader, u16);
    const bytes_total = try readValue(&reader, u32);
    if (bytes_total > bytes.len) return error.EndOfStream;
    if (bytes_total < bytes.len) return error.CorruptData;

    const trace_event_count = try readValue(&reader, u32);
    const package_name_len = try readValue(&reader, u16);
    const run_name_len = try readValue(&reader, u16);
    const build_mode = try decodeBuildMode(try readValue(&reader, u8));
    try validateReservedByte(try readValue(&reader, u8));
    const case_index = try readValue(&reader, u32);
    const run_index = try readValue(&reader, u32);
    const seed_value = try readValue(&reader, u64);
    const first_sequence_no = try readValue(&reader, u32);
    const last_sequence_no = try readValue(&reader, u32);
    const first_timestamp_ns = try readValue(&reader, u64);
    const last_timestamp_ns = try readValue(&reader, u64);
    const package_name = reader.readBytes(package_name_len) catch |err| return mapReaderError(err);
    const run_name = reader.readBytes(run_name_len) catch |err| return mapReaderError(err);

    if (package_name.len == 0) return error.CorruptData;
    if (run_name.len == 0) return error.CorruptData;
    try validateFlags(flags);
    if (reader.remaining() != 0) return error.CorruptData;

    const header = ReplayArtifactHeader{
        .version = version,
        .flags = flags,
        .bytes_total = bytes_total,
        .trace_event_count = trace_event_count,
        .package_name_len = package_name_len,
        .run_name_len = run_name_len,
        .build_mode = build_mode,
        .case_index = case_index,
        .run_index = run_index,
        .seed_value = seed_value,
        .first_sequence_no = first_sequence_no,
        .last_sequence_no = last_sequence_no,
        .first_timestamp_ns = first_timestamp_ns,
        .last_timestamp_ns = last_timestamp_ns,
    };
    const trace_metadata = decodeTraceMetadata(header);
    try validateTraceMetadata(trace_metadata);
    const run_identity = identity.makeRunIdentity(.{
        .package_name = package_name,
        .run_name = run_name,
        .seed = .{ .value = seed_value },
        .artifact_version = version,
        .build_mode = build_mode,
        .case_index = case_index,
        .run_index = run_index,
    });

    return .{
        .bytes = bytes,
        .header = header,
        .identity = run_identity,
        .trace_metadata = trace_metadata,
    };
}

fn makeHeader(
    run_identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
    encoded_len: usize,
) ReplayArtifactHeader {
    var flags: u16 = 0;
    if (trace_metadata.truncated) flags |= trace_flag_truncated;
    if (trace_metadata.has_range) flags |= trace_flag_has_range;

    return .{
        .version = run_identity.artifact_version,
        .flags = flags,
        .bytes_total = @as(u32, @intCast(encoded_len)),
        .trace_event_count = trace_metadata.event_count,
        .package_name_len = @as(u16, @intCast(run_identity.package_name.len)),
        .run_name_len = @as(u16, @intCast(run_identity.run_name.len)),
        .build_mode = run_identity.build_mode,
        .case_index = run_identity.case_index,
        .run_index = run_identity.run_index,
        .seed_value = run_identity.seed.value,
        .first_sequence_no = trace_metadata.first_sequence_no,
        .last_sequence_no = trace_metadata.last_sequence_no,
        .first_timestamp_ns = trace_metadata.first_timestamp_ns,
        .last_timestamp_ns = trace_metadata.last_timestamp_ns,
    };
}

fn computeHeaderFixedSizeBytes() usize {
    return artifact_magic.len +
        @sizeOf(u16) +
        @sizeOf(u16) +
        @sizeOf(u32) +
        @sizeOf(u32) +
        @sizeOf(u16) +
        @sizeOf(u16) +
        @sizeOf(u8) +
        @sizeOf(u8) +
        @sizeOf(u32) +
        @sizeOf(u32) +
        @sizeOf(u64) +
        @sizeOf(u32) +
        @sizeOf(u32) +
        @sizeOf(u64) +
        @sizeOf(u64);
}

fn encodedLen(run_identity: identity.RunIdentity) ReplayArtifactError!usize {
    const names_len = std.math.add(usize, run_identity.package_name.len, run_identity.run_name.len) catch {
        return error.Overflow;
    };
    if (run_identity.package_name.len > std.math.maxInt(u16)) return error.Overflow;
    if (run_identity.run_name.len > std.math.maxInt(u16)) return error.Overflow;

    return std.math.add(usize, header_fixed_size_bytes, names_len) catch error.Overflow;
}

fn decodeVersion(raw: u16) error{Unsupported}!identity.ArtifactVersion {
    return switch (raw) {
        @intFromEnum(identity.ArtifactVersion.v1) => .v1,
        else => error.Unsupported,
    };
}

fn decodeBuildMode(raw: u8) ReplayArtifactError!identity.BuildMode {
    return switch (raw) {
        @intFromEnum(identity.BuildMode.debug) => .debug,
        @intFromEnum(identity.BuildMode.release_safe) => .release_safe,
        @intFromEnum(identity.BuildMode.release_fast) => .release_fast,
        @intFromEnum(identity.BuildMode.release_small) => .release_small,
        else => error.CorruptData,
    };
}

fn validateReservedByte(raw: u8) ReplayArtifactError!void {
    if (raw != 0) return error.CorruptData;
}

fn validateFlags(flags: u16) ReplayArtifactError!void {
    if ((flags & ~trace_flags_known_mask) != 0) return error.CorruptData;
}

fn decodeTraceMetadata(header: ReplayArtifactHeader) trace.TraceMetadata {
    return .{
        .event_count = header.trace_event_count,
        .truncated = header.traceTruncated(),
        .has_range = header.traceHasRange(),
        .first_sequence_no = header.first_sequence_no,
        .last_sequence_no = header.last_sequence_no,
        .first_timestamp_ns = header.first_timestamp_ns,
        .last_timestamp_ns = header.last_timestamp_ns,
    };
}

fn validateTraceMetadata(metadata: trace.TraceMetadata) ReplayArtifactError!void {
    if (metadata.event_count == 0) {
        if (metadata.has_range) return error.CorruptData;
        if (metadata.first_sequence_no != 0) return error.CorruptData;
        if (metadata.last_sequence_no != 0) return error.CorruptData;
        if (metadata.first_timestamp_ns != 0) return error.CorruptData;
        if (metadata.last_timestamp_ns != 0) return error.CorruptData;
        return;
    }

    if (!metadata.has_range) return error.CorruptData;
    if (metadata.first_sequence_no > metadata.last_sequence_no) return error.CorruptData;
    if (metadata.first_timestamp_ns > metadata.last_timestamp_ns) return error.CorruptData;
}

fn assertValidTraceMetadata(metadata: trace.TraceMetadata) void {
    validateTraceMetadata(metadata) catch |err| switch (err) {
        error.CorruptData => unreachable,
        else => unreachable,
    };
}

fn readValue(reader: *serial.reader.Reader, comptime T: type) ReplayArtifactError!T {
    return reader.readInt(T, .little) catch |err| mapReaderError(err);
}

fn mapReaderError(err: serial.reader.Error) ReplayArtifactError {
    return switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.InvalidInput => error.CorruptData,
        error.Overflow => error.Overflow,
        error.Underflow => error.CorruptData,
        error.CorruptData => error.CorruptData,
    };
}

fn writerError(err: serial.writer.Error) ReplayArtifactError {
    return switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.InvalidInput => error.CorruptData,
        error.Overflow => error.Overflow,
        error.Underflow => error.CorruptData,
    };
}

fn writeBytes(writer: *serial.writer.Writer, bytes: []const u8) ReplayArtifactError!void {
    writer.writeBytes(bytes) catch |err| return writerError(err);
}

fn writeInt(writer: *serial.writer.Writer, value: anytype) ReplayArtifactError!void {
    writer.writeInt(value, .little) catch |err| return writerError(err);
}

test "replay artifact round-trips identity and trace metadata" {
    // Method: Round-trip both identity fields and trace-range flags so the
    // encoded fixed header and variable names are exercised together.
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "artifact_roundtrip",
        .seed = .{ .value = 77 },
        .build_mode = .debug,
        .case_index = 4,
        .run_index = 9,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 2,
        .truncated = true,
        .has_range = true,
        .first_sequence_no = 5,
        .last_sequence_no = 6,
        .first_timestamp_ns = 10,
        .last_timestamp_ns = 20,
    };

    var bytes: [128]u8 = undefined;
    const written = try encodeReplayArtifact(&bytes, run_identity, trace_metadata);
    const view = try decodeReplayArtifact(bytes[0..written]);

    try std.testing.expectEqualStrings(run_identity.package_name, view.identity.package_name);
    try std.testing.expectEqualStrings(run_identity.run_name, view.identity.run_name);
    try std.testing.expectEqual(run_identity.seed.value, view.identity.seed.value);
    try std.testing.expectEqual(trace_metadata.event_count, view.trace_metadata.event_count);
    try std.testing.expect(view.trace_metadata.truncated);
}

test "replay artifact rejects unsupported version" {
    // Method: Corrupt only the version field after a valid encode so the decode
    // failure is pinned to version negotiation rather than payload shape.
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "unsupported_version",
        .seed = .{ .value = 1 },
        .build_mode = .debug,
    });
    const trace_metadata = trace.TraceMetadata{
        .event_count = 0,
        .truncated = false,
        .has_range = false,
        .first_sequence_no = 0,
        .last_sequence_no = 0,
        .first_timestamp_ns = 0,
        .last_timestamp_ns = 0,
    };

    var bytes: [128]u8 = undefined;
    const written = try encodeReplayArtifact(&bytes, run_identity, trace_metadata);
    std.mem.writeInt(u16, bytes[artifact_magic.len..][0..2], 99, .little);

    try std.testing.expectError(error.Unsupported, decodeReplayArtifact(bytes[0..written]));
}

test "replay artifact rejects truncated buffers" {
    // Method: Drop exactly one trailing byte from a valid artifact so the short
    // read is exercised without changing any earlier header fields.
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "truncated",
        .seed = .{ .value = 5 },
        .build_mode = .debug,
    });
    const trace_metadata = trace.TraceMetadata{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 1,
        .last_sequence_no = 1,
        .first_timestamp_ns = 10,
        .last_timestamp_ns = 10,
    };

    var bytes: [128]u8 = undefined;
    const written = try encodeReplayArtifact(&bytes, run_identity, trace_metadata);
    try std.testing.expectError(error.EndOfStream, decodeReplayArtifact(bytes[0 .. written - 1]));
}

test "replay artifact supports empty trace range metadata" {
    // Method: Encode and decode the zero-event form directly so the absence of
    // range fields stays a supported stable boundary.
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "empty_trace",
        .seed = .{ .value = 9 },
        .build_mode = .release_safe,
    });
    const trace_metadata = trace.TraceMetadata{
        .event_count = 0,
        .truncated = false,
        .has_range = false,
        .first_sequence_no = 0,
        .last_sequence_no = 0,
        .first_timestamp_ns = 0,
        .last_timestamp_ns = 0,
    };

    var bytes: [128]u8 = undefined;
    const written = try encodeReplayArtifact(&bytes, run_identity, trace_metadata);
    const view = try decodeReplayArtifact(bytes[0..written]);

    try std.testing.expectEqual(@as(u32, 0), view.trace_metadata.event_count);
    try std.testing.expect(!view.trace_metadata.has_range);
    try std.testing.expect(!view.trace_metadata.truncated);
}

test "replay artifact rejects non-zero reserved bytes" {
    // Method: Mutate only the reserved byte after a valid encode so the test
    // proves that unknown header space is not silently accepted.
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "reserved_byte",
        .seed = .{ .value = 10 },
        .build_mode = .debug,
    });
    const trace_metadata = trace.TraceMetadata{
        .event_count = 0,
        .truncated = false,
        .has_range = false,
        .first_sequence_no = 0,
        .last_sequence_no = 0,
        .first_timestamp_ns = 0,
        .last_timestamp_ns = 0,
    };

    var bytes: [128]u8 = undefined;
    const written = try encodeReplayArtifact(&bytes, run_identity, trace_metadata);
    bytes[25] = 1;

    try std.testing.expectError(error.CorruptData, decodeReplayArtifact(bytes[0..written]));
}

test "replay artifact rejects unknown trace flags for v1" {
    // Method: Add one unsupported flag bit on top of a valid header so the
    // version-specific flag vocabulary remains closed.
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "unknown_flags",
        .seed = .{ .value = 11 },
        .build_mode = .debug,
    });
    const trace_metadata = trace.TraceMetadata{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 1,
        .last_sequence_no = 1,
        .first_timestamp_ns = 1,
        .last_timestamp_ns = 1,
    };

    var bytes: [128]u8 = undefined;
    const written = try encodeReplayArtifact(&bytes, run_identity, trace_metadata);
    std.mem.writeInt(u16, bytes[10..12], trace_flag_has_range | (@as(u16, 1) << 15), .little);

    try std.testing.expectError(error.CorruptData, decodeReplayArtifact(bytes[0..written]));
}

test "replay artifact rejects empty traces that still claim a range" {
    // Method: Flip only the range flag on a zero-event artifact so inconsistent
    // external metadata is rejected at the decode boundary.
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "empty_range_corrupt",
        .seed = .{ .value = 12 },
        .build_mode = .debug,
    });
    const trace_metadata = trace.TraceMetadata{
        .event_count = 0,
        .truncated = false,
        .has_range = false,
        .first_sequence_no = 0,
        .last_sequence_no = 0,
        .first_timestamp_ns = 0,
        .last_timestamp_ns = 0,
    };

    var bytes: [128]u8 = undefined;
    const written = try encodeReplayArtifact(&bytes, run_identity, trace_metadata);
    std.mem.writeInt(u16, bytes[10..12], trace_flag_has_range, .little);

    try std.testing.expectError(error.CorruptData, decodeReplayArtifact(bytes[0..written]));
}

test "replay artifact rejects reversed trace ranges" {
    // Method: Reverse the encoded sequence range after a valid encode so the
    // monotonic trace-range invariant is proven on decode.
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "reversed_range",
        .seed = .{ .value = 13 },
        .build_mode = .debug,
    });
    const trace_metadata = trace.TraceMetadata{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 1,
        .last_sequence_no = 1,
        .first_timestamp_ns = 10,
        .last_timestamp_ns = 10,
    };

    var bytes: [128]u8 = undefined;
    const written = try encodeReplayArtifact(&bytes, run_identity, trace_metadata);
    std.mem.writeInt(u32, bytes[42..46], 7, .little);
    std.mem.writeInt(u32, bytes[46..50], 6, .little);

    try std.testing.expectError(error.CorruptData, decodeReplayArtifact(bytes[0..written]));
}
