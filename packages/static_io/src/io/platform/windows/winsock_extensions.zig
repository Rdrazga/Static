//! Winsock extension function loading (`AcceptEx`, `ConnectEx`).
//!
//! This module is Windows-only and performs no allocation; it just exposes
//! helpers for calling `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER, ...)`.

const std = @import("std");
const assert = std.debug.assert;

const windows = std.os.windows;
const ws2_32 = windows.ws2_32;

/// Signature of `AcceptEx`.
pub const AcceptExFn = *const fn (
    listen_socket: ws2_32.SOCKET,
    accept_socket: ws2_32.SOCKET,
    output_buffer: *anyopaque,
    receive_data_len: windows.DWORD,
    local_addr_len: windows.DWORD,
    remote_addr_len: windows.DWORD,
    bytes_received: *windows.DWORD,
    overlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

/// Signature of `ConnectEx`.
pub const ConnectExFn = *const fn (
    socket: ws2_32.SOCKET,
    name: *const ws2_32.sockaddr,
    name_len: i32,
    send_buffer: ?*const anyopaque,
    send_len: windows.DWORD,
    bytes_sent: ?*windows.DWORD,
    overlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

/// Loaded Winsock extension entry points.
pub const Extensions = struct {
    accept_ex: AcceptExFn,
    connect_ex: ConnectExFn,
};

/// Loads required extension pointers for an overlapped socket.
pub fn load(socket: ws2_32.SOCKET) error{Unsupported}!Extensions {
    assert(socket != ws2_32.INVALID_SOCKET);
    const accept_ex = loadPointer(AcceptExFn, socket, wsaid_accept_ex) catch return error.Unsupported;
    const connect_ex = loadPointer(ConnectExFn, socket, wsaid_connect_ex) catch return error.Unsupported;
    return .{
        .accept_ex = accept_ex,
        .connect_ex = connect_ex,
    };
}

/// Calls `WSAIoctl` to resolve one extension function pointer.
fn loadPointer(comptime T: type, socket: ws2_32.SOCKET, guid: windows.GUID) error{Unsupported}!T {
    assert(socket != ws2_32.INVALID_SOCKET);
    var out: T = undefined;
    var bytes: windows.DWORD = 0;
    const rc = ws2_32.WSAIoctl(
        socket,
        sio_get_extension_function_pointer,
        @ptrCast(@constCast(&guid)),
        @sizeOf(windows.GUID),
        @ptrCast(&out),
        @sizeOf(T),
        &bytes,
        null,
        null,
    );
    if (rc == ws2_32.SOCKET_ERROR) return error.Unsupported;
    if (bytes != @sizeOf(T)) return error.Unsupported;
    assert(bytes == @sizeOf(T));
    return out;
}

const sio_get_extension_function_pointer: windows.DWORD = 0xC8000006;

const wsaid_accept_ex: windows.GUID = .{
    .Data1 = 0xB5367DF1,
    .Data2 = 0xCBAC,
    .Data3 = 0x11CF,
    .Data4 = .{ 0x95, 0xCA, 0x00, 0x80, 0x5F, 0x48, 0xA1, 0x92 },
};

const wsaid_connect_ex: windows.GUID = .{
    .Data1 = 0x25A207B9,
    .Data2 = 0xDDF3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8E, 0xE9, 0x76, 0xE5, 0x8C, 0x74, 0x06, 0x3E },
};
