//! Shared OS error mapping for stable `static_io` completion tags.
//!
//! OS backends use this module to convert platform-specific error codes into a
//! stable, cross-backend vocabulary.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");
const types = @import("types.zig");

/// Stable completion status plus stable error tag.
pub const MappedCompletionError = struct {
    status: types.CompletionStatus,
    tag: types.CompletionErrorTag,
};

/// Converts a stable error tag into its completion status.
pub fn statusFromTag(tag: types.CompletionErrorTag) types.CompletionStatus {
    return switch (tag) {
        .cancelled => .cancelled,
        .closed => .closed,
        .timeout => .timeout,
        .would_block => .would_block,
        .invalid_input => .invalid_input,
        .unsupported => .unsupported,
        .not_found => .not_found,
        .no_space_left => .no_space_left,
        .access_denied => .access_denied,
        .already_exists => .already_exists,
        .address_in_use => .address_in_use,
        .address_unavailable => .address_unavailable,
        .connection_refused => .connection_refused,
        .connection_reset => .connection_reset,
        .broken_pipe => .broken_pipe,
        .name_too_long => .name_too_long,
    };
}

/// Builds a mapped completion value from a stable tag.
pub fn fromTag(tag: types.CompletionErrorTag) MappedCompletionError {
    const status = statusFromTag(tag);
    assert(status != .success);
    return .{ .status = status, .tag = tag };
}

/// Maps a POSIX errno value into the stable completion vocabulary.
pub fn fromPosixErrno(err: std.posix.E) MappedCompletionError {
    if (builtin.os.tag == .linux) {
        // On Linux, `std.posix.E` is `std.os.linux.E`, which does not expose a
        // dedicated `NOTSUP` tag (it aliases to `OPNOTSUPP`).
        return fromLinuxErrno(@enumFromInt(@intFromEnum(err)));
    }

    const tag: types.CompletionErrorTag = switch (err) {
        .TIMEDOUT => .timeout,
        .AGAIN => .would_block,
        .PERM, .ACCES => .access_denied,
        .NOMEM, .NOBUFS => .no_space_left,
        .NOENT => .not_found,
        .NOSPC => .no_space_left,
        .EXIST => .already_exists,
        .ADDRINUSE => .address_in_use,
        .ADDRNOTAVAIL => .address_unavailable,
        .CONNREFUSED => .connection_refused,
        .CONNABORTED => .connection_reset,
        .CONNRESET => .connection_reset,
        .NOTCONN => .invalid_input,
        .HOSTUNREACH, .NETUNREACH, .NETDOWN, .NETRESET => .address_unavailable,
        .PIPE => .broken_pipe,
        .NAMETOOLONG => .name_too_long,
        .OPNOTSUPP, .NOSYS => .unsupported,
        .INVAL, .BADF => .invalid_input,
        .SUCCESS => .invalid_input,
        else => .invalid_input,
    };
    return fromTag(tag);
}

/// Maps a Linux errno value into the stable completion vocabulary.
pub fn fromLinuxErrno(err: std.os.linux.E) MappedCompletionError {
    const tag: types.CompletionErrorTag = switch (err) {
        .TIMEDOUT => .timeout,
        .AGAIN => .would_block,
        .PERM, .ACCES => .access_denied,
        .NOMEM, .NOBUFS => .no_space_left,
        .NOENT => .not_found,
        .NOSPC => .no_space_left,
        .EXIST => .already_exists,
        .ADDRINUSE => .address_in_use,
        .ADDRNOTAVAIL, .HOSTUNREACH, .NETUNREACH => .address_unavailable,
        .CONNREFUSED => .connection_refused,
        .CONNABORTED => .connection_reset,
        .CONNRESET => .connection_reset,
        .NOTCONN => .invalid_input,
        .NETDOWN, .NETRESET => .address_unavailable,
        .PIPE => .broken_pipe,
        .NAMETOOLONG => .name_too_long,
        .OPNOTSUPP, .NOSYS => .unsupported,
        .INVAL, .BADF => .invalid_input,
        .SUCCESS => .invalid_input,
        else => .invalid_input,
    };
    return fromTag(tag);
}

/// Maps a Windows error code (`DWORD`) into the stable completion vocabulary.
pub const fromWindowsErrorCode = windows_impl.fromWindowsErrorCode;

const windows_impl = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const wsae_would_block: u32 = 10035;
    const wsae_access: u32 = 10013;
    const wsae_addr_in_use: u32 = 10048;
    const wsae_addr_not_avail: u32 = 10049;
    const wsae_net_down: u32 = 10050;
    const wsae_net_unreach: u32 = 10051;
    const wsae_net_reset: u32 = 10052;
    const wsae_conn_aborted: u32 = 10053;
    const wsae_conn_reset: u32 = 10054;
    const wsae_no_bufs: u32 = 10055;
    const wsae_not_conn: u32 = 10057;
    const wsae_shutdown: u32 = 10058;
    const wsae_timed_out: u32 = 10060;
    const wsae_conn_refused: u32 = 10061;
    const wsae_name_too_long: u32 = 10063;
    const wsae_host_unreach: u32 = 10065;

    /// Maps Win32 and Winsock errors returned by overlapped I/O.
    pub fn fromWindowsErrorCode(err_code: u32) MappedCompletionError {
        const tag: types.CompletionErrorTag = switch (err_code) {
            @intFromEnum(windows.Win32Error.WAIT_TIMEOUT) => .timeout,

            @intFromEnum(windows.Win32Error.FILE_NOT_FOUND),
            @intFromEnum(windows.Win32Error.PATH_NOT_FOUND),
            => .not_found,

            @intFromEnum(windows.Win32Error.ACCESS_DENIED),
            @intFromEnum(windows.Win32Error.NETWORK_ACCESS_DENIED),
            => .access_denied,

            @intFromEnum(windows.Win32Error.DISK_FULL),
            @intFromEnum(windows.Win32Error.HANDLE_DISK_FULL),
            => .no_space_left,

            @intFromEnum(windows.Win32Error.ALREADY_EXISTS),
            @intFromEnum(windows.Win32Error.FILE_EXISTS),
            => .already_exists,

            @intFromEnum(windows.Win32Error.NOT_SUPPORTED),
            @intFromEnum(windows.Win32Error.CALL_NOT_IMPLEMENTED),
            => .unsupported,

            @intFromEnum(windows.Win32Error.INVALID_HANDLE),
            @intFromEnum(windows.Win32Error.INVALID_PARAMETER),
            => .invalid_input,

            @intFromEnum(windows.Win32Error.CONNECTION_REFUSED) => .connection_refused,
            @intFromEnum(windows.Win32Error.CONNECTION_ABORTED),
            @intFromEnum(windows.Win32Error.GRACEFUL_DISCONNECT),
            @intFromEnum(windows.Win32Error.CONNECTION_INVALID),
            @intFromEnum(windows.Win32Error.NETNAME_DELETED),
            => .connection_reset,

            // Winsock errors can surface as `DWORD` values in IOCP completions.
            wsae_would_block => .would_block,
            wsae_addr_in_use => .address_in_use,
            wsae_addr_not_avail => .address_unavailable,
            wsae_access => .access_denied,
            wsae_no_bufs => .no_space_left,
            wsae_conn_refused => .connection_refused,
            wsae_conn_aborted => .connection_reset,
            wsae_conn_reset => .connection_reset,
            wsae_not_conn => .invalid_input,
            wsae_shutdown => .broken_pipe,
            wsae_net_down,
            wsae_net_reset,
            => .address_unavailable,
            wsae_timed_out => .timeout,
            wsae_name_too_long => .name_too_long,
            wsae_host_unreach,
            wsae_net_unreach,
            => .address_unavailable,

            // Named pipe style errors.
            @intFromEnum(windows.Win32Error.BROKEN_PIPE),
            @intFromEnum(windows.Win32Error.NO_DATA),
            @intFromEnum(windows.Win32Error.PIPE_NOT_CONNECTED),
            => .broken_pipe,

            // Path/file name too long.
            @intFromEnum(windows.Win32Error.FILENAME_EXCED_RANGE) => .name_too_long,

            else => .invalid_input,
        };
        return fromTag(tag);
    }
} else struct {
    /// Non-Windows fallback keeps interface available for cross-target tests.
    pub fn fromWindowsErrorCode(err_code: u32) MappedCompletionError {
        _ = err_code;
        return fromTag(.invalid_input);
    }
};

test "statusFromTag matches field name" {
    try testing.expectEqual(types.CompletionStatus.timeout, statusFromTag(.timeout));
    try testing.expectEqual(types.CompletionStatus.access_denied, statusFromTag(.access_denied));
    try testing.expectEqual(types.CompletionStatus.connection_refused, statusFromTag(.connection_refused));
}

test "all error tags map to non-success statuses and imply zero progress" {
    inline for (@typeInfo(types.CompletionErrorTag).@"enum".fields) |field| {
        const tag: types.CompletionErrorTag = @enumFromInt(field.value);
        const status = statusFromTag(tag);
        try testing.expect(status != .success);

        const completion: types.Completion = .{
            .operation_id = 1,
            .tag = .nop,
            .status = status,
            .bytes_transferred = 0,
            .buffer = .{ .bytes = &[_]u8{} },
            .err = tag,
            .handle = null,
            .endpoint = null,
        };
        try testing.expect(completion.err != null);
        try testing.expectEqual(@as(u32, 0), completion.bytes_transferred);
        try testing.expectEqual(statusFromTag(completion.err.?), completion.status);
    }
}

test "posix errno maps to stable tags" {
    try testing.expectEqual(types.CompletionErrorTag.access_denied, fromPosixErrno(.ACCES).tag);
    try testing.expectEqual(types.CompletionErrorTag.not_found, fromPosixErrno(.NOENT).tag);
    try testing.expectEqual(types.CompletionErrorTag.no_space_left, fromPosixErrno(.NOSPC).tag);
    try testing.expectEqual(types.CompletionErrorTag.connection_refused, fromPosixErrno(.CONNREFUSED).tag);
}

test "linux errno maps to stable tags" {
    try testing.expectEqual(types.CompletionErrorTag.would_block, fromLinuxErrno(.AGAIN).tag);
    try testing.expectEqual(types.CompletionErrorTag.name_too_long, fromLinuxErrno(.NAMETOOLONG).tag);
    try testing.expectEqual(types.CompletionErrorTag.address_unavailable, fromLinuxErrno(.HOSTUNREACH).tag);
}

test "windows error code maps to stable tags" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const windows = std.os.windows;

    try testing.expectEqual(types.CompletionErrorTag.not_found, fromWindowsErrorCode(@intFromEnum(windows.Win32Error.FILE_NOT_FOUND)).tag);
    try testing.expectEqual(types.CompletionErrorTag.access_denied, fromWindowsErrorCode(@intFromEnum(windows.Win32Error.ACCESS_DENIED)).tag);
    try testing.expectEqual(types.CompletionErrorTag.connection_refused, fromWindowsErrorCode(10061).tag);
    try testing.expectEqual(types.CompletionErrorTag.connection_reset, fromWindowsErrorCode(10053).tag);
    try testing.expectEqual(types.CompletionErrorTag.connection_reset, fromWindowsErrorCode(@intFromEnum(windows.Win32Error.NETNAME_DELETED)).tag);
    try testing.expectEqual(types.CompletionErrorTag.would_block, fromWindowsErrorCode(10035).tag);
}
