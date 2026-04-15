//! Runtime orchestration over selected `static_io` backends.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");
const core = @import("static_core");
const collections = @import("static_collections");
const io_caps = @import("caps.zig");
const backend = @import("backend.zig");
const config = @import("config.zig");
const error_map = @import("error_map.zig");
const fake_backend = @import("fake_backend.zig");
const platform = @import("platform/selected_backend.zig");
const windows = @import("platform/windows/windows_compat.zig");
const threaded_backend = @import("threaded_backend.zig");
const types = @import("types.zig");
const static_net_native = @import("static_net_native");
const static_sync = @import("static_sync");
const PosixSockaddrAny = static_net_native.posix.SockaddrAny;
const WindowsSockaddrAny = static_net_native.windows.SockaddrAny;
const socketLocalEndpointPosix = static_net_native.posix.socketLocalEndpoint;
const socketLocalEndpointWindows = static_net_native.windows.socketLocalEndpoint;

const windows_platform = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn DeleteFileW(lpFileName: windows.LPCWSTR) callconv(.winapi) windows.BOOL;
} else struct {};

const BackendStorage = union(enum) {
    fake: fake_backend.FakeBackend,
    threaded: threaded_backend.ThreadedBackend,
    platform: platform.SelectedBackend,
};

const HandleState = enum {
    free,
    open,
    closed,
};

const HandleSlot = struct {
    state: HandleState = .free,
    kind: types.HandleKind = .file,
    adopted_native: ?types.NativeHandle = null,
    adopted_owned: bool = false,

    listener_endpoint: ?types.Endpoint = null,
};

/// File open configuration for `openFile`.
pub const FileOpenFlags = struct {
    read: bool = true,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    exclusive: bool = false,
};

/// Listener creation options.
pub const ListenOptions = struct {
    backlog: u32 = 128,
};

/// Ownership policy for adopted native handles.
pub const Ownership = enum(u8) {
    owned,
    borrowed,
};

/// `openFile` failures.
pub const OpenFileError = error{
    InvalidInput,
    OutOfMemory,
    NoSpaceLeft,
    Unsupported,
    NotFound,
    AlreadyExists,
    AccessDenied,
    NameTooLong,
    Closed,
};

/// Native-handle adoption failures.
pub const AdoptError = error{
    InvalidInput,
    NoSpaceLeft,
    Unsupported,
    Closed,
};

/// Handle close failures.
pub const CloseHandleError = error{
    InvalidInput,
    Closed,
};

/// Listener creation failures.
pub const ListenError = error{
    InvalidInput,
    NoSpaceLeft,
    Unsupported,
    AddressInUse,
    AddressUnavailable,
    AccessDenied,
    Closed,
};

/// `listenerLocalEndpoint` failures.
pub const ListenerEndpointError = error{
    InvalidInput,
    Closed,
    Unsupported,
};

/// `wait` failures.
pub const WaitError = error{
    Timeout,
    Cancelled,
    Closed,
    InvalidInput,
    Unsupported,
};

/// High-level runtime facade around selected backends.
pub const Runtime = struct {
    cfg: config.Config,
    backend_storage: BackendStorage,
    closed: bool = false,

    handles: []HandleSlot,
    handle_pool: collections.index_pool.IndexPool,

    /// Initializes runtime storage and selected backend.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!Runtime {
        config.validate(cfg) catch |cfg_err| switch (cfg_err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
        };

        var backend_storage = try initBackendStorage(allocator, cfg);
        errdefer switch (backend_storage) {
            .fake => |*fake| fake.deinit(),
            .threaded => |*threaded| threaded.deinit(),
            .platform => |*selected| selected.deinit(),
        };

        const handles = allocator.alloc(HandleSlot, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handles);
        @memset(handles, .{});

        const handle_pool = collections.index_pool.IndexPool.init(allocator, .{ .slots_max = cfg.handles_max, .budget = null }) catch |err| switch (err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.OutOfMemory => return error.OutOfMemory,
            error.NoSpaceLeft => unreachable,
            error.NotFound => unreachable,
            error.Overflow => unreachable,
        };
        errdefer {
            var owned_pool = handle_pool;
            owned_pool.deinit();
        }
        assert(handles.len == handle_pool.capacity());

        return .{
            .cfg = cfg,
            .backend_storage = backend_storage,
            .handles = handles,
            .handle_pool = handle_pool,
        };
    }

    /// Deinitializes backend and runtime-owned arrays.
    pub fn deinit(self: *Runtime) void {
        assert(self.handles.len == self.handle_pool.capacity());
        const allocator = switch (self.backend_storage) {
            .fake => |*fake| fake.allocator,
            .threaded => |*threaded| threaded.shared.allocator,
            .platform => |*platform_backend| platform_backend.getAllocator(),
        };

        switch (self.backend_storage) {
            .fake => |*fake| fake.deinit(),
            .threaded => |*threaded| threaded.deinit(),
            .platform => |*platform_backend| platform_backend.deinit(),
        }
        self.handle_pool.deinit();
        allocator.free(self.handles);
        self.* = undefined;
    }

    /// Opens a file and returns a runtime file handle.
    pub fn openFile(self: *Runtime, path: []const u8, flags: FileOpenFlags) OpenFileError!types.File {
        if (self.closed) return error.Closed;
        if (path.len == 0) return error.InvalidInput;

        const handle = self.allocHandle(.file) catch return error.NoSpaceLeft;
        errdefer self.freeAllocatedHandle(handle);

        if (!io_caps.os_backends_enabled or self.backend_storage == .fake) {
            var iface = self.backendIface();
            iface.registerHandle(handle, .file, 0, true);
            return .{ .handle = handle };
        }

        const allocator = switch (self.backend_storage) {
            .fake => unreachable,
            .threaded => |*threaded| threaded.shared.allocator,
            .platform => |*platform_backend| platform_backend.getAllocator(),
        };

        const native = try openNativeFile(allocator, path, flags);
        const slot = &self.handles[handle.index];
        assert(slot.state == .open);
        assert(slot.kind == .file);
        slot.adopted_native = native;
        slot.adopted_owned = true;
        var iface = self.backendIface();
        iface.registerHandle(handle, .file, native, true);
        return .{ .handle = handle };
    }

    /// Opens and binds a listener socket.
    pub fn listen(self: *Runtime, endpoint: types.Endpoint, options: ListenOptions) ListenError!types.Listener {
        if (self.closed) return error.Closed;

        const handle = self.allocHandle(.listener) catch return error.NoSpaceLeft;
        errdefer self.freeAllocatedHandle(handle);

        if (!io_caps.os_backends_enabled or self.backend_storage == .fake) {
            const slot = &self.handles[handle.index];
            slot.listener_endpoint = endpoint;
            var iface = self.backendIface();
            iface.registerHandle(handle, .listener, 0, true);
            return .{ .handle = handle };
        }

        const allocator = switch (self.backend_storage) {
            .fake => unreachable,
            .threaded => |*threaded| threaded.shared.allocator,
            .platform => |*platform_backend| platform_backend.getAllocator(),
        };

        const native = try listenNative(allocator, endpoint, options);
        const slot = &self.handles[handle.index];
        assert(slot.state == .open);
        assert(slot.kind == .listener);
        slot.adopted_native = native;
        slot.adopted_owned = true;
        slot.listener_endpoint = null;
        var iface = self.backendIface();
        iface.registerHandle(handle, .listener, native, true);
        return .{ .handle = handle };
    }

    /// Returns the listener's local endpoint, when available.
    pub fn listenerLocalEndpoint(self: *Runtime, listener: types.Listener) ListenerEndpointError!types.Endpoint {
        if (self.closed) return error.Closed;

        const handle_index = self.validateHandle(listener.handle, .listener) catch |err| switch (err) {
            error.InvalidInput => return error.InvalidInput,
            error.Closed => return error.Closed,
        };

        const slot = self.handles[handle_index];
        if (self.backend_storage == .fake) {
            return slot.listener_endpoint orelse error.Unsupported;
        }

        const native = slot.adopted_native orelse return error.Unsupported;
        return socketLocalEndpointNative(native) orelse error.Unsupported;
    }

    /// Adopts a native file handle into runtime handle tracking.
    pub fn adoptFile(self: *Runtime, native: types.NativeHandle, ownership: Ownership) AdoptError!types.File {
        const handle = try self.adoptHandle(.file, native, ownership);
        return .{ .handle = handle };
    }

    /// Adopts a native stream handle into runtime handle tracking.
    pub fn adoptStream(self: *Runtime, native: types.NativeHandle, ownership: Ownership) AdoptError!types.Stream {
        const handle = try self.adoptHandle(.stream, native, ownership);
        return .{ .handle = handle };
    }

    /// Adopts a native listener handle into runtime handle tracking.
    pub fn adoptListener(self: *Runtime, native: types.NativeHandle, ownership: Ownership) AdoptError!types.Listener {
        const handle = try self.adoptHandle(.listener, native, ownership);
        return .{ .handle = handle };
    }

    /// Marks a runtime handle closed and notifies the backend.
    pub fn closeHandle(self: *Runtime, handle: types.Handle) CloseHandleError!void {
        if (!handle.isValid()) return error.InvalidInput;
        const handle_index = self.handle_pool.validate(handle) catch return error.InvalidInput;
        if (handle_index >= self.handles.len) return error.InvalidInput;

        var slot = &self.handles[handle_index];
        if (slot.state == .free) return error.InvalidInput;
        if (slot.state == .closed) return error.Closed;
        assert(slot.state == .open);

        slot.state = .closed;
        var iface = self.backendIface();
        iface.notifyHandleClosed(handle);
    }

    /// Submits a validated operation to the selected backend.
    pub fn submit(self: *Runtime, op: types.Operation) backend.SubmitError!types.OperationId {
        if (self.closed) return error.Closed;
        var iface = self.backendIface();
        return iface.submit(op);
    }

    pub fn submitStreamRead(
        self: *Runtime,
        stream: types.Stream,
        buffer: types.Buffer,
        timeout_ns: ?u64,
    ) backend.SubmitError!types.OperationId {
        if (!isStreamBufferValid(buffer)) return error.InvalidInput;
        if (!isReadBufferValid(buffer)) return error.InvalidInput;
        _ = self.validateHandle(stream.handle, .stream) catch |err| return mapHandleSubmitError(err);
        return self.submit(.{ .stream_read = .{
            .stream = stream,
            .buffer = buffer,
            .timeout_ns = timeout_ns,
        } });
    }

    pub fn submitStreamWrite(
        self: *Runtime,
        stream: types.Stream,
        buffer: types.Buffer,
        timeout_ns: ?u64,
    ) backend.SubmitError!types.OperationId {
        if (!isWriteBufferValid(buffer)) return error.InvalidInput;
        _ = self.validateHandle(stream.handle, .stream) catch |err| return mapHandleSubmitError(err);
        return self.submit(.{ .stream_write = .{
            .stream = stream,
            .buffer = buffer,
            .timeout_ns = timeout_ns,
        } });
    }

    pub fn submitFileReadAt(
        self: *Runtime,
        file: types.File,
        buffer: types.Buffer,
        offset_bytes: u64,
        timeout_ns: ?u64,
    ) backend.SubmitError!types.OperationId {
        if (!isReadBufferValid(buffer)) return error.InvalidInput;
        _ = self.validateHandle(file.handle, .file) catch |err| return mapHandleSubmitError(err);
        return self.submit(.{ .file_read_at = .{
            .file = file,
            .buffer = buffer,
            .offset_bytes = offset_bytes,
            .timeout_ns = timeout_ns,
        } });
    }

    pub fn submitFileWriteAt(
        self: *Runtime,
        file: types.File,
        buffer: types.Buffer,
        offset_bytes: u64,
        timeout_ns: ?u64,
    ) backend.SubmitError!types.OperationId {
        if (!isWriteBufferValid(buffer)) return error.InvalidInput;
        _ = self.validateHandle(file.handle, .file) catch |err| return mapHandleSubmitError(err);
        return self.submit(.{ .file_write_at = .{
            .file = file,
            .buffer = buffer,
            .offset_bytes = offset_bytes,
            .timeout_ns = timeout_ns,
        } });
    }

    pub fn submitAccept(
        self: *Runtime,
        listener: types.Listener,
        timeout_ns: ?u64,
    ) backend.SubmitError!types.OperationId {
        _ = self.validateHandle(listener.handle, .listener) catch |err| return mapHandleSubmitError(err);
        const stream_handle = self.allocHandle(.stream) catch return error.WouldBlock;
        errdefer self.freeAllocatedHandle(stream_handle);
        assert(self.handles[stream_handle.index].kind == .stream);
        const stream = types.Stream{ .handle = stream_handle };
        return self.submit(.{ .accept = .{
            .listener = listener,
            .stream = stream,
            .timeout_ns = timeout_ns,
        } });
    }

    pub fn submitConnect(
        self: *Runtime,
        endpoint: types.Endpoint,
        timeout_ns: ?u64,
    ) backend.SubmitError!types.OperationId {
        if (endpointPort(endpoint) == 0) return error.InvalidInput;
        const stream_handle = self.allocHandle(.stream) catch return error.WouldBlock;
        errdefer self.freeAllocatedHandle(stream_handle);
        assert(self.handles[stream_handle.index].kind == .stream);
        const stream = types.Stream{ .handle = stream_handle };
        return self.submit(.{ .connect = .{
            .stream = stream,
            .endpoint = endpoint,
            .timeout_ns = timeout_ns,
        } });
    }

    pub fn pump(self: *Runtime, max_completions: u32) backend.PumpError!u32 {
        assert(max_completions > 0);
        var iface = self.backendIface();
        return iface.pump(max_completions);
    }

    /// Polls one completion and performs runtime-side cleanup.
    pub fn poll(self: *Runtime) ?types.Completion {
        var iface = self.backendIface();
        var completion = iface.poll() orelse return null;
        if (completion.status != .success) {
            switch (completion.tag) {
                .accept, .connect => if (completion.handle) |stream_handle| {
                    // `submitAccept`/`submitConnect` allocate a stream handle up front.
                    // On failure, keep the API robust by reclaiming the handle slot.
                    iface.notifyHandleClosed(stream_handle);
                    self.freeAllocatedHandle(stream_handle);
                    completion.handle = null;
                },
                else => {},
            }
        }
        return completion;
    }

    /// Requests cancellation of an in-flight operation.
    pub fn cancel(self: *Runtime, operation_id: types.OperationId) backend.CancelError!void {
        if (self.closed) return error.Closed;

        var iface = self.backendIface();
        try iface.cancel(operation_id);
    }

    /// Initiates runtime/backend shutdown.
    pub fn close(self: *Runtime) void {
        if (self.closed) return;
        self.closed = true;

        var iface = self.backendIface();
        iface.close();
    }

    /// Waits for at least one completion, timeout, cancellation, or closure.
    pub fn wait(
        self: *Runtime,
        max_completions: u32,
        timeout_ns: ?u64,
        cancel_token: ?static_sync.cancel.CancelToken,
    ) WaitError!u32 {
        if (max_completions == 0) return error.InvalidInput;
        assert(max_completions > 0);
        if (cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        const first = self.pump(max_completions) catch |err| switch (err) {
            error.InvalidInput => return error.InvalidInput,
            error.Unsupported => return error.Unsupported,
        };
        if (first > 0) return first;

        if (self.closed) return error.Closed;
        if (timeout_ns) |limit| {
            if (limit == 0) return error.Timeout;
        }

        if (cancel_token == null) {
            const maybe_backend_waited: ?u32 = self.waitBackend(max_completions, timeout_ns) catch |err| switch (err) {
                error.InvalidInput => return error.InvalidInput,
                error.Unsupported => null,
            };
            if (maybe_backend_waited) |waited| {
                if (waited > 0) return waited;
                if (timeout_ns != null) return error.Timeout;
            }
        } else if (cancel_token) |token| {
            switch (self.backend_storage) {
                .platform => |*platform_backend| {
                    var reg = static_sync.cancel.CancelRegistration.init(wakePlatformBackend, platform_backend);
                    reg.register(token) catch |err| switch (err) {
                        error.Cancelled => return error.Cancelled,
                        error.WouldBlock => return error.Unsupported,
                    };
                    defer reg.unregister();

                    const waited = self.waitBackend(max_completions, timeout_ns) catch |err| switch (err) {
                        error.InvalidInput => return error.InvalidInput,
                        error.Unsupported => return error.Unsupported,
                    };

                    if (token.isCancelled()) return error.Cancelled;
                    if (waited > 0) return waited;
                    if (timeout_ns != null) return error.Timeout;
                    return error.Unsupported;
                },
                .threaded => |*threaded| {
                    var reg = static_sync.cancel.CancelRegistration.init(wakeThreadedBackend, threaded);
                    reg.register(token) catch |err| switch (err) {
                        error.Cancelled => return error.Cancelled,
                        error.WouldBlock => return error.Unsupported,
                    };
                    defer reg.unregister();

                    const waited = self.waitBackend(max_completions, timeout_ns) catch |err| switch (err) {
                        error.InvalidInput => return error.InvalidInput,
                        error.Unsupported => return error.Unsupported,
                    };

                    if (token.isCancelled()) return error.Cancelled;
                    if (waited > 0) return waited;
                    if (timeout_ns != null) return error.Timeout;
                    return error.Unsupported;
                },
                else => {},
            }
        }

        const start_instant = if (timeout_ns != null) core.time_compat.Instant.now() catch return error.Unsupported else null;
        while (true) {
            if (cancel_token) |token| {
                if (token.isCancelled()) return error.Cancelled;
            }

            const pumped = self.pump(max_completions) catch |err| switch (err) {
                error.InvalidInput => return error.InvalidInput,
                error.Unsupported => return error.Unsupported,
            };
            if (pumped > 0) return pumped;
            if (self.closed) return error.Closed;

            if (timeout_ns) |limit| {
                const elapsed_ns = elapsedSince(start_instant.?) orelse return error.Unsupported;
                if (elapsed_ns >= limit) return error.Timeout;
            }
            std.Thread.yield() catch {};
        }
    }

    /// Returns capability flags advertised by the active backend.
    pub fn capabilities(self: *const Runtime) types.CapabilityFlags {
        const caps = switch (self.backend_storage) {
            .fake => |*fake| fake.capabilities(),
            .threaded => |*threaded| threaded.capabilities(),
            .platform => |*platform_backend| platform_backend.capabilities(),
        };
        return caps;
    }

    /// Returns true after `close` was called.
    pub fn isClosed(self: *const Runtime) bool {
        return self.closed;
    }

    fn initBackendStorage(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!BackendStorage {
        return switch (cfg.backend_kind) {
            .fake => .{ .fake = try fake_backend.FakeBackend.init(allocator, cfg) },
            .threaded => .{ .threaded = try threaded_backend.ThreadedBackend.init(allocator, cfg) },
            .platform => blk: {
                if (!io_caps.platformBackendEnabled(builtin.os.tag)) return error.Unsupported;
                break :blk .{ .platform = try platform.SelectedBackend.init(allocator, cfg) };
            },
            .windows_iocp => blk: {
                if (!io_caps.windowsBackendEnabled()) return error.Unsupported;
                break :blk .{ .platform = try platform.SelectedBackend.init(allocator, cfg) };
            },
            .linux_io_uring => blk: {
                if (!io_caps.linuxBackendEnabled()) return error.Unsupported;
                break :blk .{ .platform = try platform.SelectedBackend.init(allocator, cfg) };
            },
            .bsd_kqueue => blk: {
                if (!io_caps.bsdBackendEnabled(builtin.os.tag)) return error.Unsupported;
                break :blk .{ .platform = try platform.SelectedBackend.init(allocator, cfg) };
            },
        };
    }

    fn backendIface(self: *Runtime) backend.Backend {
        return switch (self.backend_storage) {
            .fake => |*fake| fake.asBackend(),
            .threaded => |*threaded| threaded.asBackend(),
            .platform => |*platform_backend| platform_backend.asBackend(),
        };
    }

    fn waitBackend(self: *Runtime, max_completions: u32, timeout_ns: ?u64) backend.PumpError!u32 {
        return switch (self.backend_storage) {
            .platform => |*platform_backend| platform_backend.waitForCompletions(max_completions, timeout_ns),
            .threaded => |*threaded| threaded.waitForCompletions(max_completions, timeout_ns),
            else => error.Unsupported,
        };
    }

    fn adoptHandle(
        self: *Runtime,
        kind: types.HandleKind,
        native: types.NativeHandle,
        ownership: Ownership,
    ) AdoptError!types.Handle {
        if (!io_caps.os_backends_enabled) return error.Unsupported;
        if (self.closed) return error.Closed;
        if (native == 0 and builtin.os.tag == .windows) return error.InvalidInput;

        const handle = self.allocHandle(kind) catch return error.NoSpaceLeft;
        var slot = &self.handles[handle.index];
        assert(slot.state == .open);
        assert(slot.kind == kind);
        slot.adopted_native = native;
        slot.adopted_owned = ownership == .owned;
        var iface = self.backendIface();
        iface.registerHandle(handle, kind, native, slot.adopted_owned);
        return handle;
    }

    fn allocHandle(self: *Runtime, kind: types.HandleKind) error{NoSpaceLeft}!types.Handle {
        if (self.handle_pool.freeCount() == 0) self.recycleClosedHandle();
        const handle = self.handle_pool.allocate() catch |err| switch (err) {
            error.NoSpaceLeft => return error.NoSpaceLeft,
            error.InvalidConfig, error.OutOfMemory, error.NotFound, error.Overflow => unreachable,
        };
        const slot_index = handle.index;
        assert(slot_index < self.handles.len);
        var slot = &self.handles[slot_index];
        assert(slot.state == .free);
        slot.state = .open;
        slot.kind = kind;
        slot.adopted_native = null;
        slot.adopted_owned = false;
        slot.listener_endpoint = null;
        return handle;
    }

    fn freeAllocatedHandle(self: *Runtime, handle: types.Handle) void {
        if (!handle.isValid()) return;
        const slot_index = self.handle_pool.validate(handle) catch return;
        assert(slot_index < self.handles.len);

        var slot = &self.handles[slot_index];
        if (slot.state != .open) return;

        slot.state = .free;
        slot.kind = .file;
        slot.adopted_native = null;
        slot.adopted_owned = false;
        slot.listener_endpoint = null;
        self.handle_pool.release(handle) catch unreachable;
    }

    fn recycleClosedHandle(self: *Runtime) void {
        var iface = self.backendIface();
        var index: u32 = 0;
        while (index < self.handles.len) : (index += 1) {
            var slot = &self.handles[index];
            if (slot.state != .closed) continue;
            const handle = self.handle_pool.handleForIndex(index) orelse continue;
            if (iface.handleInUse(handle)) continue;

            slot.state = .free;
            self.handle_pool.release(handle) catch unreachable;
            return;
        }
    }

    fn validateHandle(
        self: *Runtime,
        handle: types.Handle,
        expected_kind: types.HandleKind,
    ) error{ InvalidInput, Closed }!u32 {
        assert(expected_kind == .file or expected_kind == .stream or expected_kind == .listener);
        const handle_index = self.handle_pool.validate(handle) catch return error.InvalidInput;
        const slot = self.handles[handle_index];
        if (slot.kind != expected_kind) return error.InvalidInput;
        return switch (slot.state) {
            .open => handle_index,
            .closed => error.Closed,
            .free => error.InvalidInput,
        };
    }
};

fn endpointPort(endpoint: types.Endpoint) u16 {
    return switch (endpoint) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
}

fn socketLocalEndpointNative(native: types.NativeHandle) ?types.Endpoint {
    return switch (comptime builtin.os.tag) {
        .windows => socketLocalEndpointWindows(@ptrFromInt(native)),
        else => socketLocalEndpointPosix(@intCast(native)),
    };
}

fn openFileErrorFromTag(tag: types.CompletionErrorTag) OpenFileError {
    return switch (tag) {
        .no_space_left => error.NoSpaceLeft,
        .unsupported => error.Unsupported,
        .not_found => error.NotFound,
        .already_exists => error.AlreadyExists,
        .access_denied => error.AccessDenied,
        .name_too_long => error.NameTooLong,
        else => error.InvalidInput,
    };
}

fn listenErrorFromTag(tag: types.CompletionErrorTag) ListenError {
    return switch (tag) {
        .no_space_left => error.NoSpaceLeft,
        .unsupported => error.Unsupported,
        .address_in_use => error.AddressInUse,
        .address_unavailable => error.AddressUnavailable,
        .access_denied => error.AccessDenied,
        else => error.InvalidInput,
    };
}

fn openNativeFile(allocator: std.mem.Allocator, path: []const u8, flags: FileOpenFlags) OpenFileError!types.NativeHandle {
    return switch (comptime builtin.os.tag) {
        .windows => openNativeFileWindows(allocator, path, flags),
        else => openNativeFilePosix(path, flags),
    };
}

fn openNativeFileWindows(allocator: std.mem.Allocator, path: []const u8, flags: FileOpenFlags) OpenFileError!types.NativeHandle {
    const kernel32 = windows.kernel32;

    const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInput,
    };
    defer allocator.free(path_w);

    if (!flags.read and !flags.write) return error.InvalidInput;
    var desired_access: windows.ACCESS_MASK = .{};
    desired_access.GENERIC.READ = flags.read;
    desired_access.GENERIC.WRITE = flags.write;

    const share_mode: windows.DWORD = 0x00000001 | 0x00000002 | 0x00000004;

    const creation_disposition: windows.DWORD = if (flags.create) blk: {
        if (flags.exclusive) break :blk windows.CREATE_NEW;
        if (flags.truncate) break :blk windows.CREATE_ALWAYS;
        break :blk windows.OPEN_ALWAYS;
    } else blk: {
        if (flags.truncate) break :blk windows.TRUNCATE_EXISTING;
        break :blk windows.OPEN_EXISTING;
    };

    const flags_and_attributes: windows.DWORD = 0x00000080 | windows.FILE_FLAG_OVERLAPPED;
    const native_handle = kernel32.CreateFileW(
        path_w.ptr,
        desired_access,
        share_mode,
        null,
        creation_disposition,
        flags_and_attributes,
        null,
    );
    if (native_handle == windows.INVALID_HANDLE_VALUE) {
        const err_code: u32 = @intFromEnum(kernel32.GetLastError());
        const mapped = error_map.fromWindowsErrorCode(err_code);
        return openFileErrorFromTag(mapped.tag);
    }
    return @intFromPtr(native_handle);
}

fn openNativeFilePosix(path: []const u8, flags: FileOpenFlags) OpenFileError!types.NativeHandle {
    if (!flags.read and !flags.write) return error.InvalidInput;
    if (flags.exclusive and !flags.create) return error.InvalidInput;

    var open_flags: std.posix.O = .{
        .CLOEXEC = true,
    };
    open_flags.ACCMODE = if (flags.read and flags.write) .RDWR else if (flags.write) .WRONLY else .RDONLY;
    open_flags.CREAT = flags.create;
    open_flags.EXCL = flags.exclusive;
    open_flags.TRUNC = flags.truncate;

    const mode: std.posix.mode_t = if (flags.create) 0o666 else 0;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, open_flags, mode) catch |err| {
        return switch (err) {
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.FileNotFound => error.NotFound,
            error.PathAlreadyExists => error.AlreadyExists,
            error.NameTooLong => error.NameTooLong,
            error.NoSpaceLeft,
            error.SystemResources,
            error.SystemFdQuotaExceeded,
            error.ProcessFdQuotaExceeded,
            => error.NoSpaceLeft,
            error.FileLocksUnsupported => error.Unsupported,
            else => error.InvalidInput,
        };
    };
    return @intCast(fd);
}

fn listenNative(allocator: std.mem.Allocator, endpoint: types.Endpoint, options: ListenOptions) ListenError!types.NativeHandle {
    _ = allocator;
    return switch (comptime builtin.os.tag) {
        .windows => listenNativeWindows(endpoint, options),
        else => listenNativePosix(endpoint, options),
    };
}

fn listenNativeWindows(endpoint: types.Endpoint, options: ListenOptions) ListenError!types.NativeHandle {
    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const family: i32 = switch (endpoint) {
        .ipv4 => windows.ws2_32.AF.INET,
        .ipv6 => windows.ws2_32.AF.INET6,
    };
    const sock = windows.ws2_32.WSASocketW(
        family,
        windows.ws2_32.SOCK.STREAM,
        windows.ws2_32.IPPROTO.TCP,
        null,
        0,
        wsa_flag_overlapped,
    );
    if (sock == windows.ws2_32.INVALID_SOCKET) {
        const err_code: u32 = @intFromEnum(windows.ws2_32.WSAGetLastError());
        const mapped = error_map.fromWindowsErrorCode(err_code);
        return listenErrorFromTag(mapped.tag);
    }
    errdefer _ = windows.ws2_32.closesocket(sock);

    // Winsock2 uses `SO_EXCLUSIVEADDRUSE == ~SO_REUSEADDR` (i.e. `-5`) but Zig's
    // bindings do not currently expose a named constant for it.
    const so_exclusiveaddruse: i32 = -5;

    var exclusive: i32 = 1;
    if (windows.ws2_32.setsockopt(sock, windows.ws2_32.SOL.SOCKET, so_exclusiveaddruse, @ptrCast(&exclusive), @sizeOf(i32)) == windows.ws2_32.SOCKET_ERROR) {
        const err_code: u32 = @intFromEnum(windows.ws2_32.WSAGetLastError());
        const mapped = error_map.fromWindowsErrorCode(err_code);
        return listenErrorFromTag(mapped.tag);
    }

    var addr = WindowsSockaddrAny.fromEndpoint(endpoint);
    if (windows.ws2_32.bind(sock, addr.ptr(), addr.len()) == windows.ws2_32.SOCKET_ERROR) {
        const err_code: u32 = @intFromEnum(windows.ws2_32.WSAGetLastError());
        const mapped = error_map.fromWindowsErrorCode(err_code);
        return listenErrorFromTag(mapped.tag);
    }

    const backlog_i32: i32 = if (options.backlog > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(options.backlog);
    if (windows.ws2_32.listen(sock, backlog_i32) == windows.ws2_32.SOCKET_ERROR) {
        const err_code: u32 = @intFromEnum(windows.ws2_32.WSAGetLastError());
        const mapped = error_map.fromWindowsErrorCode(err_code);
        return listenErrorFromTag(mapped.tag);
    }

    return @intFromPtr(sock);
}

fn listenNativePosix(endpoint: types.Endpoint, options: ListenOptions) ListenError!types.NativeHandle {
    const family: u32 = switch (endpoint) {
        .ipv4 => std.posix.AF.INET,
        .ipv6 => std.posix.AF.INET6,
    };
    const sock_rc = std.posix.system.socket(family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    const sock: std.posix.socket_t = switch (std.posix.errno(sock_rc)) {
        .SUCCESS => @intCast(sock_rc),
        else => |errno_tag| {
            const mapped = error_map.fromPosixErrno(errno_tag);
            return listenErrorFromTag(mapped.tag);
        },
    };
    errdefer std.posix.close(sock);

    var reuse: i32 = 1;
    std.posix.setsockopt(sock, @intCast(std.posix.SOL.SOCKET), @intCast(std.posix.SO.REUSEADDR), std.mem.asBytes(&reuse)) catch {};

    var addr = PosixSockaddrAny.fromEndpoint(endpoint);
    const bind_rc = std.posix.system.bind(sock, addr.ptr(), addr.len());
    switch (std.posix.errno(bind_rc)) {
        .SUCCESS => {},
        else => |errno_tag| {
            const mapped = error_map.fromPosixErrno(errno_tag);
            return listenErrorFromTag(mapped.tag);
        },
    }

    const listen_rc = std.posix.system.listen(sock, options.backlog);
    switch (std.posix.errno(listen_rc)) {
        .SUCCESS => {},
        else => |errno_tag| {
            const mapped = error_map.fromPosixErrno(errno_tag);
            return listenErrorFromTag(mapped.tag);
        },
    }

    return @intCast(sock);
}

fn mapHandleSubmitError(err: anyerror) backend.SubmitError {
    return switch (err) {
        error.InvalidInput => error.InvalidInput,
        error.Closed => error.Closed,
        else => error.InvalidInput,
    };
}

fn isBufferValid(buffer: types.Buffer) bool {
    return buffer.used_len <= buffer.bytes.len;
}

fn isStreamBufferValid(buffer: types.Buffer) bool {
    if (buffer.bytes.len == 0) return false;
    return isBufferValid(buffer);
}

fn isReadBufferValid(buffer: types.Buffer) bool {
    if (!isBufferValid(buffer)) return false;
    return buffer.used_len == 0;
}

fn isWriteBufferValid(buffer: types.Buffer) bool {
    if (buffer.bytes.len == 0) return false;
    if (!isBufferValid(buffer)) return false;
    return buffer.used_len != 0;
}

fn wakePlatformBackend(ctx: ?*anyopaque) void {
    const backend_ptr: *platform.SelectedBackend = @ptrCast(@alignCast(ctx.?));
    backend_ptr.wakeup();
}

fn wakeThreadedBackend(ctx: ?*anyopaque) void {
    const backend_ptr: *threaded_backend.ThreadedBackend = @ptrCast(@alignCast(ctx.?));
    backend_ptr.wakeup();
}

fn elapsedSince(start: core.time_compat.Instant) ?u64 {
    const now = core.time_compat.Instant.now() catch return null;
    return now.since(start);
}

test "runtime fake backend preserves deterministic ordering" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(2));
    defer runtime_impl.deinit();

    var storage_a: [8]u8 = [_]u8{0} ** 8;
    var storage_b: [8]u8 = [_]u8{0} ** 8;
    const buffer_a = types.Buffer{ .bytes = &storage_a };
    const buffer_b = types.Buffer{ .bytes = &storage_b };

    const id_a = try runtime_impl.submit(.{ .fill = .{
        .buffer = buffer_a,
        .len = 4,
        .byte = 0x22,
    } });
    const id_b = try runtime_impl.submit(.{ .nop = buffer_b });
    try testing.expectError(error.WouldBlock, runtime_impl.submit(.{ .nop = buffer_b }));

    _ = try runtime_impl.pump(8);
    const completion_a = runtime_impl.poll().?;
    const completion_b = runtime_impl.poll().?;
    try testing.expect(runtime_impl.poll() == null);

    try testing.expectEqual(id_a, completion_a.operation_id);
    try testing.expectEqual(id_b, completion_b.operation_id);
    try testing.expectEqual(types.CompletionStatus.success, completion_a.status);
    try testing.expectEqual(types.CompletionStatus.success, completion_b.status);
    try testing.expectEqual(@as(u8, 0x22), completion_a.buffer.bytes[0]);
}

test "runtime stream write then read roundtrip through fake backend" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(4));
    defer runtime_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9000,
    } };
    const connect_id = try runtime_impl.submitConnect(endpoint, null);
    _ = try runtime_impl.pump(1);
    const connect_completion = runtime_impl.poll().?;
    try testing.expectEqual(connect_id, connect_completion.operation_id);
    const stream = types.Stream{ .handle = connect_completion.handle.? };

    var write_bytes: [4]u8 = .{ 't', 'e', 's', 't' };
    var write_buffer = types.Buffer{ .bytes = &write_bytes };
    try write_buffer.setUsedLen(4);
    const write_id = try runtime_impl.submitStreamWrite(stream, write_buffer, null);

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buffer = types.Buffer{ .bytes = &read_bytes };
    const read_id = try runtime_impl.submitStreamRead(stream, read_buffer, null);

    _ = try runtime_impl.pump(8);
    const first = runtime_impl.poll().?;
    const second = runtime_impl.poll().?;
    try testing.expect(runtime_impl.poll() == null);
    try testing.expectEqual(write_id, first.operation_id);
    try testing.expectEqual(read_id, second.operation_id);
    try testing.expectEqualSlices(u8, "test", second.buffer.usedSlice());
}

test "runtime closeHandle is idempotent until recycled" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(2));
    defer runtime_impl.deinit();

    const file = try runtime_impl.openFile("runtime-close-handle.tmp", .{});
    try runtime_impl.closeHandle(file.handle);
    try testing.expectError(error.Closed, runtime_impl.closeHandle(file.handle));
}

test "runtime rejects wrong-kind and stale handles" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(1));
    defer runtime_impl.deinit();

    const file_a = try runtime_impl.openFile("runtime-stale-a.tmp", .{});
    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buffer = types.Buffer{ .bytes = &read_bytes };
    try testing.expectError(
        error.InvalidInput,
        runtime_impl.submitStreamRead(.{ .handle = file_a.handle }, read_buffer, null),
    );

    try runtime_impl.closeHandle(file_a.handle);
    _ = try runtime_impl.openFile("runtime-stale-b.tmp", .{});
    try testing.expectError(
        error.InvalidInput,
        runtime_impl.submitFileReadAt(file_a, read_buffer, 0, null),
    );
}

test "runtime closeHandle forces in-flight completion closed" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(4));
    defer runtime_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9001,
    } };
    _ = try runtime_impl.submitConnect(endpoint, null);
    _ = try runtime_impl.pump(1);
    const stream = types.Stream{ .handle = runtime_impl.poll().?.handle.? };

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buffer = types.Buffer{ .bytes = &read_bytes };
    const read_id = try runtime_impl.submitStreamRead(stream, read_buffer, null);
    try runtime_impl.closeHandle(stream.handle);

    _ = try runtime_impl.pump(1);
    const completion = runtime_impl.poll().?;
    try testing.expectEqual(read_id, completion.operation_id);
    try testing.expectEqual(types.CompletionStatus.closed, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .closed), completion.err);
    try testing.expectEqual(@as(u32, 0), completion.bytes_transferred);
}

test "runtime immediate timeout produces timeout completion" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(4));
    defer runtime_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9002,
    } };
    _ = try runtime_impl.submitConnect(endpoint, null);
    _ = try runtime_impl.pump(1);
    const stream = types.Stream{ .handle = runtime_impl.poll().?.handle.? };

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buffer = types.Buffer{ .bytes = &read_bytes };
    _ = try runtime_impl.submitStreamRead(stream, read_buffer, 0);

    _ = try runtime_impl.pump(1);
    const completion = runtime_impl.poll().?;
    try testing.expectEqual(types.CompletionStatus.timeout, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), completion.err);
}

test "runtime timeout_ns==0 yields immediate timeout for all operation kinds (windows backends)" {
    if (!io_caps.windowsBackendEnabled()) {
        return;
    }

    const backend_kinds = [_]config.BackendKind{ .threaded, .windows_iocp };
    inline for (backend_kinds) |backend_kind| {
        var cfg = config.Config.initForTest(32);
        cfg.backend_kind = backend_kind;
        cfg.threaded_worker_count = 2;

        var runtime_impl = try Runtime.init(testing.allocator, cfg);
        defer runtime_impl.deinit();

        const listener = try runtime_impl.listen(.{ .ipv4 = .{
            .address = .init(127, 0, 0, 1),
            .port = 0,
        } }, .{ .backlog = 16 });
        defer runtime_impl.closeHandle(listener.handle) catch {};

        const local = try runtime_impl.listenerLocalEndpoint(listener);
        const accept_id = try runtime_impl.submitAccept(listener, null);
        const connect_id = try runtime_impl.submitConnect(local, null);

        var server_stream: ?types.Stream = null;
        var client_stream: ?types.Stream = null;
        var attempts: u32 = 0;
        while (attempts < 8 and (server_stream == null or client_stream == null)) : (attempts += 1) {
            _ = try runtime_impl.wait(2, std.time.ns_per_s, null);
            while (runtime_impl.poll()) |completion| {
                if (completion.operation_id == accept_id and completion.status == .success) {
                    server_stream = .{ .handle = completion.handle.? };
                } else if (completion.operation_id == connect_id and completion.status == .success) {
                    client_stream = .{ .handle = completion.handle.? };
                }
            }
        }
        if (server_stream == null or client_stream == null) return error.SkipZigTest;
        defer runtime_impl.closeHandle(server_stream.?.handle) catch {};
        defer runtime_impl.closeHandle(client_stream.?.handle) catch {};

        const filename = if (backend_kind == .threaded)
            "static_io_timeout0_threaded.tmp"
        else
            "static_io_timeout0_iocp.tmp";
        defer deleteFileBestEffort(filename);

        const file = try runtime_impl.openFile(filename, .{
            .read = true,
            .write = true,
            .create = true,
            .truncate = true,
        });
        defer runtime_impl.closeHandle(file.handle) catch {};

        var write_one: [1]u8 = .{'x'};
        var write_buf = types.Buffer{ .bytes = &write_one };
        try write_buf.setUsedLen(1);

        var read_one: [1]u8 = [_]u8{0};
        const read_buf = types.Buffer{ .bytes = &read_one };

        var file_read_bytes: [8]u8 = [_]u8{0} ** 8;
        const file_read_buf = types.Buffer{ .bytes = &file_read_bytes };

        var file_write_bytes: [1]u8 = .{'y'};
        var file_write_buf = types.Buffer{ .bytes = &file_write_bytes };
        try file_write_buf.setUsedLen(1);

        const read_id = try runtime_impl.submitStreamRead(server_stream.?, read_buf, 0);
        _ = try runtime_impl.wait(1, std.time.ns_per_s, null);
        const read_completion = runtime_impl.poll() orelse return error.SkipZigTest;
        try testing.expectEqual(read_id, read_completion.operation_id);
        try testing.expectEqual(types.OperationTag.stream_read, read_completion.tag);
        try testing.expectEqual(types.CompletionStatus.timeout, read_completion.status);
        try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), read_completion.err);
        try testing.expectEqual(@as(u32, 0), read_completion.bytes_transferred);

        const write_id = try runtime_impl.submitStreamWrite(client_stream.?, write_buf, 0);
        _ = try runtime_impl.wait(1, std.time.ns_per_s, null);
        const write_completion = runtime_impl.poll() orelse return error.SkipZigTest;
        try testing.expectEqual(write_id, write_completion.operation_id);
        try testing.expectEqual(types.OperationTag.stream_write, write_completion.tag);
        try testing.expectEqual(types.CompletionStatus.timeout, write_completion.status);
        try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), write_completion.err);
        try testing.expectEqual(@as(u32, 0), write_completion.bytes_transferred);

        const accept_timeout_id = try runtime_impl.submitAccept(listener, 0);
        _ = try runtime_impl.wait(1, std.time.ns_per_s, null);
        const accept_timeout_completion = runtime_impl.poll() orelse return error.SkipZigTest;
        try testing.expectEqual(accept_timeout_id, accept_timeout_completion.operation_id);
        try testing.expectEqual(types.OperationTag.accept, accept_timeout_completion.tag);
        try testing.expectEqual(types.CompletionStatus.timeout, accept_timeout_completion.status);
        try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), accept_timeout_completion.err);
        try testing.expectEqual(@as(u32, 0), accept_timeout_completion.bytes_transferred);
        try testing.expectEqual(@as(?types.Handle, null), accept_timeout_completion.handle);

        const connect_timeout_id = try runtime_impl.submitConnect(local, 0);
        _ = try runtime_impl.wait(1, std.time.ns_per_s, null);
        const connect_timeout_completion = runtime_impl.poll() orelse return error.SkipZigTest;
        try testing.expectEqual(connect_timeout_id, connect_timeout_completion.operation_id);
        try testing.expectEqual(types.OperationTag.connect, connect_timeout_completion.tag);
        try testing.expectEqual(types.CompletionStatus.timeout, connect_timeout_completion.status);
        try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), connect_timeout_completion.err);
        try testing.expectEqual(@as(u32, 0), connect_timeout_completion.bytes_transferred);
        try testing.expectEqual(@as(?types.Handle, null), connect_timeout_completion.handle);

        const file_read_id = try runtime_impl.submitFileReadAt(file, file_read_buf, 0, 0);
        _ = try runtime_impl.wait(1, std.time.ns_per_s, null);
        const file_read_completion = runtime_impl.poll() orelse return error.SkipZigTest;
        try testing.expectEqual(file_read_id, file_read_completion.operation_id);
        try testing.expectEqual(types.OperationTag.file_read_at, file_read_completion.tag);
        try testing.expectEqual(types.CompletionStatus.timeout, file_read_completion.status);
        try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), file_read_completion.err);
        try testing.expectEqual(@as(u32, 0), file_read_completion.bytes_transferred);

        const file_write_id = try runtime_impl.submitFileWriteAt(file, file_write_buf, 0, 0);
        _ = try runtime_impl.wait(1, std.time.ns_per_s, null);
        const file_write_completion = runtime_impl.poll() orelse return error.SkipZigTest;
        try testing.expectEqual(file_write_id, file_write_completion.operation_id);
        try testing.expectEqual(types.OperationTag.file_write_at, file_write_completion.tag);
        try testing.expectEqual(types.CompletionStatus.timeout, file_write_completion.status);
        try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), file_write_completion.err);
        try testing.expectEqual(@as(u32, 0), file_write_completion.bytes_transferred);

        try testing.expect(runtime_impl.poll() == null);
    }
}

test "runtime rejects empty stream buffers to preserve EOF semantics" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(2));
    defer runtime_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9010,
    } };
    _ = try runtime_impl.submitConnect(endpoint, null);
    _ = try runtime_impl.pump(1);
    const stream = types.Stream{ .handle = runtime_impl.poll().?.handle.? };

    const empty = types.Buffer{ .bytes = &[_]u8{} };
    try testing.expectError(error.InvalidInput, runtime_impl.submitStreamRead(stream, empty, null));
    try testing.expectError(error.InvalidInput, runtime_impl.submitStreamWrite(stream, empty, null));

    var zero_bytes: [1]u8 = .{0};
    const zero_write = types.Buffer{ .bytes = &zero_bytes };
    try testing.expectError(error.InvalidInput, runtime_impl.submitStreamWrite(stream, zero_write, null));

    const file = try runtime_impl.openFile("runtime-empty-write.tmp", .{ .read = true, .write = true, .create = true });
    try testing.expectError(error.InvalidInput, runtime_impl.submitFileWriteAt(file, zero_write, 0, null));
}

test "runtime rejects read buffers with non-zero used_len" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(4));
    defer runtime_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9020,
    } };
    _ = try runtime_impl.submitConnect(endpoint, null);
    _ = try runtime_impl.pump(1);
    const stream = types.Stream{ .handle = runtime_impl.poll().?.handle.? };

    var bytes: [8]u8 = [_]u8{0} ** 8;
    var buffer = types.Buffer{ .bytes = &bytes };
    try buffer.setUsedLen(1);
    try testing.expectError(error.InvalidInput, runtime_impl.submitStreamRead(stream, buffer, null));

    const file = try runtime_impl.openFile("runtime-read-usedlen.tmp", .{ .read = true, .write = true, .create = true });
    try testing.expectError(error.InvalidInput, runtime_impl.submitFileReadAt(file, buffer, 0, null));
}

test "runtime returns WouldBlock on max_in_flight exhaustion" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(1));
    defer runtime_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9030,
    } };
    _ = try runtime_impl.submitConnect(endpoint, null);
    _ = try runtime_impl.pump(1);
    const stream = types.Stream{ .handle = runtime_impl.poll().?.handle.? };

    var storage_a: [8]u8 = [_]u8{0} ** 8;
    const buffer_a = types.Buffer{ .bytes = &storage_a };
    _ = try runtime_impl.submitStreamRead(stream, buffer_a, null);

    var storage_b: [8]u8 = [_]u8{0} ** 8;
    const buffer_b = types.Buffer{ .bytes = &storage_b };
    try testing.expectError(error.WouldBlock, runtime_impl.submitStreamRead(stream, buffer_b, null));
}

test "runtime file_read_at permits empty buffer as no-op" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(2));
    defer runtime_impl.deinit();

    const file = try runtime_impl.openFile("runtime-empty-read.tmp", .{ .read = true, .write = true, .create = true });

    const empty = types.Buffer{ .bytes = &[_]u8{} };
    const read_id = try runtime_impl.submitFileReadAt(file, empty, 0, null);

    _ = try runtime_impl.pump(1);
    const completion = runtime_impl.poll().?;
    try testing.expectEqual(read_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.file_read_at, completion.tag);
    try testing.expectEqual(types.CompletionStatus.success, completion.status);
    try testing.expectEqual(@as(u32, 0), completion.bytes_transferred);
    try testing.expectEqual(@as(usize, 0), completion.buffer.used_len);
}

test "runtime cancel returns NotFound for unknown and completed operations" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(2));
    defer runtime_impl.deinit();

    try testing.expectError(error.NotFound, runtime_impl.cancel(123456));

    var storage: [8]u8 = [_]u8{0} ** 8;
    const buffer = types.Buffer{ .bytes = &storage };
    const id = try runtime_impl.submit(.{ .nop = buffer });
    _ = try runtime_impl.pump(1);

    // Once an operation has completed (even if it has not yet been polled),
    // cancellation no longer applies.
    try testing.expectError(error.NotFound, runtime_impl.cancel(id));
}

fn connectLoopbackPair(runtime_impl: *Runtime) !struct {
    listener: types.Listener,
    server: types.Stream,
    client: types.Stream,
} {
    const listener = try runtime_impl.listen(.{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = 0 } }, .{});
    const bound = try runtime_impl.listenerLocalEndpoint(listener);

    const accept_id = try runtime_impl.submitAccept(listener, null);
    const connect_id = try runtime_impl.submitConnect(bound, null);

    const deadline_ns: u64 = 5 * std.time.ns_per_s;
    const start = core.time_compat.Instant.now() catch return error.SkipZigTest;

    var server: ?types.Stream = null;
    var client: ?types.Stream = null;

    while (server == null or client == null) {
        const elapsed_ns = (core.time_compat.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed_ns >= deadline_ns) return error.Timeout;

        _ = runtime_impl.wait(2, 50 * std.time.ns_per_ms, null) catch |err| switch (err) {
            error.Timeout => 0,
            else => return err,
        };
        while (runtime_impl.poll()) |completion| {
            switch (completion.tag) {
                .accept => {
                    try testing.expectEqual(accept_id, completion.operation_id);
                    try testing.expectEqual(types.CompletionStatus.success, completion.status);
                    server = .{ .handle = completion.handle.? };
                },
                .connect => {
                    try testing.expectEqual(connect_id, completion.operation_id);
                    try testing.expectEqual(types.CompletionStatus.success, completion.status);
                    client = .{ .handle = completion.handle.? };
                },
                else => {},
            }
        }
    }

    return .{
        .listener = listener,
        .server = server.?,
        .client = client.?,
    };
}

test "runtime windows iocp cancel/close/timeout semantics are best-effort but stable" {
    if (!io_caps.windowsBackendEnabled()) {
        return;
    }

    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .windows_iocp;
    var runtime_impl = try Runtime.init(testing.allocator, cfg);
    defer runtime_impl.deinit();

    const pair = try connectLoopbackPair(&runtime_impl);
    defer runtime_impl.closeHandle(pair.client.handle) catch {};
    defer runtime_impl.closeHandle(pair.server.handle) catch {};
    defer runtime_impl.closeHandle(pair.listener.handle) catch {};

    // Cancel: if the op is in-flight and cancellation wins, the completion is cancelled.
    var read_storage: [8]u8 = [_]u8{0} ** 8;
    const read_buffer = types.Buffer{ .bytes = &read_storage };
    const read_id = try runtime_impl.submitStreamRead(pair.server, read_buffer, null);
    try runtime_impl.cancel(read_id);
    _ = try runtime_impl.wait(1, 2 * std.time.ns_per_s, null);
    const cancelled_completion = runtime_impl.poll().?;
    try testing.expectEqual(read_id, cancelled_completion.operation_id);
    try testing.expectEqual(types.CompletionStatus.cancelled, cancelled_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .cancelled), cancelled_completion.err);
    try testing.expectEqual(@as(u32, 0), cancelled_completion.bytes_transferred);
    try testing.expectEqual(@as(usize, 0), cancelled_completion.buffer.used_len);

    // Close: closing a handle attempts to cancel in-flight operations as `.closed`.
    const close_id = try runtime_impl.submitStreamRead(pair.server, read_buffer, null);
    try runtime_impl.closeHandle(pair.server.handle);
    _ = try runtime_impl.wait(1, 2 * std.time.ns_per_s, null);
    const closed_completion = runtime_impl.poll().?;
    try testing.expectEqual(close_id, closed_completion.operation_id);
    try testing.expectEqual(types.CompletionStatus.closed, closed_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .closed), closed_completion.err);
    try testing.expectEqual(@as(u32, 0), closed_completion.bytes_transferred);
    try testing.expectEqual(@as(usize, 0), closed_completion.buffer.used_len);

    // Timeout: idle reads complete as `.timeout`, not EOF.
    // Re-open a fresh pair because we closed the server stream above.
    var runtime_impl2 = try Runtime.init(testing.allocator, cfg);
    defer runtime_impl2.deinit();
    const pair2 = try connectLoopbackPair(&runtime_impl2);
    defer runtime_impl2.closeHandle(pair2.client.handle) catch {};
    defer runtime_impl2.closeHandle(pair2.server.handle) catch {};
    defer runtime_impl2.closeHandle(pair2.listener.handle) catch {};

    const timeout_id = try runtime_impl2.submitStreamRead(pair2.server, read_buffer, 100 * std.time.ns_per_ms);
    _ = try runtime_impl2.wait(1, 2 * std.time.ns_per_s, null);
    const timeout_completion = runtime_impl2.poll().?;
    try testing.expectEqual(timeout_id, timeout_completion.operation_id);
    try testing.expectEqual(types.CompletionStatus.timeout, timeout_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), timeout_completion.err);
    try testing.expectEqual(@as(u32, 0), timeout_completion.bytes_transferred);
    try testing.expectEqual(@as(usize, 0), timeout_completion.buffer.used_len);
}

test "runtime windows iocp accept immediate timeout does not leak stream handles" {
    if (!io_caps.windowsBackendEnabled()) {
        return;
    }

    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .windows_iocp;
    var runtime_impl = try Runtime.init(testing.allocator, cfg);
    defer runtime_impl.deinit();

    const listener = try runtime_impl.listen(.{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = 0 } }, .{});
    defer runtime_impl.closeHandle(listener.handle) catch {};

    var iteration: usize = 0;
    while (iteration < 8) : (iteration += 1) {
        const accept_id = try runtime_impl.submitAccept(listener, 0);
        const pumped = try runtime_impl.pump(4);
        try testing.expect(pumped >= 1);

        const completion = runtime_impl.poll().?;
        try testing.expectEqual(accept_id, completion.operation_id);
        try testing.expectEqual(types.OperationTag.accept, completion.tag);
        try testing.expectEqual(types.CompletionStatus.timeout, completion.status);
        try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), completion.err);
        try testing.expect(completion.handle == null);
    }
}

test "runtime openFile maps OS errors to stable control-plane errors" {
    if (!io_caps.threadedBackendEnabled()) {
        return;
    }

    var cfg = config.Config.initForTest(4);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 1;
    var runtime_impl = try Runtime.init(testing.allocator, cfg);
    defer runtime_impl.deinit();

    const missing_path = "static_io_missing_open.tmp";
    deleteFileBestEffort(missing_path);
    try testing.expectError(error.NotFound, runtime_impl.openFile(missing_path, .{ .read = true }));

    const existing_path = "static_io_existing_open.tmp";
    deleteFileBestEffort(existing_path);
    const created = try runtime_impl.openFile(existing_path, .{ .read = true, .write = true, .create = true, .truncate = true });
    try runtime_impl.closeHandle(created.handle);
    defer deleteFileBestEffort(existing_path);

    try testing.expectError(error.AlreadyExists, runtime_impl.openFile(existing_path, .{
        .read = true,
        .write = true,
        .create = true,
        .exclusive = true,
    }));
}

fn deleteFileBestEffort(path: []const u8) void {
    if (builtin.os.tag == .windows) {
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, path) catch return;
        defer testing.allocator.free(path_w);
        _ = windows_platform.DeleteFileW(path_w.ptr);
        return;
    }

    const allocator = testing.allocator;
    const path_z = allocator.alloc(u8, path.len + 1) catch return;
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    _ = std.posix.system.unlink(path_z[0..path.len :0].ptr);
}

test "runtime listen maps OS errors to stable control-plane errors" {
    if (!io_caps.threadedBackendEnabled()) {
        return;
    }

    var cfg = config.Config.initForTest(4);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 1;
    var runtime_impl = try Runtime.init(testing.allocator, cfg);
    defer runtime_impl.deinit();

    const endpoint_any = types.Endpoint{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = 0 } };
    const listener = try runtime_impl.listen(endpoint_any, .{});
    defer runtime_impl.closeHandle(listener.handle) catch {};

    const bound = try runtime_impl.listenerLocalEndpoint(listener);
    switch (bound) {
        .ipv4 => |ipv4| try testing.expect(ipv4.port != 0),
        .ipv6 => |ipv6| try testing.expect(ipv6.port != 0),
    }

    try testing.expectError(error.AddressInUse, runtime_impl.listen(bound, .{}));
}

test "runtime adopt APIs follow build-option gating" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(2));
    defer runtime_impl.deinit();

    if (!io_caps.os_backends_enabled) {
        try testing.expectError(error.Unsupported, runtime_impl.adoptFile(1, .owned));
        return;
    }

    const adopted = try runtime_impl.adoptFile(1, .owned);
    try runtime_impl.closeHandle(adopted.handle);
}

test "runtime wait supports timeout and cancellation" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(2));
    defer runtime_impl.deinit();

    try testing.expectError(error.Timeout, runtime_impl.wait(1, 0, null));

    var cancel_source = static_sync.cancel.CancelSource{};
    cancel_source.cancel();
    try testing.expectError(error.Cancelled, runtime_impl.wait(1, null, cancel_source.token()));
}

test "runtime capabilities include typed operation support" {
    var runtime_impl = try Runtime.init(testing.allocator, config.Config.initForTest(2));
    defer runtime_impl.deinit();

    const caps = runtime_impl.capabilities();
    try testing.expect(caps.supports_nop);
    try testing.expect(caps.supports_fill);
    try testing.expect(caps.supports_stream_read);
    try testing.expect(caps.supports_stream_write);
    try testing.expect(caps.supports_file_read_at);
    try testing.expect(caps.supports_file_write_at);
}

test "runtime backend kind gating matches host support" {
    var cfg = config.Config.initForTest(2);
    cfg.threaded_worker_count = 1;

    const kinds = [_]config.BackendKind{
        .platform,
        .windows_iocp,
        .linux_io_uring,
        .bsd_kqueue,
    };

    inline for (kinds) |kind| {
        cfg.backend_kind = kind;
        const expected_supported = switch (kind) {
            .platform => io_caps.platformBackendEnabled(builtin.os.tag),
            .windows_iocp => io_caps.windowsBackendEnabled(),
            .linux_io_uring => io_caps.linuxBackendEnabled(),
            .bsd_kqueue => io_caps.bsdBackendEnabled(builtin.os.tag),
            else => false,
        };

        if (expected_supported) {
            var runtime_impl = try Runtime.init(testing.allocator, cfg);
            runtime_impl.deinit();
        } else {
            try testing.expectError(error.Unsupported, Runtime.init(testing.allocator, cfg));
        }
    }
}

test "runtime wait uses backend blocking path on windows iocp" {
    if (!io_caps.windowsBackendEnabled()) {
        return;
    }

    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .windows_iocp;
    var runtime_impl = try Runtime.init(testing.allocator, cfg);
    defer runtime_impl.deinit();

    var storage: [8]u8 = [_]u8{0} ** 8;
    const buffer = types.Buffer{ .bytes = &storage };

    _ = try runtime_impl.submit(.{ .fill = .{
        .buffer = buffer,
        .len = 4,
        .byte = 0x33,
    } });
    const waited_count = try runtime_impl.wait(1, 1_000_000_000, null);
    try testing.expect(waited_count >= 1);

    const completion = runtime_impl.poll().?;
    try testing.expectEqual(types.CompletionStatus.success, completion.status);
    try testing.expectEqual(@as(u8, 0x33), completion.buffer.bytes[0]);
}

test "runtime wait cancellation wakes windows iocp backend wait" {
    if (!io_caps.windowsBackendEnabled()) {
        return;
    }

    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .windows_iocp;
    var runtime_impl = try Runtime.init(testing.allocator, cfg);
    defer runtime_impl.deinit();

    var cancel_source = static_sync.cancel.CancelSource{};

    const cancel_delay_ns: u64 = 50 * std.time.ns_per_ms;
    const timeout_ns: u64 = 2 * std.time.ns_per_s;

    const CancelCtx = struct {
        src: *static_sync.cancel.CancelSource,
        delay_ns: u64,

        pub fn run(ctx: *@This()) void {
            const delay_ms_u64 = ctx.delay_ns / std.time.ns_per_ms;
            const delay_ms: windows.DWORD = @intCast(@max(@as(u64, 1), delay_ms_u64));
            _ = windows.kernel32.SleepEx(delay_ms, windows.FALSE);
            ctx.src.cancel();
        }
    };

    var cancel_ctx = CancelCtx{
        .src = &cancel_source,
        .delay_ns = cancel_delay_ns,
    };
    const canceller = try std.Thread.spawn(.{}, CancelCtx.run, .{&cancel_ctx});
    defer canceller.join();

    const start = core.time_compat.Instant.now() catch return;
    try testing.expectError(error.Cancelled, runtime_impl.wait(1, timeout_ns, cancel_source.token()));
    const elapsed_ns = (core.time_compat.Instant.now() catch return).since(start);
    try testing.expect(elapsed_ns >= cancel_delay_ns / 2);
    try testing.expect(elapsed_ns < timeout_ns / 2);
}

test "runtime wait cancellation wakes threaded backend wait" {
    if (!io_caps.threadedBackendEnabled()) {
        return;
    }

    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .threaded;
    var runtime_impl = try Runtime.init(testing.allocator, cfg);
    defer runtime_impl.deinit();

    var cancel_source = static_sync.cancel.CancelSource{};

    const cancel_delay_ns: u64 = 50 * std.time.ns_per_ms;
    const timeout_ns: u64 = 2 * std.time.ns_per_s;

    const CancelCtx = struct {
        src: *static_sync.cancel.CancelSource,
        delay_ns: u64,

        pub fn run(ctx: *@This()) void {
            const start = core.time_compat.Instant.now() catch return;
            while (true) {
                const elapsed_ns = (core.time_compat.Instant.now() catch return).since(start);
                if (elapsed_ns >= ctx.delay_ns) break;
                std.Thread.yield() catch {};
            }
            ctx.src.cancel();
        }
    };

    var cancel_ctx = CancelCtx{
        .src = &cancel_source,
        .delay_ns = cancel_delay_ns,
    };
    const canceller = try std.Thread.spawn(.{}, CancelCtx.run, .{&cancel_ctx});
    defer canceller.join();

    const start = core.time_compat.Instant.now() catch return;
    try testing.expectError(error.Cancelled, runtime_impl.wait(1, timeout_ns, cancel_source.token()));
    const elapsed_ns = (core.time_compat.Instant.now() catch return).since(start);
    try testing.expect(elapsed_ns >= cancel_delay_ns / 2);
    try testing.expect(elapsed_ns < timeout_ns / 2);
}

test "runtime wait cancellation wakes linux io_uring backend wait" {
    if (!io_caps.linuxBackendEnabled()) {
        return;
    }

    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .linux_io_uring;
    var runtime_impl = Runtime.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer runtime_impl.deinit();

    var cancel_source = static_sync.cancel.CancelSource{};

    const cancel_delay_ns: u64 = 50 * std.time.ns_per_ms;
    const timeout_ns: u64 = 2 * std.time.ns_per_s;

    const CancelCtx = struct {
        src: *static_sync.cancel.CancelSource,
        delay_ns: u64,

        pub fn run(ctx: *@This()) void {
            const start = core.time_compat.Instant.now() catch return;
            while (true) {
                const elapsed_ns = (core.time_compat.Instant.now() catch return).since(start);
                if (elapsed_ns >= ctx.delay_ns) break;
                std.Thread.yield() catch {};
            }
            ctx.src.cancel();
        }
    };

    var cancel_ctx = CancelCtx{
        .src = &cancel_source,
        .delay_ns = cancel_delay_ns,
    };
    const canceller = try std.Thread.spawn(.{}, CancelCtx.run, .{&cancel_ctx});
    defer canceller.join();

    const start = core.time_compat.Instant.now() catch return error.SkipZigTest;
    try testing.expectError(error.Cancelled, runtime_impl.wait(1, timeout_ns, cancel_source.token()));
    const elapsed_ns = (core.time_compat.Instant.now() catch return error.SkipZigTest).since(start);
    try testing.expect(elapsed_ns >= cancel_delay_ns / 2);
    try testing.expect(elapsed_ns < timeout_ns / 2);
}

test "runtime wait cancellation wakes bsd kqueue backend wait" {
    if (!io_caps.bsdBackendEnabled(builtin.os.tag)) {
        return;
    }

    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .bsd_kqueue;
    var runtime_impl = Runtime.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer runtime_impl.deinit();

    var cancel_source = static_sync.cancel.CancelSource{};

    const cancel_delay_ns: u64 = 50 * std.time.ns_per_ms;
    const timeout_ns: u64 = 2 * std.time.ns_per_s;

    const CancelCtx = struct {
        src: *static_sync.cancel.CancelSource,
        delay_ns: u64,

        pub fn run(ctx: *@This()) void {
            const start = core.time_compat.Instant.now() catch return;
            while (true) {
                const elapsed_ns = (core.time_compat.Instant.now() catch return).since(start);
                if (elapsed_ns >= ctx.delay_ns) break;
                std.Thread.yield() catch {};
            }
            ctx.src.cancel();
        }
    };

    var cancel_ctx = CancelCtx{
        .src = &cancel_source,
        .delay_ns = cancel_delay_ns,
    };
    const canceller = try std.Thread.spawn(.{}, CancelCtx.run, .{&cancel_ctx});
    defer canceller.join();

    const start = core.time_compat.Instant.now() catch return error.SkipZigTest;
    try testing.expectError(error.Cancelled, runtime_impl.wait(1, timeout_ns, cancel_source.token()));
    const elapsed_ns = (core.time_compat.Instant.now() catch return error.SkipZigTest).since(start);
    try testing.expect(elapsed_ns >= cancel_delay_ns / 2);
    try testing.expect(elapsed_ns < timeout_ns / 2);
}
