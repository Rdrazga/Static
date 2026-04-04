//! Shared `static_io` value types.

const std = @import("std");
const core = @import("static_core");
const collections = @import("static_collections");
const static_net = @import("static_net");

/// Opaque operation identifier returned by backend `submit`.
pub const OperationId = u32;
/// Stable runtime handle type with generation protection.
pub const Handle = collections.handle.Handle;
/// Backend-native handle representation.
pub const NativeHandle = usize;

/// Runtime handle categories.
pub const HandleKind = enum(u8) {
    file,
    stream,
    listener,
};

/// Typed file handle wrapper.
pub const File = struct { handle: Handle };
/// Typed stream handle wrapper.
pub const Stream = struct { handle: Handle };
/// Typed listener handle wrapper.
pub const Listener = struct { handle: Handle };
/// Network endpoint type shared with `static_net`.
pub const Endpoint = static_net.Endpoint;

/// Buffer API failures.
pub const BufferError = error{
    InvalidInput,
};

comptime {
    core.errors.assertVocabularySubset(BufferError);
}

/// Caller-owned byte slice plus logical used length.
pub const Buffer = struct {
    bytes: []u8,
    used_len: u32 = 0,

    /// Returns total byte capacity of the buffer.
    pub fn capacity(self: Buffer) u32 {
        std.debug.assert(self.bytes.len <= std.math.maxInt(u32));
        return @intCast(self.bytes.len);
    }

    /// Updates logical used length if it is within bounds.
    pub fn setUsedLen(self: *Buffer, used_len: u32) BufferError!void {
        std.debug.assert(self.bytes.len <= std.math.maxInt(u32));
        if (used_len > self.bytes.len) return error.InvalidInput;
        self.used_len = used_len;
    }

    /// Returns the logical prefix `[0..used_len]`.
    pub fn usedSlice(self: Buffer) []u8 {
        std.debug.assert(self.bytes.len <= std.math.maxInt(u32));
        std.debug.assert(self.used_len <= self.bytes.len);
        return self.bytes[0..self.used_len];
    }
};

/// Supported asynchronous operations.
pub const Operation = union(enum) {
    nop: Buffer,
    fill: struct {
        buffer: Buffer,
        len: u32,
        byte: u8,
    },
    stream_read: struct {
        stream: Stream,
        buffer: Buffer,
        timeout_ns: ?u64,
    },
    stream_write: struct {
        stream: Stream,
        buffer: Buffer,
        timeout_ns: ?u64,
    },
    accept: struct {
        listener: Listener,
        stream: Stream,
        timeout_ns: ?u64,
    },
    connect: struct {
        stream: Stream,
        endpoint: Endpoint,
        timeout_ns: ?u64,
    },
    file_read_at: struct {
        file: File,
        buffer: Buffer,
        offset_bytes: u64,
        timeout_ns: ?u64,
    },
    file_write_at: struct {
        file: File,
        buffer: Buffer,
        offset_bytes: u64,
        timeout_ns: ?u64,
    },
};

/// Stable completion status vocabulary across all backends.
pub const CompletionStatus = enum {
    success,
    cancelled,
    timeout,
    would_block,
    closed,
    invalid_input,
    unsupported,
    not_found,
    no_space_left,
    access_denied,
    already_exists,
    address_in_use,
    address_unavailable,
    connection_refused,
    connection_reset,
    broken_pipe,
    name_too_long,
};

/// Operation tag mirrored in completions.
pub const OperationTag = enum(u8) {
    nop,
    fill,
    stream_read,
    stream_write,
    accept,
    connect,
    file_read_at,
    file_write_at,
};

/// Stable completion error tags across all backends.
pub const CompletionErrorTag = enum(u8) {
    cancelled,
    closed,
    timeout,
    would_block,
    invalid_input,
    unsupported,
    not_found,
    no_space_left,
    access_denied,
    already_exists,
    address_in_use,
    address_unavailable,
    connection_refused,
    connection_reset,
    broken_pipe,
    name_too_long,
};

/// Completion record returned by backend `poll`.
pub const Completion = struct {
    operation_id: OperationId,
    tag: OperationTag = .nop,
    status: CompletionStatus,
    bytes_transferred: u32,
    buffer: Buffer,
    err: ?CompletionErrorTag = null,
    handle: ?Handle = null,
    endpoint: ?Endpoint = null,
};

/// Feature flags advertised by each backend.
pub const CapabilityFlags = packed struct(u64) {
    supports_nop: bool = false,
    supports_fill: bool = false,
    supports_cancel: bool = false,
    supports_close: bool = false,
    supports_files: bool = false,
    supports_streams: bool = false,
    supports_listeners: bool = false,
    supports_stream_read: bool = false,
    supports_stream_write: bool = false,
    supports_accept: bool = false,
    supports_connect: bool = false,
    supports_file_read_at: bool = false,
    supports_file_write_at: bool = false,
    supports_timeouts: bool = false,
    reserved: u50 = 0,
};

test "buffer used length checks bounds" {
    var storage: [8]u8 = [_]u8{0} ** 8;
    var buffer = Buffer{ .bytes = &storage };
    try buffer.setUsedLen(8);
    try std.testing.expectEqual(@as(usize, 8), buffer.usedSlice().len);
    try std.testing.expectError(error.InvalidInput, buffer.setUsedLen(9));
}
