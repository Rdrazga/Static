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
pub const CloseHandle = std.os.windows.CloseHandle;
pub const LPCWSTR = std.os.windows.LPCWSTR;
pub const OVERLAPPED = @import("static_net_native").windows_compat.OVERLAPPED;
pub const TRUE = BOOL.TRUE;
pub const ULONG = std.os.windows.ULONG;
pub const ULONG_PTR = std.os.windows.ULONG_PTR;
pub const UINT = std.os.windows.UINT;
pub const Win32Error = std.os.windows.Win32Error;
pub const WORD = std.os.windows.WORD;

pub const ws2_32 = @import("static_net_native").windows_compat.ws2_32;

pub const kernel32 = struct {
    pub const GetLastError = std.os.windows.GetLastError;

    pub extern "kernel32" fn CancelIoEx(
        hFile: HANDLE,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CreateFileW(
        lpFileName: LPCWSTR,
        dwDesiredAccess: ACCESS_MASK,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    pub extern "kernel32" fn CreateIoCompletionPort(
        FileHandle: HANDLE,
        ExistingCompletionPort: ?HANDLE,
        CompletionKey: ULONG_PTR,
        NumberOfConcurrentThreads: DWORD,
    ) callconv(.winapi) ?HANDLE;

    pub extern "kernel32" fn GetOverlappedResult(
        hFile: HANDLE,
        lpOverlapped: *OVERLAPPED,
        lpNumberOfBytesTransferred: *DWORD,
        bWait: BOOL,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetQueuedCompletionStatus(
        CompletionPort: HANDLE,
        lpNumberOfBytesTransferred: *DWORD,
        lpCompletionKey: *ULONG_PTR,
        lpOverlapped: *?*OVERLAPPED,
        dwMilliseconds: DWORD,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn PostQueuedCompletionStatus(
        CompletionPort: HANDLE,
        dwNumberOfBytesTransferred: DWORD,
        dwCompletionKey: ULONG_PTR,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: std.os.windows.LPVOID,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn SleepEx(
        dwMilliseconds: DWORD,
        bAlertable: BOOL,
    ) callconv(.winapi) DWORD;

    pub extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;
};

pub const CREATE_NEW: DWORD = 1;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const TRUNCATE_EXISTING: DWORD = 5;
