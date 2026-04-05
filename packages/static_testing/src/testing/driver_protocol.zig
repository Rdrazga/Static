//! Binary wire protocol for process-boundary deterministic test drivers.
//!
//! The protocol intentionally keeps the header layout small and fixed:
//! - one request header per inbound message;
//! - one response header per outbound message; and
//! - caller-managed payload buffers outside the header layout itself.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const serial = @import("static_serial");

/// Operating errors surfaced by driver protocol encode/decode helpers.
pub const DriverProtocolError = error{
    NoSpaceLeft,
    EndOfStream,
    InvalidInput,
    Unsupported,
    Overflow,
};

/// Four-byte wire magic for all driver protocol headers.
pub const driver_magic = [_]u8{ 'S', 'T', 'D', 'R' };

/// Supported on-wire protocol version.
pub const driver_protocol_version: u16 = 1;

/// Fixed encoded request header size.
pub const request_header_size_bytes: usize = 16;

/// Fixed encoded response header size.
pub const response_header_size_bytes: usize = 16;

/// Wire message kinds supported by phase-4 process drivers.
pub const DriverMessageKind = enum(u8) {
    ping = 1,
    echo = 2,
    shutdown = 3,
    ok = 4,
    @"error" = 5,
};

/// Versioned request header written to a child driver.
pub const DriverRequestHeader = struct {
    kind: DriverMessageKind,
    request_id: u32,
    payload_len: u32,
};

/// Versioned response header read from a child driver.
pub const DriverResponseHeader = struct {
    kind: DriverMessageKind,
    request_id: u32,
    payload_len: u32,
};

comptime {
    core.errors.assertVocabularySubset(DriverProtocolError);
    assert(driver_magic.len == 4);
    assert(driver_protocol_version != 0);
    assert(request_header_size_bytes == 16);
    assert(response_header_size_bytes == 16);
}

/// Encode a request header into a caller-owned fixed buffer.
pub fn encodeRequestHeader(
    buffer: []u8,
    header: DriverRequestHeader,
) DriverProtocolError!usize {
    if (buffer.len < request_header_size_bytes) return error.NoSpaceLeft;
    if (!isRequestKind(header.kind)) return error.InvalidInput;

    var writer = serial.writer.Writer.init(buffer[0..request_header_size_bytes]);
    try writeHeaderPrefix(&writer, header.kind);
    try writeInt(&writer, header.request_id);
    try writeInt(&writer, header.payload_len);
    assert(writer.position() == request_header_size_bytes);
    return request_header_size_bytes;
}

/// Decode a request header from a fixed-size wire buffer.
pub fn decodeRequestHeader(bytes: []const u8) DriverProtocolError!DriverRequestHeader {
    if (bytes.len < request_header_size_bytes) return error.EndOfStream;
    if (bytes.len > request_header_size_bytes) return error.InvalidInput;

    var reader = serial.reader.Reader.init(bytes);
    try validateHeaderPrefix(&reader);

    const kind = try decodeRequestKind(try readValue(&reader, u8));
    try validateReservedByte(try readValue(&reader, u8));
    const request_id = try readValue(&reader, u32);
    const payload_len = try readValue(&reader, u32);

    if (reader.remaining() != 0) return error.InvalidInput;
    return .{
        .kind = kind,
        .request_id = request_id,
        .payload_len = payload_len,
    };
}

/// Encode a response header into a caller-owned fixed buffer.
pub fn encodeResponseHeader(
    buffer: []u8,
    header: DriverResponseHeader,
) DriverProtocolError!usize {
    if (buffer.len < response_header_size_bytes) return error.NoSpaceLeft;
    if (!isResponseKind(header.kind)) return error.InvalidInput;

    var writer = serial.writer.Writer.init(buffer[0..response_header_size_bytes]);
    try writeHeaderPrefix(&writer, header.kind);
    try writeInt(&writer, header.request_id);
    try writeInt(&writer, header.payload_len);
    assert(writer.position() == response_header_size_bytes);
    return response_header_size_bytes;
}

/// Decode a response header from a fixed-size wire buffer.
pub fn decodeResponseHeader(bytes: []const u8) DriverProtocolError!DriverResponseHeader {
    if (bytes.len < response_header_size_bytes) return error.EndOfStream;
    if (bytes.len > response_header_size_bytes) return error.InvalidInput;

    var reader = serial.reader.Reader.init(bytes);
    try validateHeaderPrefix(&reader);

    const kind = try decodeResponseKind(try readValue(&reader, u8));
    try validateReservedByte(try readValue(&reader, u8));
    const request_id = try readValue(&reader, u32);
    const payload_len = try readValue(&reader, u32);

    if (reader.remaining() != 0) return error.InvalidInput;
    return .{
        .kind = kind,
        .request_id = request_id,
        .payload_len = payload_len,
    };
}

fn isRequestKind(kind: DriverMessageKind) bool {
    return switch (kind) {
        .ping, .echo, .shutdown => true,
        .ok, .@"error" => false,
    };
}

fn isResponseKind(kind: DriverMessageKind) bool {
    return switch (kind) {
        .ok, .@"error" => true,
        .ping, .echo, .shutdown => false,
    };
}

fn writeHeaderPrefix(
    writer: *serial.writer.Writer,
    kind: DriverMessageKind,
) DriverProtocolError!void {
    try writeBytes(writer, &driver_magic);
    try writeInt(writer, driver_protocol_version);
    try writeInt(writer, @intFromEnum(kind));
    try writeInt(writer, @as(u8, 0));
}

fn validateHeaderPrefix(reader: *serial.reader.Reader) DriverProtocolError!void {
    const magic = reader.readBytes(driver_magic.len) catch |err| return mapReaderError(err);
    if (!std.mem.eql(u8, magic, &driver_magic)) return error.InvalidInput;

    const version = try readValue(reader, u16);
    if (version != driver_protocol_version) return error.Unsupported;
}

fn decodeRequestKind(raw: u8) DriverProtocolError!DriverMessageKind {
    const kind = decodeKind(raw) catch return error.InvalidInput;
    if (!isRequestKind(kind)) return error.InvalidInput;
    return kind;
}

fn decodeResponseKind(raw: u8) DriverProtocolError!DriverMessageKind {
    const kind = decodeKind(raw) catch return error.InvalidInput;
    if (!isResponseKind(kind)) return error.InvalidInput;
    return kind;
}

fn decodeKind(raw: u8) error{InvalidInput}!DriverMessageKind {
    return switch (raw) {
        @intFromEnum(DriverMessageKind.ping) => .ping,
        @intFromEnum(DriverMessageKind.echo) => .echo,
        @intFromEnum(DriverMessageKind.shutdown) => .shutdown,
        @intFromEnum(DriverMessageKind.ok) => .ok,
        @intFromEnum(DriverMessageKind.@"error") => .@"error",
        else => error.InvalidInput,
    };
}

fn validateReservedByte(raw: u8) DriverProtocolError!void {
    if (raw != 0) return error.InvalidInput;
}

fn readValue(reader: *serial.reader.Reader, comptime T: type) DriverProtocolError!T {
    return reader.readInt(T, .little) catch |err| mapReaderError(err);
}

fn writeInt(writer: *serial.writer.Writer, value: anytype) DriverProtocolError!void {
    writer.writeInt(value, .little) catch |err| switch (err) {
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.Overflow => return error.Overflow,
        error.InvalidInput => return error.InvalidInput,
        error.Underflow => return error.InvalidInput,
    };
}

fn writeBytes(writer: *serial.writer.Writer, bytes: []const u8) DriverProtocolError!void {
    writer.writeBytes(bytes) catch |err| switch (err) {
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.InvalidInput => return error.InvalidInput,
        error.Overflow => return error.Overflow,
        error.Underflow => return error.InvalidInput,
    };
}

fn mapReaderError(err: serial.reader.Error) DriverProtocolError {
    return switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.InvalidInput => error.InvalidInput,
        error.Overflow => error.Overflow,
        error.CorruptData => error.InvalidInput,
        error.Underflow => error.InvalidInput,
    };
}

test "request and response headers round-trip" {
    var request_bytes: [request_header_size_bytes]u8 = undefined;
    const request_written = try encodeRequestHeader(&request_bytes, .{
        .kind = .echo,
        .request_id = 9,
        .payload_len = 4,
    });
    const request_header = try decodeRequestHeader(request_bytes[0..request_written]);

    var response_bytes: [response_header_size_bytes]u8 = undefined;
    const response_written = try encodeResponseHeader(&response_bytes, .{
        .kind = .ok,
        .request_id = 9,
        .payload_len = 4,
    });
    const response_header = try decodeResponseHeader(response_bytes[0..response_written]);

    try testing.expectEqual(DriverMessageKind.echo, request_header.kind);
    try testing.expectEqual(@as(u32, 9), request_header.request_id);
    try testing.expectEqual(DriverMessageKind.ok, response_header.kind);
    try testing.expectEqual(@as(u32, 4), response_header.payload_len);
}

test "decode rejects invalid kinds in request and response space" {
    var bytes: [request_header_size_bytes]u8 = undefined;
    _ = try encodeRequestHeader(&bytes, .{
        .kind = .ping,
        .request_id = 1,
        .payload_len = 0,
    });
    bytes[6] = @intFromEnum(DriverMessageKind.ok);
    try testing.expectError(error.InvalidInput, decodeRequestHeader(&bytes));

    var response_bytes: [response_header_size_bytes]u8 = undefined;
    _ = try encodeResponseHeader(&response_bytes, .{
        .kind = .ok,
        .request_id = 1,
        .payload_len = 0,
    });
    response_bytes[6] = @intFromEnum(DriverMessageKind.echo);
    try testing.expectError(error.InvalidInput, decodeResponseHeader(&response_bytes));
}

test "decode rejects unsupported protocol version" {
    var bytes: [response_header_size_bytes]u8 = undefined;
    _ = try encodeResponseHeader(&bytes, .{
        .kind = .ok,
        .request_id = 2,
        .payload_len = 0,
    });
    std.mem.writeInt(u16, bytes[4..6], 2, .little);
    try testing.expectError(error.Unsupported, decodeResponseHeader(&bytes));
}

test "decode rejects non-zero reserved bytes" {
    var request_bytes: [request_header_size_bytes]u8 = undefined;
    _ = try encodeRequestHeader(&request_bytes, .{
        .kind = .ping,
        .request_id = 1,
        .payload_len = 0,
    });
    request_bytes[7] = 1;
    try testing.expectError(error.InvalidInput, decodeRequestHeader(&request_bytes));

    var response_bytes: [response_header_size_bytes]u8 = undefined;
    _ = try encodeResponseHeader(&response_bytes, .{
        .kind = .ok,
        .request_id = 1,
        .payload_len = 0,
    });
    response_bytes[7] = 1;
    try testing.expectError(error.InvalidInput, decodeResponseHeader(&response_bytes));
}

test "decode rejects invalid magic and truncated headers" {
    var request_bytes: [request_header_size_bytes]u8 = undefined;
    _ = try encodeRequestHeader(&request_bytes, .{
        .kind = .echo,
        .request_id = 7,
        .payload_len = 3,
    });
    request_bytes[0] = 'X';
    try testing.expectError(error.InvalidInput, decodeRequestHeader(&request_bytes));

    var response_bytes: [response_header_size_bytes]u8 = undefined;
    _ = try encodeResponseHeader(&response_bytes, .{
        .kind = .ok,
        .request_id = 7,
        .payload_len = 3,
    });
    response_bytes[0] = 'X';
    try testing.expectError(error.InvalidInput, decodeResponseHeader(&response_bytes));

    try testing.expectError(
        error.EndOfStream,
        decodeRequestHeader(request_bytes[0 .. request_header_size_bytes - 1]),
    );
    try testing.expectError(
        error.EndOfStream,
        decodeResponseHeader(response_bytes[0 .. response_header_size_bytes - 1]),
    );
}
