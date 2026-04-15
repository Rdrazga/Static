const std = @import("std");

pub const ACCESS_MASK = std.os.windows.ACCESS_MASK;
pub const BOOL = std.os.windows.BOOL;
pub const DWORD = std.os.windows.DWORD;
pub const FALSE = BOOL.FALSE;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
pub const GetLastError = std.os.windows.GetLastError;
pub const GUID = std.os.windows.GUID;
pub const HANDLE = std.os.windows.HANDLE;
pub const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;
pub const kernel32 = std.os.windows.kernel32;
pub const LPCWSTR = std.os.windows.LPCWSTR;
pub const OVERLAPPED = extern struct {
    Internal: std.os.windows.ULONG_PTR,
    InternalHigh: std.os.windows.ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?std.os.windows.PVOID,
    },
    hEvent: ?HANDLE,
};
pub const TRUE = BOOL.TRUE;
pub const ULONG = std.os.windows.ULONG;
pub const ULONG_PTR = std.os.windows.ULONG_PTR;
pub const UINT = std.os.windows.UINT;
pub const Win32Error = std.os.windows.Win32Error;
pub const WORD = std.os.windows.WORD;

pub const ws2_32 = struct {
    const win = std.os.windows;
    const base = win.ws2_32;

    pub const ADDRESS_FAMILY = base.ADDRESS_FAMILY;
    pub const GROUP = base.GROUP;
    pub const socklen_t = base.socklen_t;
    pub const sockaddr = base.sockaddr;

    pub const AF = base.AF;
    pub const SOCK = base.SOCK;
    pub const SOL = base.SOL;
    pub const SO = base.SO;
    pub const MSG = base.MSG;
    pub const IPPROTO = base.IPPROTO;

    pub const SOCKET = *anyopaque;
    pub const INVALID_SOCKET: SOCKET = @ptrFromInt(std.math.maxInt(usize));
    pub const SOCKET_ERROR: i32 = -1;
    pub const SD_SEND: i32 = 0x01;

    pub const POLL = struct {
        pub const IN: i16 = 0x0100 | 0x0200;
        pub const OUT: i16 = 0x0010;
        pub const ERR: i16 = 0x0001;
        pub const HUP: i16 = 0x0002;
        pub const NVAL: i16 = 0x0004;
    };

    pub const WSAPOLLFD = extern struct {
        fd: SOCKET,
        events: i16,
        revents: i16,
    };

    pub const WSADATA = extern struct {
        wVersion: win.WORD,
        wHighVersion: win.WORD,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*:0]u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
    };

    pub const WSABUF = extern struct {
        len: u32,
        buf: [*]u8,
    };

    pub const ErrorCode = enum(u32) {
        IO_PENDING = 997,
        EACCES = 10013,
        EWOULDBLOCK = 10035,
        EINPROGRESS = 10036,
        EALREADY = 10037,
        EADDRINUSE = 10048,
        EADDRNOTAVAIL = 10049,
        ENETDOWN = 10050,
        ENETUNREACH = 10051,
        ENETRESET = 10052,
        ECONNABORTED = 10053,
        ECONNRESET = 10054,
        ENOBUFS = 10055,
        ENOTCONN = 10057,
        ESHUTDOWN = 10058,
        ETIMEDOUT = 10060,
        ECONNREFUSED = 10061,
        ENAMETOOLONG = 10063,
        EHOSTUNREACH = 10065,
        _,
    };

    pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr, addrlen: ?*i32) callconv(.winapi) SOCKET;
    pub extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr, namelen: i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
    pub extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr, namelen: i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn getpeername(s: SOCKET, name: *sockaddr, namelen: *i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn getsockname(s: SOCKET, name: *sockaddr, namelen: *i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]u8, optlen: *i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, argp: *u32) callconv(.winapi) i32;
    pub extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: ?*const anyopaque, optlen: i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
    pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) ErrorCode;
    pub extern "ws2_32" fn WSAIoctl(
        s: SOCKET,
        dwIoControlCode: win.DWORD,
        lpvInBuffer: ?*anyopaque,
        cbInBuffer: win.DWORD,
        lpvOutBuffer: ?*anyopaque,
        cbOutBuffer: win.DWORD,
        lpcbBytesReturned: *win.DWORD,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) i32;
    pub extern "ws2_32" fn WSAPoll(fdarray: [*]WSAPOLLFD, fds: win.ULONG, timeout: i32) callconv(.winapi) i32;
    pub extern "ws2_32" fn WSARecv(
        s: SOCKET,
        lpBuffers: [*]WSABUF,
        dwBufferCount: win.DWORD,
        lpNumberOfBytesRecvd: ?*win.DWORD,
        lpFlags: *win.DWORD,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) i32;
    pub extern "ws2_32" fn WSASend(
        s: SOCKET,
        lpBuffers: [*]WSABUF,
        dwBufferCount: win.DWORD,
        lpNumberOfBytesSent: ?*win.DWORD,
        dwFlags: win.DWORD,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) i32;
    pub extern "ws2_32" fn WSASocketW(
        af: i32,
        @"type": i32,
        protocol: i32,
        lpProtocolInfo: ?*anyopaque,
        g: GROUP,
        dwFlags: win.DWORD,
    ) callconv(.winapi) SOCKET;
    pub extern "ws2_32" fn WSAStartup(wVersionRequested: win.WORD, lpWSAData: *WSADATA) callconv(.winapi) i32;
};
