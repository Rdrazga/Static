//! Shared append-only binary record-log helpers.

const std = @import("std");

pub const record_log_version: u16 = 1;

const file_magic = [8]u8{ 's', 't', 'r', 'l', 'o', 'g', 1, 0 };
const header_len = file_magic.len + @sizeOf(u16);

pub const ArtifactRecordLogError = error{
    InvalidInput,
    NoSpaceLeft,
    CorruptData,
    Unsupported,
    Overflow,
} || std.Io.Dir.WriteFileError || std.Io.Dir.ReadFileError || std.Io.Dir.OpenError;

pub const AppendBuffers = struct {
    existing_file_buffer: []u8,
    frame_buffer: []u8,
    output_file_buffer: []u8,
};

pub const FileBuilder = struct {
    writer: BufferWriter,

    pub fn init(buffer: []u8) ArtifactRecordLogError!FileBuilder {
        var writer = BufferWriter.init(buffer);
        try writeHeader(&writer);
        return .{ .writer = writer };
    }

    pub fn append(self: *FileBuilder, payload: []const u8) ArtifactRecordLogError!void {
        try self.writer.writeInt(u32, std.math.cast(u32, payload.len) orelse return error.Overflow);
        try self.writer.writeAll(payload);
    }

    pub fn finish(self: *const FileBuilder) []const u8 {
        return self.writer.finish();
    }
};

pub const Iterator = struct {
    data: []const u8,
    index: usize = 0,

    pub fn next(self: *Iterator) ArtifactRecordLogError!?[]const u8 {
        if (self.index == self.data.len) return null;
        if (self.data.len - self.index < @sizeOf(u32)) return error.CorruptData;

        const len = std.mem.readInt(u32, self.data[self.index..][0..@sizeOf(u32)], .little);
        self.index += @sizeOf(u32);

        const payload_len: usize = len;
        if (self.data.len - self.index < payload_len) return error.CorruptData;
        const payload = self.data[self.index .. self.index + payload_len];
        self.index += payload_len;
        return payload;
    }
};

pub fn readLogFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    file_buffer: []u8,
) ArtifactRecordLogError![]const u8 {
    const bytes = try dir.readFile(io, sub_path, file_buffer);
    _ = try validateHeader(bytes);
    return bytes;
}

pub fn iterateRecords(file_bytes: []const u8) ArtifactRecordLogError!Iterator {
    const data = try validateHeader(file_bytes);
    return .{ .data = data };
}

pub fn appendRecordFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: AppendBuffers,
    max_records: usize,
    payload: []const u8,
) ArtifactRecordLogError![]const u8 {
    if (max_records == 0) return error.InvalidInput;

    const existing_bytes = dir.readFile(io, sub_path, buffers.existing_file_buffer) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };

    const existing_data = if (existing_bytes.len == 0)
        ""
    else
        try validateHeader(existing_bytes);

    const frame = try encodeFrame(buffers.frame_buffer, payload);

    var writer = BufferWriter.init(buffers.output_file_buffer);
    try writeHeader(&writer);

    if (existing_data.len != 0 and max_records > 1) {
        const retained_start = try retainedStartOffset(existing_data, max_records - 1);
        if (retained_start < existing_data.len) {
            try writer.writeAll(existing_data[retained_start..]);
        }
    }

    try writer.writeAll(frame);
    const out = writer.finish();
    try dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = out,
        .flags = .{},
    });
    return out;
}

fn encodeFrame(
    buffer: []u8,
    payload: []const u8,
) ArtifactRecordLogError![]const u8 {
    var writer = BufferWriter.init(buffer);
    try writer.writeInt(u32, std.math.cast(u32, payload.len) orelse return error.Overflow);
    try writer.writeAll(payload);
    return writer.finish();
}

fn writeHeader(writer: *BufferWriter) ArtifactRecordLogError!void {
    try writer.writeAll(&file_magic);
    try writer.writeInt(u16, record_log_version);
}

fn validateHeader(file_bytes: []const u8) ArtifactRecordLogError![]const u8 {
    if (file_bytes.len < header_len) return error.CorruptData;
    if (!std.mem.eql(u8, file_bytes[0..file_magic.len], &file_magic)) return error.CorruptData;
    const version = std.mem.readInt(u16, file_bytes[file_magic.len..][0..@sizeOf(u16)], .little);
    if (version != record_log_version) return error.Unsupported;
    return file_bytes[header_len..];
}

fn retainedStartOffset(data: []const u8, keep_count: usize) ArtifactRecordLogError!usize {
    if (keep_count == 0 or data.len == 0) return data.len;

    const total = try countRecords(data);
    if (total <= keep_count) return 0;

    const skip_count = total - keep_count;
    var skipped: usize = 0;
    var index: usize = 0;
    while (skipped < skip_count) : (skipped += 1) {
        if (data.len - index < @sizeOf(u32)) return error.CorruptData;
        const len = std.mem.readInt(u32, data[index..][0..@sizeOf(u32)], .little);
        index += @sizeOf(u32);
        const payload_len: usize = len;
        if (data.len - index < payload_len) return error.CorruptData;
        index += payload_len;
    }
    return index;
}

fn countRecords(data: []const u8) ArtifactRecordLogError!usize {
    var count: usize = 0;
    var iter = Iterator{ .data = data };
    while (try iter.next()) |_| count += 1;
    return count;
}

const BufferWriter = struct {
    buffer: []u8,
    position: usize = 0,

    fn init(buffer: []u8) BufferWriter {
        return .{ .buffer = buffer };
    }

    fn writeAll(self: *BufferWriter, bytes: []const u8) ArtifactRecordLogError!void {
        if (self.buffer.len - self.position < bytes.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.position .. self.position + bytes.len], bytes);
        self.position += bytes.len;
    }

    fn writeInt(self: *BufferWriter, comptime T: type, value: T) ArtifactRecordLogError!void {
        if (self.buffer.len - self.position < @sizeOf(T)) return error.NoSpaceLeft;
        std.mem.writeInt(T, self.buffer[self.position..][0..@sizeOf(T)], value, .little);
        self.position += @sizeOf(T);
    }

    fn finish(self: *const BufferWriter) []const u8 {
        return self.buffer[0..self.position];
    }
};

test "record log appends and retains bounded records" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var existing: [256]u8 = undefined;
    var frame: [64]u8 = undefined;
    var output: [256]u8 = undefined;
    const buffers: AppendBuffers = .{
        .existing_file_buffer = &existing,
        .frame_buffer = &frame,
        .output_file_buffer = &output,
    };

    _ = try appendRecordFile(io, tmp_dir.dir, "history.binlog", buffers, 2, "one");
    _ = try appendRecordFile(io, tmp_dir.dir, "history.binlog", buffers, 2, "two");
    _ = try appendRecordFile(io, tmp_dir.dir, "history.binlog", buffers, 2, "three");

    var read_buffer: [256]u8 = undefined;
    const file_bytes = try readLogFile(io, tmp_dir.dir, "history.binlog", &read_buffer);
    var iter = try iterateRecords(file_bytes);

    const first = (try iter.next()).?;
    const second = (try iter.next()).?;
    try std.testing.expectEqualStrings("two", first);
    try std.testing.expectEqualStrings("three", second);
    try std.testing.expect((try iter.next()) == null);
}

test "record log rejects unsupported header version" {
    var builder_buffer: [64]u8 = undefined;
    var builder = try FileBuilder.init(&builder_buffer);
    try builder.append("one");

    var invalid_file: [64]u8 = undefined;
    const valid_file = builder.finish();
    @memcpy(invalid_file[0..valid_file.len], valid_file);
    std.mem.writeInt(u16, invalid_file[file_magic.len..][0..@sizeOf(u16)], record_log_version + 1, .little);

    try std.testing.expectError(error.Unsupported, iterateRecords(invalid_file[0..valid_file.len]));
}
