//! Bounded benchmark history records with environment metadata.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const baseline = @import("baseline.zig");
const stats = @import("stats.zig");
const identity = @import("../testing/identity.zig");

pub const history_version: u16 = 1;

pub const BenchmarkHistoryError = baseline.BenchmarkBaselineError;

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
};

pub const HistoryReadBuffers = struct {
    file_buffer: []u8,
    case_storage: []stats.BenchmarkStats,
    string_buffer: []u8,
};

pub const HistoryAppendBuffers = struct {
    existing_file_buffer: []u8,
    record_json_buffer: []u8,
    output_file_buffer: []u8,
};

comptime {
    std.debug.assert(history_version == 1);
    std.debug.assert(std.meta.fields(HistoryAction).len == 3);
}

pub fn captureEnvironmentMetadata(options: CaptureEnvironmentOptions) EnvironmentMetadataView {
    std.debug.assert(options.package_name.len > 0);
    std.debug.assert(options.baseline_path.len > 0);

    return .{
        .package_name = options.package_name,
        .baseline_path = options.baseline_path,
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .target_abi = @tagName(builtin.target.abi),
        .build_mode = identity.BuildMode.fromOptimizeMode(builtin.mode),
        .benchmark_mode = options.benchmark_mode,
        .host_label = options.host_label,
    };
}

pub fn encodeRecordJson(
    buffer: []u8,
    record: HistoryRecordView,
) BenchmarkHistoryError![]const u8 {
    try validateRecord(record);

    var writer = BufferWriter.init(buffer);
    try writer.writeAll("{\"version\":");
    try writer.print("{}", .{record.version});
    try writer.writeAll(",\"timestamp_unix_ms\":");
    try writer.print("{}", .{record.timestamp_unix_ms});
    try writer.writeAll(",\"action\":");
    try writer.writeJsonString(@tagName(record.action));
    try writer.writeAll(",\"comparison_passed\":");
    if (record.comparison_passed) |comparison_passed| {
        try writer.writeAll(if (comparison_passed) "true" else "false");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"package_name\":");
    try writer.writeJsonString(record.environment.package_name);
    try writer.writeAll(",\"baseline_path\":");
    try writer.writeJsonString(record.environment.baseline_path);
    try writer.writeAll(",\"target_arch\":");
    try writer.writeJsonString(record.environment.target_arch);
    try writer.writeAll(",\"target_os\":");
    try writer.writeJsonString(record.environment.target_os);
    try writer.writeAll(",\"target_abi\":");
    try writer.writeJsonString(record.environment.target_abi);
    try writer.writeAll(",\"build_mode\":");
    try writer.writeJsonString(@tagName(record.environment.build_mode));
    try writer.writeAll(",\"benchmark_mode\":");
    try writer.writeJsonString(@tagName(record.environment.benchmark_mode));
    try writer.writeAll(",\"host_label\":");
    if (record.environment.host_label) |host_label| {
        try writer.writeJsonString(host_label);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"cases\":[");
    for (record.cases, 0..) |case_stats, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try writer.writeJsonString(case_stats.case_name);
        try writer.writeAll(",\"sample_count\":");
        try writer.print("{}", .{case_stats.sample_count});
        try writer.writeAll(",\"min_elapsed_ns\":");
        try writer.print("{}", .{case_stats.min_elapsed_ns});
        try writer.writeAll(",\"max_elapsed_ns\":");
        try writer.print("{}", .{case_stats.max_elapsed_ns});
        try writer.writeAll(",\"mean_elapsed_ns\":");
        try writer.print("{}", .{case_stats.mean_elapsed_ns});
        try writer.writeAll(",\"median_elapsed_ns\":");
        try writer.print("{}", .{case_stats.median_elapsed_ns});
        try writer.writeAll(",\"p90_elapsed_ns\":");
        try writer.print("{}", .{case_stats.p90_elapsed_ns});
        try writer.writeAll(",\"p95_elapsed_ns\":");
        try writer.print("{}", .{case_stats.p95_elapsed_ns});
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
    return writer.finish();
}

pub fn decodeRecordJson(
    json_bytes: []const u8,
    case_storage: []stats.BenchmarkStats,
    string_buffer: []u8,
) BenchmarkHistoryError!HistoryRecordView {
    var cursor = JsonCursor.init(json_bytes, string_buffer);

    try cursor.expectByte('{');
    try cursor.expectKey("version");
    const version = try cursor.parseU16();
    if (version != history_version) return error.Unsupported;
    try cursor.expectByte(',');
    try cursor.expectKey("timestamp_unix_ms");
    const timestamp_unix_ms = try cursor.parseU64();
    try cursor.expectByte(',');
    try cursor.expectKey("action");
    const action = try parseAction(try cursor.parseSmallString());
    try cursor.expectByte(',');
    try cursor.expectKey("comparison_passed");
    const comparison_passed = if (try cursor.consumeNull())
        null
    else
        try cursor.parseBool();
    try cursor.expectByte(',');
    try cursor.expectKey("package_name");
    const package_name = try cursor.parseStringIntoStorage();
    try cursor.expectByte(',');
    try cursor.expectKey("baseline_path");
    const baseline_path = try cursor.parseStringIntoStorage();
    try cursor.expectByte(',');
    try cursor.expectKey("target_arch");
    const target_arch = try cursor.parseStringIntoStorage();
    try cursor.expectByte(',');
    try cursor.expectKey("target_os");
    const target_os = try cursor.parseStringIntoStorage();
    try cursor.expectByte(',');
    try cursor.expectKey("target_abi");
    const target_abi = try cursor.parseStringIntoStorage();
    try cursor.expectByte(',');
    try cursor.expectKey("build_mode");
    const build_mode = try parseBuildMode(try cursor.parseSmallString());
    try cursor.expectByte(',');
    try cursor.expectKey("benchmark_mode");
    const benchmark_mode = try parseMode(try cursor.parseSmallString());
    try cursor.expectByte(',');
    try cursor.expectKey("host_label");
    const host_label = if (try cursor.consumeNull())
        null
    else
        try cursor.parseStringIntoStorage();
    try cursor.expectByte(',');
    try cursor.expectKey("cases");
    try cursor.expectByte('[');

    var case_index: usize = 0;
    if (!try cursor.consumeByteIf(']')) {
        while (true) {
            if (case_index >= case_storage.len) return error.NoSpaceLeft;
            try cursor.expectByte('{');
            try cursor.expectKey("name");
            const name = try cursor.parseStringIntoStorage();
            try cursor.expectByte(',');
            try cursor.expectKey("sample_count");
            const sample_count = try cursor.parseU32();
            try cursor.expectByte(',');
            try cursor.expectKey("min_elapsed_ns");
            const min_elapsed_ns = try cursor.parseU64();
            try cursor.expectByte(',');
            try cursor.expectKey("max_elapsed_ns");
            const max_elapsed_ns = try cursor.parseU64();
            try cursor.expectByte(',');
            try cursor.expectKey("mean_elapsed_ns");
            const mean_elapsed_ns = try cursor.parseU64();
            try cursor.expectByte(',');
            try cursor.expectKey("median_elapsed_ns");
            const median_elapsed_ns = try cursor.parseU64();
            try cursor.expectByte(',');
            try cursor.expectKey("p90_elapsed_ns");
            const p90_elapsed_ns = try cursor.parseU64();
            try cursor.expectByte(',');
            try cursor.expectKey("p95_elapsed_ns");
            const p95_elapsed_ns = try cursor.parseU64();
            try cursor.expectByte('}');

            case_storage[case_index] = .{
                .case_name = name,
                .sample_count = sample_count,
                .min_elapsed_ns = min_elapsed_ns,
                .max_elapsed_ns = max_elapsed_ns,
                .mean_elapsed_ns = mean_elapsed_ns,
                .median_elapsed_ns = median_elapsed_ns,
                .p90_elapsed_ns = p90_elapsed_ns,
                .p95_elapsed_ns = p95_elapsed_ns,
            };
            try validateStats(case_storage[case_index]);
            case_index += 1;

            if (try cursor.consumeByteIf(']')) break;
            try cursor.expectByte(',');
        }
    }

    try cursor.expectByte('}');
    try cursor.finish();

    const record: HistoryRecordView = .{
        .version = version,
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
        },
        .cases = case_storage[0..case_index],
    };
    try validateRecord(record);
    return record;
}

pub fn readMostRecentCompatibleRecord(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    environment: EnvironmentMetadataView,
    read_buffers: HistoryReadBuffers,
) BenchmarkHistoryError!?HistoryRecordView {
    const bytes = try dir.readFile(io, sub_path, read_buffers.file_buffer);
    var end = trimTrailingNewlines(bytes);
    while (end > 0) {
        const maybe_start = std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n');
        const start = if (maybe_start) |index| index + 1 else 0;
        const line = std.mem.trim(u8, bytes[start..end], " \r\t");
        if (line.len != 0) {
            const record = try decodeRecordJson(line, read_buffers.case_storage, read_buffers.string_buffer);
            if (isCompatibleRecord(record, environment)) return record;
        }
        if (maybe_start == null) break;
        end = maybe_start.?;
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
    if (max_records == 0) return error.InvalidInput;

    const encoded_record = try encodeRecordJson(append_buffers.record_json_buffer, record);
    const existing_bytes = dir.readFile(io, sub_path, append_buffers.existing_file_buffer) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };

    const keep_start = retainedStartOffset(existing_bytes, max_records);
    var writer = BufferWriter.init(append_buffers.output_file_buffer);
    const retained = std.mem.trim(u8, existing_bytes[keep_start..], "\r\n");
    if (retained.len != 0) {
        try writer.writeAll(retained);
        try writer.writeByte('\n');
    }
    try writer.writeAll(encoded_record);
    try writer.writeByte('\n');

    const out = writer.finish();
    try dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = out,
        .flags = .{},
    });
    return out;
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
        equalOptionalText(record.environment.host_label, environment.host_label);
}

fn equalOptionalText(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |a_text| {
        if (b) |b_text| return std.mem.eql(u8, a_text, b_text);
        return false;
    }
    return b == null;
}

fn retainedStartOffset(existing_bytes: []const u8, max_records: usize) usize {
    if (existing_bytes.len == 0) return 0;
    if (max_records <= 1) return trimTrailingNewlines(existing_bytes);

    const keep_existing = max_records - 1;
    var cursor = trimTrailingNewlines(existing_bytes);
    var kept_lines: usize = 0;
    while (cursor > 0) {
        const maybe_prev_newline = std.mem.lastIndexOfScalar(u8, existing_bytes[0..cursor], '\n');
        kept_lines += 1;
        if (kept_lines == keep_existing) {
            return if (maybe_prev_newline) |index| index + 1 else 0;
        }
        if (maybe_prev_newline) |index| {
            cursor = index;
        } else {
            break;
        }
    }
    return 0;
}

fn trimTrailingNewlines(bytes: []const u8) usize {
    var end = bytes.len;
    while (end > 0) {
        const byte = bytes[end - 1];
        if (byte != '\n' and byte != '\r') break;
        end -= 1;
    }
    return end;
}

fn validateRecord(record: HistoryRecordView) BenchmarkHistoryError!void {
    if (record.version != history_version) return error.InvalidInput;
    if (record.environment.package_name.len == 0) return error.InvalidInput;
    if (record.environment.baseline_path.len == 0) return error.InvalidInput;
    if (record.environment.target_arch.len == 0) return error.InvalidInput;
    if (record.environment.target_os.len == 0) return error.InvalidInput;
    if (record.environment.target_abi.len == 0) return error.InvalidInput;
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
    if (case_stats.median_elapsed_ns > case_stats.p90_elapsed_ns) return error.InvalidInput;
    if (case_stats.p90_elapsed_ns > case_stats.p95_elapsed_ns) return error.InvalidInput;
}

fn parseAction(text: []const u8) BenchmarkHistoryError!HistoryAction {
    if (std.mem.eql(u8, text, "report_only")) return .report_only;
    if (std.mem.eql(u8, text, "recorded")) return .recorded;
    if (std.mem.eql(u8, text, "compared")) return .compared;
    return error.CorruptData;
}

fn parseBuildMode(text: []const u8) BenchmarkHistoryError!identity.BuildMode {
    if (std.mem.eql(u8, text, "debug")) return .debug;
    if (std.mem.eql(u8, text, "release_safe")) return .release_safe;
    if (std.mem.eql(u8, text, "release_fast")) return .release_fast;
    if (std.mem.eql(u8, text, "release_small")) return .release_small;
    return error.CorruptData;
}

fn parseMode(text: []const u8) BenchmarkHistoryError!config.BenchmarkMode {
    if (std.mem.eql(u8, text, "smoke")) return .smoke;
    if (std.mem.eql(u8, text, "full")) return .full;
    return error.CorruptData;
}

const JsonCursor = struct {
    bytes: []const u8,
    index: usize = 0,
    string_buffer: []u8,
    string_buffer_len: usize = 0,

    fn init(bytes: []const u8, string_buffer: []u8) JsonCursor {
        return .{
            .bytes = bytes,
            .string_buffer = string_buffer,
        };
    }

    fn finish(self: *JsonCursor) BenchmarkHistoryError!void {
        self.skipWhitespace();
        if (self.index != self.bytes.len) return error.CorruptData;
    }

    fn expectByte(self: *JsonCursor, expected: u8) BenchmarkHistoryError!void {
        self.skipWhitespace();
        if (self.index >= self.bytes.len or self.bytes[self.index] != expected) return error.CorruptData;
        self.index += 1;
    }

    fn consumeByteIf(self: *JsonCursor, expected: u8) BenchmarkHistoryError!bool {
        self.skipWhitespace();
        if (self.index >= self.bytes.len or self.bytes[self.index] != expected) return false;
        self.index += 1;
        return true;
    }

    fn expectKey(self: *JsonCursor, key: []const u8) BenchmarkHistoryError!void {
        const parsed = try self.parseSmallString();
        if (!std.mem.eql(u8, parsed, key)) return error.CorruptData;
        try self.expectByte(':');
    }

    fn parseSmallString(self: *JsonCursor) BenchmarkHistoryError![]const u8 {
        self.skipWhitespace();
        if (self.index >= self.bytes.len or self.bytes[self.index] != '"') return error.CorruptData;
        self.index += 1;
        const start = self.index;
        while (self.index < self.bytes.len and self.bytes[self.index] != '"') : (self.index += 1) {
            if (self.bytes[self.index] == '\\') return error.CorruptData;
        }
        if (self.index >= self.bytes.len) return error.CorruptData;
        const text = self.bytes[start..self.index];
        self.index += 1;
        return text;
    }

    fn parseStringIntoStorage(self: *JsonCursor) BenchmarkHistoryError![]const u8 {
        self.skipWhitespace();
        if (self.index >= self.bytes.len or self.bytes[self.index] != '"') return error.CorruptData;
        self.index += 1;
        const start = self.string_buffer_len;
        while (self.index < self.bytes.len) {
            const byte = self.bytes[self.index];
            self.index += 1;
            switch (byte) {
                '"' => return self.string_buffer[start..self.string_buffer_len],
                '\\' => {
                    if (self.index >= self.bytes.len) return error.CorruptData;
                    const escaped = self.bytes[self.index];
                    self.index += 1;
                    const decoded = switch (escaped) {
                        '"', '\\', '/' => escaped,
                        'b' => 0x08,
                        'f' => 0x0c,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => return error.CorruptData,
                    };
                    try self.appendStringByte(decoded);
                },
                else => try self.appendStringByte(byte),
            }
        }
        return error.CorruptData;
    }

    fn parseU16(self: *JsonCursor) BenchmarkHistoryError!u16 {
        return self.parseUnsigned(u16);
    }

    fn parseU32(self: *JsonCursor) BenchmarkHistoryError!u32 {
        return self.parseUnsigned(u32);
    }

    fn parseU64(self: *JsonCursor) BenchmarkHistoryError!u64 {
        return self.parseUnsigned(u64);
    }

    fn parseUnsigned(self: *JsonCursor, comptime T: type) BenchmarkHistoryError!T {
        self.skipWhitespace();
        if (self.index >= self.bytes.len) return error.CorruptData;
        var value: u128 = 0;
        var digits: usize = 0;
        while (self.index < self.bytes.len) : (self.index += 1) {
            const byte = self.bytes[self.index];
            if (byte < '0' or byte > '9') break;
            value = std.math.mul(u128, value, 10) catch return error.Overflow;
            value = std.math.add(u128, value, byte - '0') catch return error.Overflow;
            digits += 1;
        }
        if (digits == 0) return error.CorruptData;
        if (value > std.math.maxInt(T)) return error.Overflow;
        return @intCast(value);
    }

    fn parseBool(self: *JsonCursor) BenchmarkHistoryError!bool {
        self.skipWhitespace();
        if (std.mem.startsWith(u8, self.bytes[self.index..], "true")) {
            self.index += 4;
            return true;
        }
        if (std.mem.startsWith(u8, self.bytes[self.index..], "false")) {
            self.index += 5;
            return false;
        }
        return error.CorruptData;
    }

    fn consumeNull(self: *JsonCursor) BenchmarkHistoryError!bool {
        self.skipWhitespace();
        if (!std.mem.startsWith(u8, self.bytes[self.index..], "null")) return false;
        self.index += 4;
        return true;
    }

    fn appendStringByte(self: *JsonCursor, byte: u8) BenchmarkHistoryError!void {
        if (self.string_buffer_len >= self.string_buffer.len) return error.NoSpaceLeft;
        self.string_buffer[self.string_buffer_len] = byte;
        self.string_buffer_len += 1;
    }

    fn skipWhitespace(self: *JsonCursor) void {
        while (self.index < self.bytes.len) : (self.index += 1) {
            const byte = self.bytes[self.index];
            if (byte != ' ' and byte != '\n' and byte != '\r' and byte != '\t') break;
        }
    }
};

const BufferWriter = struct {
    buffer: []u8,
    position: usize = 0,

    fn init(buffer: []u8) BufferWriter {
        return .{ .buffer = buffer };
    }

    fn writeAll(self: *BufferWriter, text: []const u8) BenchmarkHistoryError!void {
        if (self.position + text.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.position .. self.position + text.len], text);
        self.position += text.len;
    }

    fn writeByte(self: *BufferWriter, byte: u8) BenchmarkHistoryError!void {
        if (self.position >= self.buffer.len) return error.NoSpaceLeft;
        self.buffer[self.position] = byte;
        self.position += 1;
    }

    fn print(self: *BufferWriter, comptime format: []const u8, args: anytype) BenchmarkHistoryError!void {
        const written = std.fmt.bufPrint(self.buffer[self.position..], format, args) catch {
            return error.NoSpaceLeft;
        };
        self.position += written.len;
    }

    fn writeJsonString(self: *BufferWriter, text: []const u8) BenchmarkHistoryError!void {
        try self.writeByte('"');
        for (text) |byte| {
            switch (byte) {
                '"' => try self.writeAll("\\\""),
                '\\' => try self.writeAll("\\\\"),
                '\n' => try self.writeAll("\\n"),
                '\r' => try self.writeAll("\\r"),
                '\t' => try self.writeAll("\\t"),
                else => {
                    if (byte < 0x20) return error.InvalidInput;
                    try self.writeByte(byte);
                },
            }
        }
        try self.writeByte('"');
    }

    fn finish(self: *const BufferWriter) []const u8 {
        return self.buffer[0..self.position];
    }
};

test "history record json round-trips with environment metadata" {
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
        },
    };
    var json_buffer: [2048]u8 = undefined;
    const encoded = try encodeRecordJson(&json_buffer, .{
        .version = history_version,
        .timestamp_unix_ms = 1234,
        .action = .compared,
        .comparison_passed = true,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.json",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "devbox",
        },
        .cases = &case_stats,
    });

    var decoded_cases: [2]stats.BenchmarkStats = undefined;
    var string_buffer: [256]u8 = undefined;
    const decoded = try decodeRecordJson(encoded, &decoded_cases, &string_buffer);
    try std.testing.expectEqual(HistoryAction.compared, decoded.action);
    try std.testing.expectEqual(@as(u64, 1234), decoded.timestamp_unix_ms);
    try std.testing.expect(decoded.comparison_passed.?);
    try std.testing.expectEqualStrings("static_sync", decoded.environment.package_name);
    try std.testing.expectEqualStrings("devbox", decoded.environment.host_label.?);
    try std.testing.expectEqualStrings("event_try_wait_signaled", decoded.cases[0].case_name);
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
        },
    };

    var append_existing: [4096]u8 = undefined;
    var append_record: [2048]u8 = undefined;
    var append_output: [4096]u8 = undefined;
    const append_buffers: HistoryAppendBuffers = .{
        .existing_file_buffer = &append_existing,
        .record_json_buffer = &append_record,
        .output_file_buffer = &append_output,
    };

    _ = try appendRecordFile(io, tmp_dir.dir, "history.jsonl", append_buffers, 2, .{
        .version = history_version,
        .timestamp_unix_ms = 1,
        .action = .recorded,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.json",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-a",
        },
        .cases = &case_stats,
    });
    _ = try appendRecordFile(io, tmp_dir.dir, "history.jsonl", append_buffers, 2, .{
        .version = history_version,
        .timestamp_unix_ms = 2,
        .action = .compared,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.json",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-b",
        },
        .cases = &case_stats,
    });
    _ = try appendRecordFile(io, tmp_dir.dir, "history.jsonl", append_buffers, 2, .{
        .version = history_version,
        .timestamp_unix_ms = 3,
        .action = .compared,
        .environment = .{
            .package_name = "static_sync",
            .baseline_path = "baseline.json",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-a",
        },
        .cases = &case_stats,
    });

    var read_file: [4096]u8 = undefined;
    var read_cases: [2]stats.BenchmarkStats = undefined;
    var read_strings: [256]u8 = undefined;
    const latest = (try readMostRecentCompatibleRecord(
        io,
        tmp_dir.dir,
        "history.jsonl",
        .{
            .package_name = "static_sync",
            .baseline_path = "baseline.json",
            .target_arch = "x86_64",
            .target_os = "windows",
            .target_abi = "msvc",
            .build_mode = .release_fast,
            .benchmark_mode = .full,
            .host_label = "host-a",
        },
        .{
            .file_buffer = &read_file,
            .case_storage = &read_cases,
            .string_buffer = &read_strings,
        },
    )).?;

    try std.testing.expectEqual(@as(u64, 3), latest.timestamp_unix_ms);

    const stored = try tmp_dir.dir.readFile(io, "history.jsonl", &read_file);
    var line_count: usize = 0;
    var tokenizer = std.mem.tokenizeScalar(u8, stored, '\n');
    while (tokenizer.next()) |_| line_count += 1;
    try std.testing.expectEqual(@as(usize, 2), line_count);
}
