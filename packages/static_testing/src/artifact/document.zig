//! Shared bounded-document helpers for typed `ZON` artifacts.

const std = @import("std");
const testing = std.testing;

pub const ArtifactDocumentError = error{
    InvalidInput,
    NoSpaceLeft,
    CorruptData,
    Unsupported,
} || std.Io.Dir.WriteFileError || std.Io.Dir.ReadFileError || std.Io.Dir.OpenError;

pub const ReadBuffers = struct {
    source_buffer: []u8,
    parse_buffer: []u8,
};

pub fn encodeZon(
    buffer: []u8,
    value: anytype,
) ArtifactDocumentError![]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    var writer: std.Io.Writer.Allocating = .init(fba.allocator());
    defer writer.deinit();

    std.zon.stringify.serialize(value, .{}, &writer.writer) catch |err| switch (err) {
        error.WriteFailed => return error.NoSpaceLeft,
    };
    return writer.written();
}

pub fn decodeZon(
    comptime T: type,
    zon_bytes: []const u8,
    buffers: ReadBuffers,
) ArtifactDocumentError!T {
    comptime {
        @setEvalBranchQuota(10_000);
    }
    const source = try sourceWithSentinel(zon_bytes, buffers.source_buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffers.parse_buffer);
    return std.zon.parse.fromSliceAlloc(
        T,
        fba.allocator(),
        source,
        null,
        .{ .free_on_error = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.NoSpaceLeft,
        error.ParseZon => return error.CorruptData,
    };
}

pub fn writeZonFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffer: []u8,
    value: anytype,
) ArtifactDocumentError!usize {
    var file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);

    var file_writer = file.writer(io, buffer);
    defer file_writer.flush() catch {};

    std.zon.stringify.serialize(value, .{}, &file_writer.interface) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err orelse error.NoSpaceLeft,
    };
    try file_writer.flush();
    return @intCast(file_writer.pos);
}

pub fn readZonFile(
    comptime T: type,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffers: ReadBuffers,
) ArtifactDocumentError!T {
    if (buffers.source_buffer.len == 0) return error.InvalidInput;
    const source_limit = buffers.source_buffer.len - 1;
    const zon = try dir.readFile(io, sub_path, buffers.source_buffer[0..source_limit]);
    return decodeZon(T, zon, buffers);
}

fn sourceWithSentinel(
    source: []const u8,
    buffer: []u8,
) ArtifactDocumentError![:0]const u8 {
    if (buffer.len < source.len + 1) return error.NoSpaceLeft;
    @memmove(buffer[0..source.len], source);
    buffer[source.len] = 0;
    return buffer[0..source.len :0];
}

test "ZON document roundtrip through bounded buffers" {
    const Example = struct {
        version: u16,
        mode: enum { smoke, full },
        names: []const []const u8,
    };

    const value = Example{
        .version = 2,
        .mode = .smoke,
        .names = &.{ "one", "two" },
    };

    var write_buffer: [256]u8 = undefined;
    const encoded = try encodeZon(&write_buffer, value);

    var source_buffer: [256]u8 = undefined;
    var parse_buffer: [2048]u8 = undefined;
    const decoded = try decodeZon(Example, encoded, .{
        .source_buffer = &source_buffer,
        .parse_buffer = &parse_buffer,
    });

    try testing.expectEqual(@as(u16, 2), decoded.version);
    try testing.expectEqualStrings("one", decoded.names[0]);
    try testing.expectEqualStrings("two", decoded.names[1]);
}
