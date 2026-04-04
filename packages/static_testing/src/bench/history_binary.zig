//! Bounded benchmark history records with environment metadata.

const std = @import("std");
const builtin = @import("builtin");
const artifact = @import("../artifact/root.zig");
const config = @import("config.zig");
const baseline = @import("baseline.zig");
const stats = @import("stats.zig");
const identity = @import("../testing/identity.zig");

pub const history_version: u16 = 3;

const max_environment_tags: usize = 4;

pub const BenchmarkHistoryError = baseline.BenchmarkBaselineError || error{
    Overflow,
};

pub const HistoryAction = enum(u8) {
    report_only = 1,
    recorded = 2,
    compared = 3,
};

pub const EnvironmentMetadataView = struct {
    package_name: []const u8,
    baseline_path: []const u8,
    target_arch: []const u8,
    target_os: []const u8,
    target_abi: []const u8,
    build_mode: identity.BuildMode,
    benchmark_mode: config.BenchmarkMode,
    host_label: ?[]const u8 = null,
    environment_note: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
};

pub const HistoryRecordView = struct {
    version: u16,
    timestamp_unix_ms: u64,
    action: HistoryAction,
    comparison_passed: ?bool = null,
    environment: EnvironmentMetadataView,
    cases: []const stats.BenchmarkStats,
};

pub const CaptureEnvironmentOptions = struct {
    package_name: []const u8,
    baseline_path: []const u8,
    benchmark_mode: config.BenchmarkMode,
    host_label: ?[]const u8 = null,
    environment_note: ?[]const u8 = null,
    environment_tags: []const []const u8 = &.{},
};

pub const HistoryReadBuffers = struct {
    file_buffer: []u8,
    case_storage: []stats.BenchmarkStats,
    string_buffer: []u8,
    tag_storage: []([]const u8),
};

pub const HistoryAppendBuffers = struct {
    existing_file_buffer: []u8,
    record_buffer: []u8,
    frame_buffer: []u8,
    output_file_buffer: []u8,
};

const null_optional_string_len = std.math.maxInt(u32);

comptime {
    std.debug.assert(history_version == 3);
    std.debug.assert(std.meta.fields(HistoryAction).len == 3);
}

pub fn captureEnvironmentMetadata(options: CaptureEnvironmentOptions) EnvironmentMetadataView {
    std.debug.assert(options.package_name.len > 0);
    std.debug.assert(options.baseline_path.len > 0);
    std.debug.assert(options.environment_tags.len <= max_environment_tags);
    for (options.environment_tags) |tag| {
        std.debug.assert(tag.len > 0);
    }

    return .{
        .package_name = options.package_name,
        .baseline_path = options.baseline_path,
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .target_abi = @tagName(builtin.target.abi),
        .build_mode = identity.BuildMode.fromOptimizeMode(builtin.mode),
        .benchmark_mode = options.benchmark_mode,
        .host_label = options.host_label,
        .environment_note = options.environment_note,
        .tags = options.environment_tags,
    };
}

pub fn encodeRecordBinary(
    buffer: []u8,
    record: HistoryRecordView,
) BenchmarkHistoryError![]const u8 {
    try validateRecord(record);

    var writer = BufferWriter.init(buffer);
    try writer.writeInt(u16, record.version);
    try writer.writeByte(@intFromEnum(record.action));
    try writer.writeByte(encodeOptionalBool(record.comparison_passed));
    try writer.writeInt(u64, record.timestamp_unix_ms);
    try writer.writeByte(@intFromEnum(record.environment.build_mode));
    try writer.writeByte(@intFromEnum(record.environment.benchmark_mode));
    try writer.writeString(record.environment.package_name);
    try writer.writeString(record.environment.baseline_path);
    try writer.writeString(record.environment.target_arch);
    try writer.writeString(record.environment.target_os);
    try writer.writeString(record.environment.target_abi);
    try writer.writeOptionalString(record.environment.host_label);
    try writer.writeOptionalString(record.environment.environment_note);
    try writer.writeInt(u32, std.math.cast(u32, record.environment.tags.len) orelse return error.Overflow);
    for (record.environment.tags) |tag| {
        try writer.writeString(tag);
    }
    try writer.writeInt(u32, std.math.cast(u32, record.cases.len) orelse return error.Overflow);
    for (record.cases) |case_stats| {
        try writer.writeString(case_stats.case_name);
        try writer.writeInt(u32, case_stats.sample_count);
        try writer.writeInt(u64, case_stats.min_elapsed_ns);
        try writer.writeInt(u64, case_stats.max_elapsed_ns);
        try writer.writeInt(u64, case_stats.mean_elapsed_ns);
        try writer.writeInt(u64, case_stats.median_elapsed_ns);
        try writer.writeInt(u64, case_stats.p90_elapsed_ns);
        try writer.writeInt(u64, case_stats.p95_elapsed_ns);
        try writer.writeOptionalU64(case_stats.p99_elapsed_ns);
    }
    return writer.finish();
}

pub fn decodeRecordBinary(
    bytes: []const u8,
    case_storage: []stats.BenchmarkStats,
    string_buffer: []u8,
    tag_storage: []([]const u8),
) BenchmarkHistoryError!HistoryRecordView {
    var reader = BufferReader.init(bytes, string_buffer);
    const version = try reader.readInt(u16);
    return switch (version) {
        1 => decodeRecordBinaryV1(&reader, case_storage),
        2 => decodeRecordBinaryV2(&reader, case_storage),
        3 => decodeRecordBinaryV3(&reader, case_storage, tag_storage),
        else => error.Unsupported,
    };
}

fn decodeRecordBinaryV1(
    reader: *BufferReader,
    case_storage: []stats.BenchmarkStats,
) BenchmarkHistoryError!HistoryRecordView {
    const action = try decodeAction(try reader.readByte());
    const comparison_passed = try decodeOptionalBool(try reader.readByte());
    const timestamp_unix_ms = try reader.readInt(u64);
    const build_mode = try decodeBuildMode(try reader.readByte());
    const benchmark_mode = try decodeBenchmarkMode(try reader.readByte());
    const package_name = try reader.readString();
    const baseline_path = try reader.readString();
    const target_arch = try reader.readString();
    const target_os = try reader.readString();
    const target_abi = try reader.readString();
    const host_label = try reader.readOptionalString();
    const case_count = try reader.readInt(u32);
    if (case_count > case_storage.len) return error.NoSpaceLeft;

    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        case_storage[case_index] = .{
            .case_name = try reader.readString(),
            .sample_count = try reader.readInt(u32),
            .min_elapsed_ns = try reader.readInt(u64),
            .max_elapsed_ns = try reader.readInt(u64),
            .mean_elapsed_ns = try reader.readInt(u64),
            .median_elapsed_ns = try reader.readInt(u64),
            .p90_elapsed_ns = try reader.readInt(u64),
            .p95_elapsed_ns = try reader.readInt(u64),
            .p99_elapsed_ns = null,
        };
        try validateStats(case_storage[case_index]);
    }

    try reader.finish();

    const record: HistoryRecordView = .{
        .version = history_version,
        .timestamp_unix_ms = timestamp_unix_ms,
        .action = action,
        .comparison_passed = comparison_passed,
        .environment = .{
            .package_name = package_name,
            .baseline_path = baseline_path,
            .target_arch = target_arch,
            .target_os = target_os,
            .target_abi = target_abi,
            .build_mode = build_mode,
            .benchmark_mode = benchmark_mode,
            .host_label = host_label,
            .environment_note = null,
            .tags = &.{},
        },
        .cases = case_storage[0..case_count],
    };
    try validateRecord(record);
    return record;
}

fn decodeRecordBinaryV3(
    reader: *BufferReader,
    case_storage: []stats.BenchmarkStats,
    tag_storage: []([]const u8),
) BenchmarkHistoryError!HistoryRecordView {
    const action = try decodeAction(try reader.readByte());
    const comparison_passed = try decodeOptionalBool(try reader.readByte());
    const timestamp_unix_ms = try reader.readInt(u64);
    const build_mode = try decodeBuildMode(try reader.readByte());
    const benchmark_mode = try decodeBenchmarkMode(try reader.readByte());
    const package_name = try reader.readString();
    const baseline_path = try reader.readString();
    const target_arch = try reader.readString();
    const target_os = try reader.readString();
    const target_abi = try reader.readString();
    const host_label = try reader.readOptionalString();
    const environment_note = try reader.readOptionalString();
    const tags = try readEnvironmentTags(reader, tag_storage);
    const record = try decodeRecordCases(
        reader,
        case_storage,
        .{
            .version = 3,
            .timestamp_unix_ms = timestamp_unix_ms,
            .action = action,
            .comparison_passed = comparison_passed,
            .environment = .{
                .package_name = package_name,
                .baseline_path = baseline_path,
                .target_arch = target_arch,
                .target_os = target_os,
                .target_abi = target_abi,
                .build_mode = build_mode,
                .benchmark_mode = benchmark_mode,
                .host_label = host_label,
                .environment_note = environment_note,
                .tags = tags,
            },
            .cases = &.{},
        },
    );
    try validateRecord(record);
    return record;
}

fn decodeRecordBinaryV2(
    reader: *BufferReader,
    case_storage: []stats.BenchmarkStats,
) BenchmarkHistoryError!HistoryRecordView {
    const action = try decodeAction(try reader.readByte());
    const comparison_passed = try decodeOptionalBool(try reader.readByte());
    const timestamp_unix_ms = try reader.readInt(u64);
    const build_mode = try decodeBuildMode(try reader.readByte());
    const benchmark_mode = try decodeBenchmarkMode(try reader.readByte());
    const package_name = try reader.readString();
    const baseline_path = try reader.readString();
    const target_arch = try reader.readString();
    const target_os = try reader.readString();
    const target_abi = try reader.readString();
    const host_label = try reader.readOptionalString();
    const environment_note = try reader.readOptionalString();
    const base_record: HistoryRecordView = .{
        .version = history_version,
        .timestamp_unix_ms = timestamp_unix_ms,
        .action = action,
        .comparison_passed = comparison_passed,
        .environment = .{
            .package_name = package_name,
            .baseline_path = baseline_path,
            .target_arch = target_arch,
            .target_os = target_os,
            .target_abi = target_abi,
            .build_mode = build_mode,
            .benchmark_mode = benchmark_mode,
            .host_label = host_label,
            .environment_note = environment_note,
            .tags = &.{},
        },
        .cases = &.{},
    };

    // Legacy retained histories exist in two v2 layouts: one without per-case
    // p99 fields and a later one that added them without bumping the outer
    // record version. Prefer the richer decode path, then fall back to the
    // earlier layout if the payload shape does not fit.
    var reader_with_p99 = reader.*;
    if (decodeRecordCases(&reader_with_p99, case_storage, base_record)) |record| {
        try validateRecord(record);
        reader.* = reader_with_p99;
        return record;
    } else |err| switch (err) {
        error.CorruptData => {},
        else => return err,
    }

    const case_count = try reader.readInt(u32);
    if (case_count > case_storage.len) return error.NoSpaceLeft;

    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        case_storage[case_index] = .{
            .case_name = try reader.readString(),
            .sample_count = try reader.readInt(u32),
            .min_elapsed_ns = try reader.readInt(u64),
            .max_elapsed_ns = try reader.readInt(u64),
            .mean_elapsed_ns = try reader.readInt(u64),
            .median_elapsed_ns = try reader.readInt(u64),
            .p90_elapsed_ns = try reader.readInt(u64),
            .p95_elapsed_ns = try reader.readInt(u64),
            .p99_elapsed_ns = null,
        };
        try validateStats(case_storage[case_index]);
    }

    try reader.finish();

    const record: HistoryRecordView = .{
        .version = base_record.version,
        .timestamp_unix_ms = base_record.timestamp_unix_ms,
        .action = base_record.action,
        .comparison_passed = base_record.comparison_passed,
        .environment = base_record.environment,
        .cases = case_storage[0..case_count],
    };
    try validateRecord(record);
    return record;
}

fn decodeRecordCases(
    reader: *BufferReader,
    case_storage: []stats.BenchmarkStats,
    base_record: HistoryRecordView,
) BenchmarkHistoryError!HistoryRecordView {
    const case_count = try reader.readInt(u32);
    if (case_count > case_storage.len) return error.NoSpaceLeft;

    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        case_storage[case_index] = .{
            .case_name = try reader.readString(),
            .sample_count = try reader.readInt(u32),
            .min_elapsed_ns = try reader.readInt(u64),
            .max_elapsed_ns = try reader.readInt(u64),
            .mean_elapsed_ns = try reader.readInt(u64),
            .median_elapsed_ns = try reader.readInt(u64),
            .p90_elapsed_ns = try reader.readInt(u64),
            .p95_elapsed_ns = try reader.readInt(u64),
            .p99_elapsed_ns = try reader.readOptionalU64(),
        };
        try validateStats(case_storage[case_index]);
    }

    try reader.finish();

    const record: HistoryRecordView = .{
        .version = base_record.version,
        .timestamp_unix_ms = base_record.timestamp_unix_ms,
        .action = base_record.action,
        .comparison_passed = base_record.comparison_passed,
        .environment = .{
            .package_name = base_record.environment.package_name,
            .baseline_path = base_record.environment.baseline_path,
            .target_arch = base_record.environment.target_arch,
            .target_os = base_record.environment.target_os,
            .target_abi = base_record.environment.target_abi,
            .build_mode = base_record.environment.build_mode,
            .benchmark_mode = base_record.environment.benchmark_mode,
            .host_label = base_record.environment.host_label,
            .environment_note = base_record.environment.environment_note,
            .tags = base_record.environment.tags,
        },
        .cases = case_storage[0..case_count],
    };
    return record;
}

fn readEnvironmentTags(
    reader: *BufferReader,
    tag_storage: []([]const u8),
) BenchmarkHistoryError![]const []const u8 {
    const tag_count = try reader.readInt(u32);
    if (tag_count > tag_storage.len) return error.NoSpaceLeft;

    var tag_index: usize = 0;
    while (tag_index < tag_count) : (tag_index += 1) {
        const tag = try reader.readString();
        if (tag.len == 0) return error.InvalidInput;
        tag_storage[tag_index] = tag;
    }
    return tag_storage[0..tag_count];
}

pub fn readMostRecentCompatibleRecord(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    environment: EnvironmentMetadataView,
    read_buffers: HistoryReadBuffers,
) BenchmarkHistoryError!?HistoryRecordView {
    const file_bytes = artifact.record_log.readLogFile(io, dir, sub_path, read_buffers.file_buffer) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.CorruptData => return error.CorruptData,
        error.Unsupported => return error.Unsupported,
        else => return err,
    };

    var iter = artifact.record_log.iterateRecords(file_bytes) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.CorruptData => return error.CorruptData,
        error.Unsupported => return error.Unsupported,
        else => return err,
    };

    var latest_payload: ?[]const u8 = null;
    while (try iter.next()) |payload| {
        const record = try decodeRecordBinary(payload, read_buffers.case_storage, read_buffers.string_buffer, read_buffers.tag_storage);
        if (isCompatibleRecord(record, environment)) latest_payload = payload;
    }
    if (latest_payload) |payload| {
        return try decodeRecordBinary(payload, read_buffers.case_storage, read_buffers.string_buffer, read_buffers.tag_storage);
    }
    return null;
}

pub fn appendRecordFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    append_buffers: HistoryAppendBuffers,
    max_records: usize,
    record: HistoryRecordView,
) BenchmarkHistoryError![]const u8 {
    const encoded_record = try encodeRecordBinary(append_buffers.record_buffer, record);
    return artifact.record_log.appendRecordFile(
        io,
        dir,
        sub_path,
        .{
            .existing_file_buffer = append_buffers.existing_file_buffer,
            .frame_buffer = append_buffers.frame_buffer,
            .output_file_buffer = append_buffers.output_file_buffer,
        },
        max_records,
        encoded_record,
    ) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.CorruptData => return error.CorruptData,
        error.Unsupported => return error.Unsupported,
        else => return err,
    };
}

pub fn writeLatestCompatibleComparisonText(
    writer: *std.Io.Writer,
    sub_path: []const u8,
    prior_record: ?HistoryRecordView,
    compare_summary: ?baseline.BaselineCompareSummary,
) !void {
    try writer.print("history_path={s}\n", .{sub_path});
    if (prior_record) |record| {
        try writer.print(
            "history_latest timestamp_unix_ms={} package={s} target={s}-{s}-{s} build_mode={s} benchmark_mode={s}",
            .{
                record.timestamp_unix_ms,
                record.environment.package_name,
                record.environment.target_arch,
                record.environment.target_os,
                record.environment.target_abi,
                @tagName(record.environment.build_mode),
                @tagName(record.environment.benchmark_mode),
            },
        );
        if (record.environment.host_label) |host_label| {
            try writer.print(" host_label={s}", .{host_label});
        }
        if (record.environment.environment_note) |environment_note| {
            try writer.print(" environment_note={s}", .{environment_note});
        }
        if (record.environment.tags.len != 0) {
            try writer.writeAll(" environment_tags=");
            for (record.environment.tags, 0..) |tag, index| {
                if (index != 0) try writer.writeByte(',');
                try writer.writeAll(tag);
            }
        }
        try writer.writeByte('\n');
        if (compare_summary) |summary| {
            try baseline.writeComparisonText(writer, summary);
        }
    } else {
        try writer.writeAll("history_latest none\n");
    }
}

pub fn asBaselineArtifact(record: HistoryRecordView) baseline.BaselineArtifactView {
    return .{
        .version = baseline.baseline_version,
        .mode = record.environment.benchmark_mode,
        .cases = record.cases,
    };
}

fn isCompatibleRecord(record: HistoryRecordView, environment: EnvironmentMetadataView) bool {
    return std.mem.eql(u8, record.environment.package_name, environment.package_name) and
        std.mem.eql(u8, record.environment.baseline_path, environment.baseline_path) and
        std.mem.eql(u8, record.environment.target_arch, environment.target_arch) and
        std.mem.eql(u8, record.environment.target_os, environment.target_os) and
        std.mem.eql(u8, record.environment.target_abi, environment.target_abi) and
        record.environment.build_mode == environment.build_mode and
        record.environment.benchmark_mode == environment.benchmark_mode and
        equalOptionalText(record.environment.host_label, environment.host_label) and
        equalTagLists(record.environment.tags, environment.tags);
}

fn equalOptionalText(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |a_text| {
        if (b) |b_text| return std.mem.eql(u8, a_text, b_text);
        return false;
    }
    return b == null;
}

fn equalTagLists(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |tag, index| {
        if (!std.mem.eql(u8, tag, b[index])) return false;
    }
    return true;
}

fn validateRecord(record: HistoryRecordView) BenchmarkHistoryError!void {
    if (record.version != history_version) return error.InvalidInput;
    if (record.environment.package_name.len == 0) return error.InvalidInput;
    if (record.environment.baseline_path.len == 0) return error.InvalidInput;
    if (record.environment.target_arch.len == 0) return error.InvalidInput;
    if (record.environment.target_os.len == 0) return error.InvalidInput;
    if (record.environment.target_abi.len == 0) return error.InvalidInput;
    if (record.environment.tags.len > max_environment_tags) return error.InvalidInput;
    for (record.environment.tags) |tag| {
        if (tag.len == 0) return error.InvalidInput;
    }
    if (record.environment.host_label) |host_label| {
        if (host_label.len == 0) return error.InvalidInput;
    }
    if (record.environment.environment_note) |environment_note| {
        if (environment_note.len == 0) return error.InvalidInput;
    }
    for (record.cases) |case_stats| {
        try validateStats(case_stats);
    }
}

fn validateStats(case_stats: stats.BenchmarkStats) BenchmarkHistoryError!void {
    if (case_stats.case_name.len == 0) return error.InvalidInput;
    if (case_stats.sample_count == 0) return error.InvalidInput;
    if (case_stats.min_elapsed_ns > case_stats.max_elapsed_ns) return error.InvalidInput;
    if (case_stats.mean_elapsed_ns < case_stats.min_elapsed_ns or case_stats.mean_elapsed_ns > case_stats.max_elapsed_ns) return error.InvalidInput;
    if (case_stats.median_elapsed_ns < case_stats.min_elapsed_ns or case_stats.median_elapsed_ns > case_stats.max_elapsed_ns) return error.InvalidInput;
    if (case_stats.p90_elapsed_ns < case_stats.min_elapsed_ns or case_stats.p90_elapsed_ns > case_stats.max_elapsed_ns) return error.InvalidInput;
    if (case_stats.p95_elapsed_ns < case_stats.min_elapsed_ns or case_stats.p95_elapsed_ns > case_stats.max_elapsed_ns) return error.InvalidInput;
    if (case_stats.p99_elapsed_ns) |p99_elapsed_ns| {
        if (p99_elapsed_ns < case_stats.min_elapsed_ns or p99_elapsed_ns > case_stats.max_elapsed_ns) return error.InvalidInput;
        if (case_stats.p95_elapsed_ns > p99_elapsed_ns) return error.InvalidInput;
    }
    if (case_stats.median_elapsed_ns > case_stats.p90_elapsed_ns) return error.InvalidInput;
    if (case_stats.p90_elapsed_ns > case_stats.p95_elapsed_ns) return error.InvalidInput;
}

fn encodeOptionalBool(value: ?bool) u8 {
    return if (value) |bool_value|
        (if (bool_value) 2 else 1)
    else
        0;
}

fn decodeOptionalBool(value: u8) BenchmarkHistoryError!?bool {
    return switch (value) {
        0 => null,
        1 => false,
        2 => true,
        else => error.CorruptData,
    };
}

fn decodeAction(value: u8) BenchmarkHistoryError!HistoryAction {
    return switch (value) {
        @intFromEnum(HistoryAction.report_only) => .report_only,
        @intFromEnum(HistoryAction.recorded) => .recorded,
        @intFromEnum(HistoryAction.compared) => .compared,
        else => error.CorruptData,
    };
}

fn decodeBuildMode(value: u8) BenchmarkHistoryError!identity.BuildMode {
    return switch (value) {
        @intFromEnum(identity.BuildMode.debug) => .debug,
        @intFromEnum(identity.BuildMode.release_safe) => .release_safe,
        @intFromEnum(identity.BuildMode.release_fast) => .release_fast,
        @intFromEnum(identity.BuildMode.release_small) => .release_small,
        else => error.CorruptData,
    };
}

fn decodeBenchmarkMode(value: u8) BenchmarkHistoryError!config.BenchmarkMode {
    return switch (value) {
        @intFromEnum(config.BenchmarkMode.smoke) => .smoke,
        @intFromEnum(config.BenchmarkMode.full) => .full,
        else => error.CorruptData,
    };
}

const BufferWriter = struct {
    buffer: []u8,
    position: usize = 0,

    fn init(buffer: []u8) BufferWriter {
        return .{ .buffer = buffer };
    }

    fn writeByte(self: *BufferWriter, value: u8) BenchmarkHistoryError!void {
        if (self.position >= self.buffer.len) return error.NoSpaceLeft;
        self.buffer[self.position] = value;
        self.position += 1;
    }

    fn writeInt(self: *BufferWriter, comptime T: type, value: T) BenchmarkHistoryError!void {
        if (self.buffer.len - self.position < @sizeOf(T)) return error.NoSpaceLeft;
        std.mem.writeInt(T, self.buffer[self.position..][0..@sizeOf(T)], value, .little);
        self.position += @sizeOf(T);
    }

    fn writeString(self: *BufferWriter, value: []const u8) BenchmarkHistoryError!void {
        try self.writeInt(u32, std.math.cast(u32, value.len) orelse return error.Overflow);
        if (self.buffer.len - self.position < value.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.position .. self.position + value.len], value);
        self.position += value.len;
    }

    fn writeOptionalString(self: *BufferWriter, value: ?[]const u8) BenchmarkHistoryError!void {
        if (value) |text| {
            try self.writeString(text);
        } else {
            try self.writeInt(u32, null_optional_string_len);
        }
    }

    fn writeOptionalU64(self: *BufferWriter, value: ?u64) BenchmarkHistoryError!void {
        if (value) |elapsed_ns| {
            try self.writeByte(1);
            try self.writeInt(u64, elapsed_ns);
        } else {
            try self.writeByte(0);
        }
    }

    fn finish(self: *const BufferWriter) []const u8 {
        return self.buffer[0..self.position];
    }
};

const BufferReader = struct {
    bytes: []const u8,
    index: usize = 0,
    string_buffer: []u8,
    string_buffer_len: usize = 0,

    fn init(bytes: []const u8, string_buffer: []u8) BufferReader {
        return .{
            .bytes = bytes,
            .string_buffer = string_buffer,
        };
    }

    fn finish(self: *const BufferReader) BenchmarkHistoryError!void {
        if (self.index != self.bytes.len) return error.CorruptData;
    }

    fn readByte(self: *BufferReader) BenchmarkHistoryError!u8 {
        if (self.index >= self.bytes.len) return error.CorruptData;
        const value = self.bytes[self.index];
        self.index += 1;
        return value;
    }

    fn readInt(self: *BufferReader, comptime T: type) BenchmarkHistoryError!T {
        if (self.bytes.len - self.index < @sizeOf(T)) return error.CorruptData;
        const value = std.mem.readInt(T, self.bytes[self.index..][0..@sizeOf(T)], .little);
        self.index += @sizeOf(T);
        return value;
    }

    fn readString(self: *BufferReader) BenchmarkHistoryError![]const u8 {
        const len = try self.readInt(u32);
        return self.readStringWithLen(len);
    }

    fn readOptionalString(self: *BufferReader) BenchmarkHistoryError!?[]const u8 {
        const len = try self.readInt(u32);
        if (len == null_optional_string_len) return null;
        return try self.readStringWithLen(len);
    }

    fn readOptionalU64(self: *BufferReader) BenchmarkHistoryError!?u64 {
        return switch (try self.readByte()) {
            0 => null,
            1 => try self.readInt(u64),
            else => error.CorruptData,
        };
    }

    fn readStringWithLen(self: *BufferReader, len: u32) BenchmarkHistoryError![]const u8 {
        const text_len: usize = len;
        if (self.bytes.len - self.index < text_len) return error.CorruptData;
        if (self.string_buffer.len - self.string_buffer_len < text_len) return error.NoSpaceLeft;
        const start = self.string_buffer_len;
        @memcpy(
            self.string_buffer[start .. start + text_len],
            self.bytes[self.index .. self.index + text_len],
        );
        self.index += text_len;
        self.string_buffer_len += text_len;
        return self.string_buffer[start .. start + text_len];
    }
};

test "history record binary round-trips with environment metadata" {
    const case_stats = [_]stats.BenchmarkStats{
        .{
            .case_name = "event_try_wait_signaled",
            .sample_count = 3,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 20,
            .mean_elapsed_ns = 15,
            .median_elapsed_ns = 15,
            .p90_elapsed_ns = 20,
            .p95_elapsed_ns = 20,
            .p99_elapsed_ns = 20,
        },
    };
    const environment_tags = [_][]const u8{ "smoke", "baseline" };
    var record_buffer: [2048]u8 = undefined;
    const encoded = try encodeRecordBinary(&record_buffer, .{
        .version = history_version,
        .timestamp_unix_ms = 1234,
        .action = .compared,
        .comparison_passed = true,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.zon",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "devbox",
            .environment_note = "lab-a",
            .tags = &environment_tags,
        },
        .cases = &case_stats,
    });

    var decoded_cases: [2]stats.BenchmarkStats = undefined;
    var string_buffer: [256]u8 = undefined;
    var tag_storage: [4][]const u8 = undefined;
    const decoded = try decodeRecordBinary(encoded, &decoded_cases, &string_buffer, &tag_storage);
    try std.testing.expectEqual(HistoryAction.compared, decoded.action);
    try std.testing.expectEqual(@as(u64, 1234), decoded.timestamp_unix_ms);
    try std.testing.expect(decoded.comparison_passed.?);
    try std.testing.expectEqualStrings("static_sync", decoded.environment.package_name);
    try std.testing.expectEqualStrings("devbox", decoded.environment.host_label.?);
    try std.testing.expectEqualStrings("lab-a", decoded.environment.environment_note.?);
    try std.testing.expectEqual(@as(usize, 2), decoded.environment.tags.len);
    try std.testing.expectEqualStrings("smoke", decoded.environment.tags[0]);
    try std.testing.expectEqualStrings("baseline", decoded.environment.tags[1]);
    try std.testing.expectEqualStrings("event_try_wait_signaled", decoded.cases[0].case_name);
    try std.testing.expectEqual(@as(?u64, 20), decoded.cases[0].p99_elapsed_ns);
}

test "decodeRecordBinary reads legacy v1 records without note or p99" {
    var record_buffer: [2048]u8 = undefined;
    var writer = BufferWriter.init(&record_buffer);
    try writer.writeInt(u16, 1);
    try writer.writeByte(@intFromEnum(HistoryAction.recorded));
    try writer.writeByte(encodeOptionalBool(null));
    try writer.writeInt(u64, 99);
    try writer.writeByte(@intFromEnum(identity.BuildMode.release_fast));
    try writer.writeByte(@intFromEnum(config.BenchmarkMode.full));
    try writer.writeString("static_io");
    try writer.writeString("baseline.zon");
    try writer.writeString("x86_64");
    try writer.writeString("windows");
    try writer.writeString("gnu");
    try writer.writeOptionalString("legacy-host");
    try writer.writeInt(u32, 1);
    try writer.writeString("legacy_case");
    try writer.writeInt(u32, 4);
    try writer.writeInt(u64, 10);
    try writer.writeInt(u64, 14);
    try writer.writeInt(u64, 12);
    try writer.writeInt(u64, 12);
    try writer.writeInt(u64, 14);
    try writer.writeInt(u64, 14);

    var decoded_cases: [1]stats.BenchmarkStats = undefined;
    var string_buffer: [256]u8 = undefined;
    var tag_storage: [4][]const u8 = undefined;
    const decoded = try decodeRecordBinary(writer.finish(), &decoded_cases, &string_buffer, &tag_storage);
    try std.testing.expectEqual(@as(u64, 99), decoded.timestamp_unix_ms);
    try std.testing.expectEqualStrings("legacy-host", decoded.environment.host_label.?);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.environment.environment_note);
    try std.testing.expectEqual(@as(?u64, null), decoded.cases[0].p99_elapsed_ns);
    try std.testing.expectEqual(@as(usize, 0), decoded.environment.tags.len);
}

test "decodeRecordBinary reads legacy v2 records without tags" {
    var record_buffer: [2048]u8 = undefined;
    var writer = BufferWriter.init(&record_buffer);
    try writer.writeInt(u16, 2);
    try writer.writeByte(@intFromEnum(HistoryAction.recorded));
    try writer.writeByte(encodeOptionalBool(null));
    try writer.writeInt(u64, 101);
    try writer.writeByte(@intFromEnum(identity.BuildMode.release_fast));
    try writer.writeByte(@intFromEnum(config.BenchmarkMode.full));
    try writer.writeString("static_io");
    try writer.writeString("baseline.zon");
    try writer.writeString("x86_64");
    try writer.writeString("windows");
    try writer.writeString("gnu");
    try writer.writeOptionalString("legacy-host");
    try writer.writeOptionalString("legacy-note");
    try writer.writeInt(u32, 1);
    try writer.writeString("legacy_case");
    try writer.writeInt(u32, 4);
    try writer.writeInt(u64, 10);
    try writer.writeInt(u64, 14);
    try writer.writeInt(u64, 12);
    try writer.writeInt(u64, 12);
    try writer.writeInt(u64, 14);
    try writer.writeInt(u64, 14);

    var decoded_cases: [1]stats.BenchmarkStats = undefined;
    var string_buffer: [256]u8 = undefined;
    var tag_storage: [4][]const u8 = undefined;
    const decoded = try decodeRecordBinary(writer.finish(), &decoded_cases, &string_buffer, &tag_storage);
    try std.testing.expectEqual(@as(u64, 101), decoded.timestamp_unix_ms);
    try std.testing.expectEqualStrings("legacy-host", decoded.environment.host_label.?);
    try std.testing.expectEqualStrings("legacy-note", decoded.environment.environment_note.?);
    try std.testing.expectEqual(@as(?u64, null), decoded.cases[0].p99_elapsed_ns);
    try std.testing.expectEqual(@as(usize, 0), decoded.environment.tags.len);
}

test "appendRecordFile bounds retained history and compatibility filtering works" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const case_stats = [_]stats.BenchmarkStats{
        .{
            .case_name = "case_a",
            .sample_count = 3,
            .min_elapsed_ns = 10,
            .max_elapsed_ns = 10,
            .mean_elapsed_ns = 10,
            .median_elapsed_ns = 10,
            .p90_elapsed_ns = 10,
            .p95_elapsed_ns = 10,
            .p99_elapsed_ns = 10,
        },
    };
    const tags_a = [_][]const u8{ "stable", "cpu-a" };
    const tags_b = [_][]const u8{ "stable", "cpu-b" };

    var append_existing: [4096]u8 = undefined;
    var append_record: [2048]u8 = undefined;
    var append_frame: [2048]u8 = undefined;
    var append_output: [4096]u8 = undefined;
    const append_buffers: HistoryAppendBuffers = .{
        .existing_file_buffer = &append_existing,
        .record_buffer = &append_record,
        .frame_buffer = &append_frame,
        .output_file_buffer = &append_output,
    };

    _ = try appendRecordFile(io, tmp_dir.dir, "history.binlog", append_buffers, 2, .{
        .version = history_version,
        .timestamp_unix_ms = 1,
        .action = .recorded,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.zon",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-a",
            .environment_note = "rack-1",
            .tags = &tags_a,
        },
        .cases = &case_stats,
    });
    _ = try appendRecordFile(io, tmp_dir.dir, "history.binlog", append_buffers, 2, .{
        .version = history_version,
        .timestamp_unix_ms = 2,
        .action = .compared,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.zon",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-a",
            .environment_note = "rack-2",
            .tags = &tags_b,
        },
        .cases = &case_stats,
    });
    _ = try appendRecordFile(io, tmp_dir.dir, "history.binlog", append_buffers, 2, .{
        .version = history_version,
        .timestamp_unix_ms = 3,
        .action = .compared,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.zon",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-a",
            .environment_note = "rack-3",
            .tags = &tags_a,
        },
        .cases = &case_stats,
    });
    _ = try appendRecordFile(io, tmp_dir.dir, "history.binlog", append_buffers, 2, .{
        .version = history_version,
        .timestamp_unix_ms = 4,
        .action = .compared,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.zon",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-a",
            .environment_note = "rack-4",
            .tags = &tags_b,
        },
        .cases = &case_stats,
    });

    var read_file: [4096]u8 = undefined;
    var read_cases: [2]stats.BenchmarkStats = undefined;
    var read_strings: [256]u8 = undefined;
    var read_tags: [4][]const u8 = undefined;
    const latest = (try readMostRecentCompatibleRecord(
        io,
        tmp_dir.dir,
        "history.binlog",
        .{
            .package_name = "static_sync",
            .baseline_path = "baseline.zon",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-a",
            .environment_note = "rack-3",
            .tags = &tags_a,
        },
        .{
            .file_buffer = &read_file,
            .case_storage = &read_cases,
            .string_buffer = &read_strings,
            .tag_storage = &read_tags,
        },
    )).?;

    try std.testing.expectEqual(@as(u64, 3), latest.timestamp_unix_ms);
    try std.testing.expectEqual(@as(usize, 2), latest.environment.tags.len);
    try std.testing.expectEqualStrings("stable", latest.environment.tags[0]);
    try std.testing.expectEqualStrings("cpu-a", latest.environment.tags[1]);

    const stored = try artifact.record_log.readLogFile(io, tmp_dir.dir, "history.binlog", &read_file);
    var iter = try artifact.record_log.iterateRecords(stored);
    var count: usize = 0;
    while (try iter.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}
