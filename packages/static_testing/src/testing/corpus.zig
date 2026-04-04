//! Bounded corpus naming and persistence helpers for replay artifacts.
//!
//! Phase 2 persists one replay artifact per failing case. The helper keeps the
//! file naming scheme deterministic and filesystem-safe by excluding arbitrary
//! run labels from the file name and using only normalized identifiers.

const std = @import("std");
const core = @import("static_core");
const identity = @import("identity.zig");
const replay_artifact = @import("replay_artifact.zig");
const seed_mod = @import("seed.zig");
const trace = @import("trace.zig");

/// Errors returned by corpus name formatting.
pub const CorpusNamingError = error{
    InvalidInput,
    NoSpaceLeft,
    Overflow,
};

/// Errors returned by corpus writes.
pub const CorpusWriteError = CorpusNamingError ||
    replay_artifact.ReplayArtifactError ||
    std.Io.Dir.WriteFileError;

/// Errors returned by corpus reads.
pub const CorpusReadError = error{InvalidInput} ||
    replay_artifact.ReplayArtifactError ||
    std.Io.Dir.ReadFileError;

/// Metadata describing one persisted corpus entry.
///
/// `entry_name` borrows the caller-provided name buffer on write, or the
/// caller-provided file name on read.
pub const CorpusEntryMeta = struct {
    entry_name: []const u8,
    identity_hash: u64,
    artifact_bytes_len: u32,
};

/// Decoded corpus entry view.
pub const CorpusEntry = struct {
    meta: CorpusEntryMeta,
    artifact: replay_artifact.ReplayArtifactView,
};

/// Deterministic corpus naming options.
pub const CorpusNaming = struct {
    prefix: []const u8 = "fuzz",
    extension: []const u8 = ".bin",

    /// Format a deterministic corpus file name into caller-owned storage.
    pub fn formatEntryName(
        self: CorpusNaming,
        buffer: []u8,
        run_identity: identity.RunIdentity,
    ) CorpusNamingError![]const u8 {
        try validateNamePart(self.prefix);
        try validateExtension(self.extension);

        const required_len = try entryNameLen(self);
        if (required_len > std.Io.Dir.max_name_bytes) return error.InvalidInput;
        if (buffer.len < required_len) return error.NoSpaceLeft;

        const seed_text = seed_mod.formatSeed(run_identity.seed);
        const identity_hash = identity.identityHash(run_identity);
        const entry_name = std.fmt.bufPrint(
            buffer,
            "{s}-{s}-{d:0>10}-{d:0>10}-{x:0>16}{s}",
            .{
                self.prefix,
                seed_text[0..],
                run_identity.case_index,
                run_identity.run_index,
                identity_hash,
                self.extension,
            },
        ) catch return error.NoSpaceLeft;

        std.debug.assert(entry_name.len == required_len);
        return entry_name;
    }
};

comptime {
    core.errors.assertVocabularySubset(CorpusNamingError);
}

/// Encode and write one replay artifact using a deterministic corpus file name.
pub fn writeCorpusEntry(
    io: std.Io,
    dir: std.Io.Dir,
    naming: CorpusNaming,
    entry_name_buffer: []u8,
    artifact_buffer: []u8,
    run_identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
) CorpusWriteError!CorpusEntryMeta {
    assertTraceMetadata(trace_metadata);

    const artifact_len = try replay_artifact.encodeReplayArtifact(
        artifact_buffer,
        run_identity,
        trace_metadata,
    );
    const entry_name = try naming.formatEntryName(entry_name_buffer, run_identity);
    try dir.writeFile(io, .{
        .sub_path = entry_name,
        .data = artifact_buffer[0..artifact_len],
        .flags = .{ .exclusive = true },
    });

    return .{
        .entry_name = entry_name,
        .identity_hash = identity.identityHash(run_identity),
        .artifact_bytes_len = @as(u32, @intCast(artifact_len)),
    };
}

/// Read and decode one replay artifact from a deterministic corpus file name.
pub fn readCorpusEntry(
    io: std.Io,
    dir: std.Io.Dir,
    entry_name: []const u8,
    artifact_buffer: []u8,
) CorpusReadError!CorpusEntry {
    if (entry_name.len == 0) return error.InvalidInput;

    const artifact_bytes = try dir.readFile(io, entry_name, artifact_buffer);
    const artifact = try replay_artifact.decodeReplayArtifact(artifact_bytes);

    return .{
        .meta = .{
            .entry_name = entry_name,
            .identity_hash = identity.identityHash(artifact.identity),
            .artifact_bytes_len = artifact.header.bytes_total,
        },
        .artifact = artifact,
    };
}

fn entryNameLen(naming: CorpusNaming) CorpusNamingError!usize {
    var len_total = naming.prefix.len;
    len_total = std.math.add(usize, len_total, 1) catch return error.Overflow;
    len_total = std.math.add(usize, len_total, seed_mod.formatted_seed_len) catch return error.Overflow;
    len_total = std.math.add(usize, len_total, 1) catch return error.Overflow;
    len_total = std.math.add(usize, len_total, 10) catch return error.Overflow;
    len_total = std.math.add(usize, len_total, 1) catch return error.Overflow;
    len_total = std.math.add(usize, len_total, 10) catch return error.Overflow;
    len_total = std.math.add(usize, len_total, 1) catch return error.Overflow;
    len_total = std.math.add(usize, len_total, 16) catch return error.Overflow;
    len_total = std.math.add(usize, len_total, naming.extension.len) catch return error.Overflow;
    return len_total;
}

fn validateNamePart(text: []const u8) CorpusNamingError!void {
    if (text.len == 0) return error.InvalidInput;

    for (text) |byte| {
        if (!isNormalizedNameByte(byte)) return error.InvalidInput;
    }
}

fn validateExtension(text: []const u8) CorpusNamingError!void {
    if (text.len < 2) return error.InvalidInput;
    if (text[0] != '.') return error.InvalidInput;

    for (text[1..]) |byte| {
        if (!isNormalizedNameByte(byte)) return error.InvalidInput;
    }
}

fn isNormalizedNameByte(byte: u8) bool {
    if (std.ascii.isLower(byte)) return true;
    if (std.ascii.isDigit(byte)) return true;
    return byte == '-' or byte == '_';
}

fn assertTraceMetadata(metadata: trace.TraceMetadata) void {
    if (metadata.event_count == 0) {
        std.debug.assert(!metadata.has_range);
        std.debug.assert(metadata.first_sequence_no == 0);
        std.debug.assert(metadata.last_sequence_no == 0);
        std.debug.assert(metadata.first_timestamp_ns == 0);
        std.debug.assert(metadata.last_timestamp_ns == 0);
    } else {
        std.debug.assert(metadata.has_range);
        std.debug.assert(metadata.first_sequence_no <= metadata.last_sequence_no);
        std.debug.assert(metadata.first_timestamp_ns <= metadata.last_timestamp_ns);
    }
}

test "corpus naming is stable and rejects invalid prefixes" {
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "corpus_name",
        .seed = .{ .value = 44 },
        .build_mode = .debug,
        .case_index = 3,
        .run_index = 5,
    });
    const naming = CorpusNaming{
        .prefix = "phase2_corpus",
        .extension = ".art",
    };
    var name_buffer_a: [128]u8 = undefined;
    var name_buffer_b: [128]u8 = undefined;

    const first = try naming.formatEntryName(&name_buffer_a, run_identity);
    const second = try naming.formatEntryName(&name_buffer_b, run_identity);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectError(
        error.InvalidInput,
        (CorpusNaming{ .prefix = "bad name" }).formatEntryName(&name_buffer_a, run_identity),
    );
    try std.testing.expectError(
        error.InvalidInput,
        (CorpusNaming{ .extension = "bin" }).formatEntryName(&name_buffer_a, run_identity),
    );
}

test "corpus write/read round-trip preserves artifact identity and rejects duplicates" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "corpus_roundtrip",
        .seed = .{ .value = 91 },
        .build_mode = .debug,
        .case_index = 4,
        .run_index = 0,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 4,
        .last_sequence_no = 4,
        .first_timestamp_ns = 900,
        .last_timestamp_ns = 900,
    };
    const naming = CorpusNaming{
        .prefix = "phase2_corpus",
    };
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    const written_meta = try writeCorpusEntry(
        io,
        tmp_dir.dir,
        naming,
        &entry_name_buffer,
        &artifact_buffer,
        run_identity,
        trace_metadata,
    );

    try std.testing.expectEqual(identity.identityHash(run_identity), written_meta.identity_hash);
    try std.testing.expectError(
        error.PathAlreadyExists,
        writeCorpusEntry(
            io,
            tmp_dir.dir,
            naming,
            &entry_name_buffer,
            &artifact_buffer,
            run_identity,
            trace_metadata,
        ),
    );

    var read_buffer: [256]u8 = undefined;
    const entry = try readCorpusEntry(io, tmp_dir.dir, written_meta.entry_name, &read_buffer);

    try std.testing.expectEqual(written_meta.identity_hash, entry.meta.identity_hash);
    try std.testing.expectEqualStrings(run_identity.package_name, entry.artifact.identity.package_name);
    try std.testing.expectEqualStrings(run_identity.run_name, entry.artifact.identity.run_name);
    try std.testing.expectEqual(trace_metadata.last_timestamp_ns, entry.artifact.trace_metadata.last_timestamp_ns);
}

test "corpus naming rejects undersized name buffers" {
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "small_name_buffer",
        .seed = .{ .value = 5 },
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 1,
    });
    var small_buffer: [8]u8 = undefined;

    try std.testing.expectError(
        error.NoSpaceLeft,
        (CorpusNaming{}).formatEntryName(&small_buffer, run_identity),
    );
}

test "corpus write rejects undersized artifact buffers" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "small_artifact_buffer",
        .seed = .{ .value = 12 },
        .build_mode = .debug,
        .case_index = 0,
        .run_index = 0,
    });
    const trace_metadata: trace.TraceMetadata = .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 1,
        .last_sequence_no = 1,
        .first_timestamp_ns = 10,
        .last_timestamp_ns = 10,
    };
    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [8]u8 = undefined;

    try std.testing.expectError(error.NoSpaceLeft, writeCorpusEntry(
        threaded_io.io(),
        tmp_dir.dir,
        .{},
        &entry_name_buffer,
        &artifact_buffer,
        run_identity,
        trace_metadata,
    ));
}
