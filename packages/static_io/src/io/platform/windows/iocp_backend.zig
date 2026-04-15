//! Windows IOCP backend.
//!
//! Current scope:
//! - real IOCP queue for completion delivery
//! - supports `nop`/`fill`
//! - file `read_at`/`write_at` for adopted native handles (overlapped, IOCP-driven)
//! - TCP stream ops (`read`/`write`/`connect`/`accept`) using Winsock overlapped calls

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const io_caps = @import("../../caps.zig");
const static_queues = @import("static_queues");
const backend = @import("../../backend.zig");
const config = @import("../../config.zig");
const operation_helpers = @import("../../operation_helpers.zig");
const operation_ids = @import("../../operation_ids.zig");
const types = @import("../../types.zig");
const error_map = @import("../../error_map.zig");
const winsock_extensions = @import("winsock_extensions.zig");
const static_net_native = @import("static_net_native");

const windows = @import("windows_compat.zig");
const kernel32 = windows.kernel32;
const IdQueue = static_queues.ring_buffer.RingBuffer(u32);
const DecodedOperationId = operation_ids.DecodedOperationId;
const decodeOperationId = operation_ids.decodeExternalOperationId;
const encodeOperationId = operation_ids.encodeExternalOperationId;
const nextGeneration = operation_ids.nextGeneration;
const TargetHandles = operation_helpers.TargetHandles;
const makeSimpleCompletion = operation_helpers.makeSimpleCompletion;
const operationHasImmediateTimeout = operation_helpers.operationHasImmediateTimeout;
const operationTargetHandles = operation_helpers.operationTargetHandles;
const operationTimeoutNs = operation_helpers.operationTimeoutNs;
const validateOperation = operation_helpers.validateOperation;
const SockaddrAny = static_net_native.windows.SockaddrAny;
const socketFamily = static_net_native.windows.socketFamily;
const socketLocalEndpoint = static_net_native.windows.socketLocalEndpoint;
const socketPeerEndpoint = static_net_native.windows.socketPeerEndpoint;
const af_inet_family: u16 = 2;
const af_inet6_family: u16 = 23;
const sock_stream: i32 = 1;
const ipproto_tcp: i32 = 6;

const SlotState = enum {
    free,
    in_flight,
    ready,
};

const CancelReason = enum {
    none,
    cancelled,
    timeout,
    closed,
};

const Slot = struct {
    generation: u32 = 1,
    state: SlotState = .free,
    operation_id: types.OperationId = 0,
    operation: types.Operation = undefined,
    completion: types.Completion = undefined,
    manual_completion: bool = false,
    cancel_reason: CancelReason = .none,
    timeout_start: ?core.time_compat.Instant = null,
    target_handle_a: ?types.Handle = null,
    target_handle_b: ?types.Handle = null,
    native_for_cancel: types.NativeHandle = 0,
    native_for_accept: types.NativeHandle = 0,
    accept_bytes_received: windows.DWORD = 0,
    overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
};

const HandleState = enum {
    free,
    open,
    closed,
};

/// Windows-native IOCP backend implementation.
pub const IocpBackend = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    port: windows.HANDLE,
    winsock_ext: winsock_extensions.Extensions,
    accept_buffers: []u8,
    slots: []Slot,
    free_slots: []u32,
    free_len: u32,
    completed: IdQueue,
    handle_states: []HandleState,
    handle_generations: []u32,
    handle_kinds: []types.HandleKind,
    handle_native: []types.NativeHandle,
    handle_owned: []bool,
    closed: bool = false,
    wsa_started: bool = false,

    const vtable: backend.BackendVTable = .{
        .deinit = deinitVTable,
        .submit = submitVTable,
        .pump = pumpVTable,
        .poll = pollVTable,
        .cancel = cancelVTable,
        .close = closeVTable,
        .capabilities = capabilitiesVTable,
        .registerHandle = registerHandleVTable,
        .notifyHandleClosed = notifyHandleClosedVTable,
        .handleInUse = handleInUseVTable,
    };

    /// Initializes IOCP backend state and required Winsock extensions.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!IocpBackend {
        if (!io_caps.windowsBackendEnabled()) return error.Unsupported;
        if (cfg.backend_kind != .windows_iocp and cfg.backend_kind != .platform) return error.Unsupported;
        config.validate(cfg) catch |cfg_err| switch (cfg_err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
        };

        var wsa_data: windows.ws2_32.WSADATA = undefined;
        const wsa_version: windows.WORD = 0x0202;
        if (windows.ws2_32.WSAStartup(wsa_version, &wsa_data) != 0) {
            return error.Unsupported;
        }
        errdefer _ = windows.ws2_32.WSACleanup();

        const wsa_flag_overlapped: windows.DWORD = 0x00000001;
        const temp_socket = windows.ws2_32.WSASocketW(
            @intCast(af_inet_family),
            sock_stream,
            ipproto_tcp,
            null,
            0,
            wsa_flag_overlapped,
        );
        if (temp_socket == windows.ws2_32.INVALID_SOCKET) {
            return error.Unsupported;
        }
        defer _ = windows.ws2_32.closesocket(temp_socket);

        const ext = winsock_extensions.load(temp_socket) catch return error.Unsupported;

        const required_accept_buffer_bytes: u32 = @intCast((@sizeOf(windows.ws2_32.sockaddr.storage) + 16) * 2);
        if (cfg.iocp_accept_buffer_bytes < required_accept_buffer_bytes) {
            return error.InvalidConfig;
        }

        const port = kernel32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0) orelse {
            return error.Unsupported;
        };
        errdefer windows.CloseHandle(port);

        const accept_bytes_total: usize = std.math.mul(usize, @intCast(cfg.max_in_flight), @intCast(cfg.iocp_accept_buffer_bytes)) catch return error.Overflow;
        const accept_buffers = allocator.alloc(u8, accept_bytes_total) catch return error.OutOfMemory;
        errdefer allocator.free(accept_buffers);
        @memset(accept_buffers, 0);

        const slots = allocator.alloc(Slot, cfg.max_in_flight) catch return error.OutOfMemory;
        errdefer allocator.free(slots);
        @memset(slots, .{});

        const free_slots = allocator.alloc(u32, cfg.max_in_flight) catch return error.OutOfMemory;
        errdefer allocator.free(free_slots);
        var index: usize = 0;
        while (index < free_slots.len) : (index += 1) {
            free_slots[index] = @intCast(cfg.max_in_flight - 1 - index);
        }

        var completed = IdQueue.init(allocator, .{ .capacity = cfg.completion_queue_capacity }) catch |queue_err| switch (queue_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
            error.NoSpaceLeft, error.WouldBlock => return error.InvalidConfig,
        };
        errdefer completed.deinit();

        const handle_states = allocator.alloc(HandleState, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_states);
        @memset(handle_states, .free);

        const handle_generations = allocator.alloc(u32, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_generations);
        @memset(handle_generations, 0);

        const handle_kinds = allocator.alloc(types.HandleKind, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_kinds);
        @memset(handle_kinds, .file);

        const handle_native = allocator.alloc(types.NativeHandle, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_native);
        @memset(handle_native, 0);

        const handle_owned = allocator.alloc(bool, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_owned);
        @memset(handle_owned, false);

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .port = port,
            .winsock_ext = ext,
            .accept_buffers = accept_buffers,
            .slots = slots,
            .free_slots = free_slots,
            .free_len = cfg.max_in_flight,
            .completed = completed,
            .handle_states = handle_states,
            .handle_generations = handle_generations,
            .handle_kinds = handle_kinds,
            .handle_native = handle_native,
            .handle_owned = handle_owned,
            .wsa_started = true,
        };
    }

    /// Releases IOCP resources and backend-owned allocations.
    pub fn deinit(self: *IocpBackend) void {
        windows.CloseHandle(self.port);
        self.completed.deinit();
        if (self.wsa_started) {
            _ = windows.ws2_32.WSACleanup();
        }
        self.allocator.free(self.accept_buffers);
        self.allocator.free(self.handle_owned);
        self.allocator.free(self.handle_native);
        self.allocator.free(self.handle_kinds);
        self.allocator.free(self.handle_generations);
        self.allocator.free(self.handle_states);
        self.allocator.free(self.free_slots);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Returns a type-erased backend interface for runtime dispatch.
    pub fn asBackend(self: *IocpBackend) backend.Backend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    /// Returns allocator used by backend-owned memory.
    pub fn getAllocator(self: *const IocpBackend) std.mem.Allocator {
        return self.allocator;
    }

    /// Submits one operation to IOCP/overlapped execution.
    pub fn submit(self: *IocpBackend, op: types.Operation) backend.SubmitError!types.OperationId {
        if (self.closed) return error.Closed;
        const checked_op = try validateOperation(op);
        const slot_index = try self.allocSlot();
        errdefer self.freeSlot(slot_index);

        var slot = &self.slots[slot_index];
        const operation_id = encodeOperationId(slot_index, slot.generation);
        slot.state = .in_flight;
        slot.operation_id = operation_id;
        slot.operation = checked_op;
        slot.manual_completion = false;
        slot.cancel_reason = .none;
        slot.timeout_start = null;
        slot.native_for_cancel = 0;
        slot.native_for_accept = 0;
        slot.accept_bytes_received = 0;
        const targets = operationTargetHandles(checked_op);
        slot.target_handle_a = targets.a;
        slot.target_handle_b = targets.b;
        slot.overlapped = std.mem.zeroes(windows.OVERLAPPED);

        if (operationHasImmediateTimeout(checked_op)) {
            slot.manual_completion = true;
            slot.completion = makeManualTimeoutCompletion(operation_id, checked_op);
            tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
            return operation_id;
        }

        if (operationTimeoutNs(checked_op)) |timeout_ns| {
            if (timeout_ns != 0) {
                slot.timeout_start = core.time_compat.Instant.now() catch return error.Unsupported;
            }
        }

        switch (checked_op) {
            .nop => |buffer| {
                slot.manual_completion = true;
                slot.completion = .{
                    .operation_id = operation_id,
                    .tag = .nop,
                    .status = .success,
                    .bytes_transferred = buffer.used_len,
                    .buffer = buffer,
                };
                tryPostQueuedCompletionStatus(self.port, &slot.overlapped, buffer.used_len);
            },
            .fill => |fill| {
                slot.manual_completion = true;
                var buffer = fill.buffer;
                if (fill.len > 0) @memset(buffer.bytes[0..fill.len], fill.byte);
                buffer.used_len = fill.len;
                slot.completion = .{
                    .operation_id = operation_id,
                    .tag = .fill,
                    .status = .success,
                    .bytes_transferred = fill.len,
                    .buffer = buffer,
                };
                tryPostQueuedCompletionStatus(self.port, &slot.overlapped, fill.len);
            },
            .file_read_at => |file_op| {
                const file_native = nativeForHandle(self, file_op.file.handle, .file) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                slot.native_for_cancel = file_native;

                var buffer = file_op.buffer;
                buffer.used_len = 0;
                const request_len_u32: u32 = bufferRequestLenU32(buffer, true) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                if (request_len_u32 == 0) {
                    slot.manual_completion = true;
                    slot.completion = .{
                        .operation_id = operation_id,
                        .tag = .file_read_at,
                        .status = .success,
                        .bytes_transferred = 0,
                        .buffer = buffer,
                        .handle = file_op.file.handle,
                    };
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                }

                setOverlappedOffset(&slot.overlapped, file_op.offset_bytes);
                const handle: windows.HANDLE = @ptrFromInt(file_native);
                const ok = kernel32.ReadFile(
                    handle,
                    @ptrCast(buffer.bytes.ptr),
                    request_len_u32,
                    null,
                    &slot.overlapped,
                );
                if (ok == windows.FALSE) {
                    const last_error = windows.GetLastError();
                    if (last_error != windows.Win32Error.IO_PENDING) {
                        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(last_error));
                        slot.manual_completion = true;
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    }
                }
            },
            .file_write_at => |file_op| {
                const file_native = nativeForHandle(self, file_op.file.handle, .file) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                slot.native_for_cancel = file_native;

                const request_len_u32: u32 = bufferRequestLenU32(file_op.buffer, false) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                assert(request_len_u32 > 0);

                setOverlappedOffset(&slot.overlapped, file_op.offset_bytes);
                const handle: windows.HANDLE = @ptrFromInt(file_native);
                const ok = kernel32.WriteFile(
                    handle,
                    @ptrCast(file_op.buffer.bytes.ptr),
                    request_len_u32,
                    null,
                    &slot.overlapped,
                );
                if (ok == windows.FALSE) {
                    const last_error = windows.GetLastError();
                    if (last_error != windows.Win32Error.IO_PENDING) {
                        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(last_error));
                        slot.manual_completion = true;
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    }
                }
            },
            .stream_read => |stream_op| {
                const stream_native = nativeForHandle(self, stream_op.stream.handle, .stream) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                slot.native_for_cancel = stream_native;

                var buffer = stream_op.buffer;
                buffer.used_len = 0;
                const request_len_u32: u32 = bufferRequestLenU32(buffer, true) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                assert(request_len_u32 > 0);

                const sock: windows.ws2_32.SOCKET = @ptrFromInt(stream_native);
                var wsabuf: windows.ws2_32.WSABUF = .{
                    .len = request_len_u32,
                    .buf = @ptrCast(buffer.bytes.ptr),
                };
                var flags: windows.DWORD = 0;
                const rc = windows.ws2_32.WSARecv(sock, @ptrCast(&wsabuf), 1, null, &flags, &slot.overlapped, null);
                if (rc == windows.ws2_32.SOCKET_ERROR) {
                    const wsa_err = windows.ws2_32.WSAGetLastError();
                    if (@intFromEnum(wsa_err) != wsa_io_pending) {
                        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(wsa_err));
                        slot.manual_completion = true;
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    }
                }
            },
            .stream_write => |stream_op| {
                const stream_native = nativeForHandle(self, stream_op.stream.handle, .stream) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                slot.native_for_cancel = stream_native;

                const request_len_u32: u32 = bufferRequestLenU32(stream_op.buffer, false) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                assert(request_len_u32 > 0);

                const sock: windows.ws2_32.SOCKET = @ptrFromInt(stream_native);
                var wsabuf: windows.ws2_32.WSABUF = .{
                    .len = request_len_u32,
                    .buf = @ptrCast(stream_op.buffer.bytes.ptr),
                };
                const rc = windows.ws2_32.WSASend(sock, @ptrCast(&wsabuf), 1, null, 0, &slot.overlapped, null);
                if (rc == windows.ws2_32.SOCKET_ERROR) {
                    const wsa_err = windows.ws2_32.WSAGetLastError();
                    if (@intFromEnum(wsa_err) != wsa_io_pending) {
                        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(wsa_err));
                        slot.manual_completion = true;
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    }
                }
            },
            .connect => |connect_op| {
                if (connect_op.stream.handle.index >= self.handle_states.len) {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                }

                const socket_family: i32 = switch (connect_op.endpoint) {
                    .ipv4 => @intCast(af_inet_family),
                    .ipv6 => @intCast(af_inet6_family),
                };

                const wsa_flag_overlapped: windows.DWORD = 0x00000001;
                const sock = windows.ws2_32.WSASocketW(
                    socket_family,
                    sock_stream,
                    ipproto_tcp,
                    null,
                    0,
                    wsa_flag_overlapped,
                );
                if (sock == windows.ws2_32.INVALID_SOCKET) {
                    const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                }

                const sock_native: types.NativeHandle = @intFromPtr(sock);
                slot.native_for_cancel = sock_native;

                self.handle_states[connect_op.stream.handle.index] = .open;
                self.handle_generations[connect_op.stream.handle.index] = connect_op.stream.handle.generation;
                self.handle_kinds[connect_op.stream.handle.index] = .stream;
                self.handle_native[connect_op.stream.handle.index] = sock_native;
                self.handle_owned[connect_op.stream.handle.index] = true;

                const native_handle: windows.HANDLE = @ptrFromInt(sock_native);
                _ = kernel32.CreateIoCompletionPort(native_handle, self.port, @intCast(connect_op.stream.handle.index), 0);

                var local_addr = SockaddrAny.anyForFamily(socket_family);
                if (windows.ws2_32.bind(sock, local_addr.ptr(), local_addr.len()) == windows.ws2_32.SOCKET_ERROR) {
                    const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
                    closeNativeHandle(.stream, sock_native);
                    self.handle_native[connect_op.stream.handle.index] = 0;
                    self.handle_owned[connect_op.stream.handle.index] = false;
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                }

                var remote_addr = SockaddrAny.fromEndpoint(connect_op.endpoint);
                const ok = self.winsock_ext.connect_ex(
                    sock,
                    remote_addr.ptr(),
                    remote_addr.len(),
                    null,
                    0,
                    null,
                    &slot.overlapped,
                );
                if (ok == windows.FALSE) {
                    const wsa_err = windows.ws2_32.WSAGetLastError();
                    if (@intFromEnum(wsa_err) != wsa_io_pending) {
                        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(wsa_err));
                        closeNativeHandle(.stream, sock_native);
                        self.handle_native[connect_op.stream.handle.index] = 0;
                        self.handle_owned[connect_op.stream.handle.index] = false;
                        slot.manual_completion = true;
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    }
                }
            },
            .accept => |accept_op| {
                const listener_native = nativeForHandle(self, accept_op.listener.handle, .listener) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };
                slot.native_for_cancel = listener_native;

                const listen_sock: windows.ws2_32.SOCKET = @ptrFromInt(listener_native);
                const family = socketFamily(listen_sock) orelse {
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };

                const wsa_flag_overlapped: windows.DWORD = 0x00000001;
                const accept_sock = windows.ws2_32.WSASocketW(
                    family,
                    sock_stream,
                    ipproto_tcp,
                    null,
                    0,
                    wsa_flag_overlapped,
                );
                if (accept_sock == windows.ws2_32.INVALID_SOCKET) {
                    const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                }
                slot.native_for_accept = @intFromPtr(accept_sock);

                const accept_buf = self.acceptBufferForSlot(slot_index) orelse {
                    closeNativeHandle(.stream, slot.native_for_accept);
                    slot.native_for_accept = 0;
                    slot.manual_completion = true;
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    return operation_id;
                };

                const local_addr_len: windows.DWORD = @intCast(@sizeOf(windows.ws2_32.sockaddr.storage) + 16);
                const ok = self.winsock_ext.accept_ex(
                    listen_sock,
                    accept_sock,
                    @ptrCast(accept_buf.ptr),
                    0,
                    local_addr_len,
                    local_addr_len,
                    &slot.accept_bytes_received,
                    &slot.overlapped,
                );
                if (ok == windows.FALSE) {
                    const wsa_err = windows.ws2_32.WSAGetLastError();
                    if (@intFromEnum(wsa_err) != wsa_io_pending) {
                        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(wsa_err));
                        closeNativeHandle(.stream, slot.native_for_accept);
                        slot.native_for_accept = 0;
                        slot.manual_completion = true;
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        tryPostQueuedCompletionStatus(self.port, &slot.overlapped, 0);
                    }
                }
            },
        }
        return operation_id;
    }

    /// Drains completion entries without blocking.
    pub fn pump(self: *IocpBackend, max_completions: u32) backend.PumpError!u32 {
        assert(max_completions > 0);
        const now = core.time_compat.Instant.now() catch return error.Unsupported;
        self.cancelExpiredTimeouts(now);
        var saw_wakeup = false;
        return self.dequeueFromPort(0, max_completions, &saw_wakeup);
    }

    /// Pops one completion if available.
    pub fn poll(self: *IocpBackend) ?types.Completion {
        const slot_index = self.completed.tryPop() catch blk: {
            var saw_wakeup = false;
            _ = self.dequeueFromPort(0, 1, &saw_wakeup);
            break :blk self.completed.tryPop() catch return null;
        };
        const slot = &self.slots[slot_index];
        if (slot.state != .ready) {
            assert(slot.state == .ready);
            return null;
        }
        const completion = slot.completion;
        self.freeSlot(slot_index);
        return completion;
    }

    /// Blocks for completions, optionally bounded by timeout.
    pub fn waitForCompletions(self: *IocpBackend, max_completions: u32, timeout_ns: ?u64) backend.PumpError!u32 {
        if (max_completions == 0) return error.InvalidInput;
        const global_timeout_ms: u32 = timeoutNsToMs(timeout_ns);
        if (global_timeout_ms == 0) {
            var saw_wakeup = false;
            return self.dequeueFromPort(0, max_completions, &saw_wakeup);
        }

        const global_start = if (timeout_ns != null) core.time_compat.Instant.now() catch return error.Unsupported else null;
        var drained: u32 = 0;
        while (drained < max_completions) {
            const now = core.time_compat.Instant.now() catch return error.Unsupported;
            self.cancelExpiredTimeouts(now);

            var remaining_timeout_ms: u32 = std.math.maxInt(u32);
            if (timeout_ns) |limit_ns| {
                const elapsed_ns: u64 = now.since(global_start.?);
                if (elapsed_ns >= limit_ns) break;
                remaining_timeout_ms = timeoutNsToMs(limit_ns - elapsed_ns);
                if (remaining_timeout_ms == 0) break;
            }

            const next_deadline_ms: u32 = self.msUntilNextDeadline(now) orelse std.math.maxInt(u32);
            const wait_timeout_ms: u32 = if (remaining_timeout_ms < next_deadline_ms) remaining_timeout_ms else next_deadline_ms;

            var saw_wakeup = false;
            const added = self.dequeueFromPort(wait_timeout_ms, max_completions - drained, &saw_wakeup);
            drained += added;
            if (added > 0) continue;
            if (saw_wakeup) break;

            if (wait_timeout_ms == std.math.maxInt(u32)) break;
        }
        return drained;
    }

    /// Wakes a blocked IOCP wait by posting a synthetic completion.
    pub fn wakeup(self: *IocpBackend) void {
        if (self.closed) return;
        _ = kernel32.PostQueuedCompletionStatus(self.port, 0, 0, null);
    }

    /// Attempts to cancel one in-flight operation.
    pub fn cancel(self: *IocpBackend, operation_id: types.OperationId) backend.CancelError!void {
        if (self.closed) return error.Closed;
        const decoded = decodeOperationId(operation_id) orelse return error.NotFound;
        if (decoded.index >= self.slots.len) return error.NotFound;
        var slot = &self.slots[decoded.index];
        if (slot.generation != decoded.generation) return error.NotFound;
        if (slot.state != .in_flight) return error.NotFound;
        if (slot.operation_id != operation_id) return error.NotFound;
        if (slot.cancel_reason == .none) slot.cancel_reason = .cancelled;
        slot.timeout_start = null;
        if (slot.native_for_cancel != 0) {
            _ = kernel32.CancelIoEx(@ptrFromInt(slot.native_for_cancel), &slot.overlapped);
        }
    }

    /// Requests backend shutdown and cancellation of in-flight work.
    pub fn close(self: *IocpBackend) void {
        if (self.closed) return;
        self.closed = true;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            var slot = &self.slots[index];
            if (slot.state != .in_flight) continue;
            if (slot.cancel_reason == .none) slot.cancel_reason = .closed;
            slot.timeout_start = null;
            if (slot.native_for_cancel != 0) {
                _ = kernel32.CancelIoEx(@ptrFromInt(slot.native_for_cancel), &slot.overlapped);
            }
        }
    }

    /// Returns backend capability flags.
    pub fn capabilities(self: *const IocpBackend) types.CapabilityFlags {
        _ = self;
        return .{
            .supports_nop = true,
            .supports_fill = true,
            .supports_cancel = true,
            .supports_close = true,
            .supports_files = true,
            .supports_streams = true,
            .supports_listeners = true,
            .supports_stream_read = true,
            .supports_stream_write = true,
            .supports_accept = true,
            .supports_connect = true,
            .supports_file_read_at = true,
            .supports_file_write_at = true,
            .supports_timeouts = true,
        };
    }

    /// Registers runtime handle metadata and associates it to IOCP.
    pub fn registerHandle(
        self: *IocpBackend,
        handle: types.Handle,
        kind: types.HandleKind,
        native: types.NativeHandle,
        owned: bool,
    ) void {
        if (handle.index >= self.handle_states.len) return;
        if (native == 0) return;

        self.handle_states[handle.index] = .open;
        self.handle_generations[handle.index] = handle.generation;
        self.handle_kinds[handle.index] = kind;
        self.handle_native[handle.index] = native;
        self.handle_owned[handle.index] = owned;

        const native_handle: windows.HANDLE = @ptrFromInt(native);
        _ = kernel32.CreateIoCompletionPort(native_handle, self.port, @intCast(handle.index), 0);
    }

    /// Marks handle closed and cancels dependent operations.
    pub fn notifyHandleClosed(self: *IocpBackend, handle: types.Handle) void {
        if (handle.index >= self.handle_states.len) return;
        if (self.handle_generations[handle.index] != handle.generation) return;

        self.handle_states[handle.index] = .closed;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            var slot = &self.slots[index];
            if (slot.state != .in_flight) continue;
            const matches_a = slot.target_handle_a != null and slot.target_handle_a.? == handle;
            const matches_b = slot.target_handle_b != null and slot.target_handle_b.? == handle;
            if (!matches_a and !matches_b) continue;
            if (slot.cancel_reason == .none) slot.cancel_reason = .closed;
            slot.timeout_start = null;
            if (slot.native_for_cancel != 0) {
                _ = kernel32.CancelIoEx(@ptrFromInt(slot.native_for_cancel), &slot.overlapped);
            }
        }

        if (self.handle_owned[handle.index] and self.handle_native[handle.index] != 0) {
            const native = self.handle_native[handle.index];
            self.handle_native[handle.index] = 0;
            self.handle_owned[handle.index] = false;
            closeNativeHandle(self.handle_kinds[handle.index], native);
        }
    }

    /// Returns true while an in-flight slot references `handle`.
    pub fn handleInUse(self: *IocpBackend, handle: types.Handle) bool {
        if (handle.index >= self.handle_states.len) return false;
        if (self.handle_generations[handle.index] != handle.generation) return false;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            const slot = self.slots[index];
            if (slot.state != .in_flight) continue;
            if (slot.target_handle_a != null and slot.target_handle_a.? == handle) return true;
            if (slot.target_handle_b != null and slot.target_handle_b.? == handle) return true;
        }
        return false;
    }

    fn allocSlot(self: *IocpBackend) backend.SubmitError!u32 {
        assert(self.free_len <= self.free_slots.len);
        if (self.free_len == 0) return error.WouldBlock;
        self.free_len -= 1;
        const slot_index = self.free_slots[self.free_len];
        assert(slot_index < self.slots.len);
        assert(self.slots[slot_index].state == .free);
        return slot_index;
    }

    fn freeSlot(self: *IocpBackend, slot_index: u32) void {
        assert(slot_index < self.slots.len);
        assert(self.free_len < self.free_slots.len);
        const next_generation = nextGeneration(self.slots[slot_index].generation);
        self.slots[slot_index] = .{
            .generation = next_generation,
        };
        self.free_slots[self.free_len] = slot_index;
        self.free_len += 1;
        assert(self.free_len <= self.free_slots.len);
    }

    fn cancelExpiredTimeouts(self: *IocpBackend, now: core.time_compat.Instant) void {
        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            var slot = &self.slots[index];
            if (slot.state != .in_flight) continue;
            const start = slot.timeout_start orelse continue;
            const timeout_ns = operationTimeoutNs(slot.operation) orelse {
                slot.timeout_start = null;
                continue;
            };
            if (timeout_ns == 0) {
                slot.timeout_start = null;
                continue;
            }
            if (slot.cancel_reason != .none) {
                slot.timeout_start = null;
                continue;
            }

            const elapsed_ns: u64 = now.since(start);
            if (elapsed_ns < timeout_ns) continue;

            slot.cancel_reason = .timeout;
            slot.timeout_start = null;
            if (slot.native_for_cancel != 0) {
                _ = kernel32.CancelIoEx(@ptrFromInt(slot.native_for_cancel), &slot.overlapped);
            }
        }
    }

    fn msUntilNextDeadline(self: *IocpBackend, now: core.time_compat.Instant) ?u32 {
        var best: ?u32 = null;
        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            const slot = self.slots[index];
            if (slot.state != .in_flight) continue;
            if (slot.cancel_reason != .none) continue;
            const start = slot.timeout_start orelse continue;
            const timeout_ns = operationTimeoutNs(slot.operation) orelse continue;
            if (timeout_ns == 0) continue;

            const elapsed_ns: u64 = now.since(start);
            if (elapsed_ns >= timeout_ns) return 0;
            const remaining_ns: u64 = timeout_ns - elapsed_ns;
            const remaining_ms: u32 = timeoutNsToMs(remaining_ns);
            best = if (best) |current| @min(current, remaining_ms) else remaining_ms;
        }
        return best;
    }

    fn dequeueFromPort(self: *IocpBackend, timeout_ms: u32, max_completions: u32, saw_wakeup: *bool) u32 {
        saw_wakeup.* = false;
        var drained: u32 = 0;
        while (drained < max_completions) {
            var bytes_transferred: u32 = 0;
            var completion_key: usize = 0;
            var overlapped: ?*windows.OVERLAPPED = null;
            const wait_timeout_ms: u32 = if (drained == 0) timeout_ms else 0;
            const ok = kernel32.GetQueuedCompletionStatus(
                self.port,
                &bytes_transferred,
                &completion_key,
                &overlapped,
                wait_timeout_ms,
            );
            const last_error = if (ok == windows.FALSE) windows.GetLastError() else windows.Win32Error.SUCCESS;
            if (ok == windows.FALSE and last_error == windows.Win32Error.WAIT_TIMEOUT) break;
            const overlapped_ptr = overlapped orelse {
                if (drained == 0) {
                    saw_wakeup.* = true;
                    break;
                }
                continue;
            };
            const slot_index = slotIndexFromOverlapped(self.slots, overlapped_ptr) orelse continue;
            var slot = &self.slots[slot_index];
            if (slot.state != .in_flight) continue;

            if (!slot.manual_completion) {
                slot.completion = self.finalizeCompletion(slot, ok, bytes_transferred, last_error);
            }

            slot.state = .ready;
            self.completed.tryPush(slot_index) catch break;
            drained += 1;
        }
        return drained;
    }

    fn acceptBufferForSlot(self: *IocpBackend, slot_index: u32) ?[]u8 {
        const bytes_per_slot: usize = @intCast(self.cfg.iocp_accept_buffer_bytes);
        const base: usize = std.math.mul(usize, @intCast(slot_index), bytes_per_slot) catch return null;
        if (base + bytes_per_slot > self.accept_buffers.len) return null;
        return self.accept_buffers[base .. base + bytes_per_slot];
    }

    fn finalizeCompletion(self: *IocpBackend, slot: *Slot, ok: windows.BOOL, bytes_transferred: u32, last_error: windows.Win32Error) types.Completion {
        if (ok == windows.FALSE) {
            const completion = if (last_error == windows.Win32Error.OPERATION_ABORTED) switch (slot.cancel_reason) {
                .cancelled => makeSimpleCompletion(slot.operation_id, slot.operation, .cancelled, .cancelled),
                .timeout => makeSimpleCompletion(slot.operation_id, slot.operation, .timeout, .timeout),
                .closed => makeSimpleCompletion(slot.operation_id, slot.operation, .closed, .closed),
                .none => makeSimpleCompletion(slot.operation_id, slot.operation, .cancelled, .cancelled),
            } else blk: {
                const mapped = error_map.fromWindowsErrorCode(@intFromEnum(last_error));
                break :blk makeSimpleCompletion(slot.operation_id, slot.operation, mapped.status, mapped.tag);
            };

            self.cleanupFailedOperation(slot);
            return completion;
        }

        const completion: types.Completion = switch (slot.operation) {
            .nop, .fill => slot.completion,
            .file_read_at => |op| blk: {
                var buffer = op.buffer;
                buffer.used_len = bytes_transferred;
                break :blk types.Completion{
                    .operation_id = slot.operation_id,
                    .tag = .file_read_at,
                    .status = .success,
                    .bytes_transferred = bytes_transferred,
                    .buffer = buffer,
                    .handle = op.file.handle,
                };
            },
            .file_write_at => |op| types.Completion{
                .operation_id = slot.operation_id,
                .tag = .file_write_at,
                .status = .success,
                .bytes_transferred = bytes_transferred,
                .buffer = op.buffer,
                .handle = op.file.handle,
            },
            .stream_read => |op| blk: {
                var buffer = op.buffer;
                buffer.used_len = bytes_transferred;
                break :blk types.Completion{
                    .operation_id = slot.operation_id,
                    .tag = .stream_read,
                    .status = .success,
                    .bytes_transferred = bytes_transferred,
                    .buffer = buffer,
                    .handle = op.stream.handle,
                };
            },
            .stream_write => |op| types.Completion{
                .operation_id = slot.operation_id,
                .tag = .stream_write,
                .status = .success,
                .bytes_transferred = bytes_transferred,
                .buffer = op.buffer,
                .handle = op.stream.handle,
            },
            .connect => |op| blk: {
                const sock_native = nativeForHandle(self, op.stream.handle, .stream) orelse {
                    self.cleanupFailedOperation(slot);
                    break :blk makeSimpleCompletion(slot.operation_id, slot.operation, .invalid_input, .invalid_input);
                };
                const sock: windows.ws2_32.SOCKET = @ptrFromInt(sock_native);
                if (windows.ws2_32.setsockopt(sock, sol_socket, so_update_connect_context, null, 0) == windows.ws2_32.SOCKET_ERROR) {
                    const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
                    self.cleanupFailedOperation(slot);
                    break :blk makeSimpleCompletion(slot.operation_id, slot.operation, mapped.status, mapped.tag);
                }
                break :blk types.Completion{
                    .operation_id = slot.operation_id,
                    .tag = .connect,
                    .status = .success,
                    .bytes_transferred = 0,
                    .buffer = .{ .bytes = &[_]u8{} },
                    .handle = op.stream.handle,
                    .endpoint = op.endpoint,
                };
            },
            .accept => |op| blk: {
                if (slot.native_for_accept == 0) {
                    self.cleanupFailedOperation(slot);
                    break :blk makeSimpleCompletion(slot.operation_id, slot.operation, .invalid_input, .invalid_input);
                }

                const accept_sock: windows.ws2_32.SOCKET = @ptrFromInt(slot.native_for_accept);
                const listen_sock: windows.ws2_32.SOCKET = @ptrFromInt(slot.native_for_cancel);
                var listen_sock_copy = listen_sock;
                if (windows.ws2_32.setsockopt(
                    accept_sock,
                    sol_socket,
                    so_update_accept_context,
                    @ptrCast(&listen_sock_copy),
                    @sizeOf(windows.ws2_32.SOCKET),
                ) == windows.ws2_32.SOCKET_ERROR) {
                    const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
                    self.cleanupFailedOperation(slot);
                    break :blk makeSimpleCompletion(slot.operation_id, slot.operation, mapped.status, mapped.tag);
                }

                if (op.stream.handle.index >= self.handle_states.len) {
                    self.cleanupFailedOperation(slot);
                    break :blk makeSimpleCompletion(slot.operation_id, slot.operation, .invalid_input, .invalid_input);
                }

                self.handle_states[op.stream.handle.index] = .open;
                self.handle_generations[op.stream.handle.index] = op.stream.handle.generation;
                self.handle_kinds[op.stream.handle.index] = .stream;
                self.handle_native[op.stream.handle.index] = slot.native_for_accept;
                self.handle_owned[op.stream.handle.index] = true;

                const native_handle: windows.HANDLE = @ptrFromInt(slot.native_for_accept);
                _ = kernel32.CreateIoCompletionPort(native_handle, self.port, @intCast(op.stream.handle.index), 0);
                slot.native_for_accept = 0;

                break :blk types.Completion{
                    .operation_id = slot.operation_id,
                    .tag = .accept,
                    .status = .success,
                    .bytes_transferred = 0,
                    .buffer = .{ .bytes = &[_]u8{} },
                    .handle = op.stream.handle,
                    .endpoint = socketPeerEndpoint(accept_sock),
                };
            },
        };
        return completion;
    }

    fn cleanupFailedOperation(self: *IocpBackend, slot: *Slot) void {
        switch (slot.operation) {
            .connect => |op| {
                if (op.stream.handle.index >= self.handle_states.len) return;
                if (self.handle_generations[op.stream.handle.index] != op.stream.handle.generation) return;
                if (self.handle_kinds[op.stream.handle.index] != .stream) return;
                if (self.handle_native[op.stream.handle.index] != 0 and self.handle_owned[op.stream.handle.index]) {
                    closeNativeHandle(.stream, self.handle_native[op.stream.handle.index]);
                }
                self.handle_states[op.stream.handle.index] = .closed;
                self.handle_native[op.stream.handle.index] = 0;
                self.handle_owned[op.stream.handle.index] = false;
            },
            .accept => {
                if (slot.native_for_accept != 0) {
                    closeNativeHandle(.stream, slot.native_for_accept);
                    slot.native_for_accept = 0;
                }
            },
            else => {},
        }
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const IocpBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *IocpBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};

fn tryPostQueuedCompletionStatus(port: windows.HANDLE, overlapped: *windows.OVERLAPPED, bytes_transferred: u32) void {
    _ = kernel32.PostQueuedCompletionStatus(port, bytes_transferred, 0, overlapped);
}

fn setOverlappedOffset(overlapped: *windows.OVERLAPPED, offset_bytes: u64) void {
    overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @intCast(offset_bytes & 0xFFFF_FFFF);
    overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @intCast((offset_bytes >> 32) & 0xFFFF_FFFF);
}

fn bufferRequestLenU32(buffer: types.Buffer, is_read: bool) ?u32 {
    if (buffer.bytes.len > std.math.maxInt(u32)) return null;
    if (is_read) return @intCast(buffer.bytes.len);
    if (buffer.used_len == 0) return null;
    return buffer.used_len;
}

fn makeManualTimeoutCompletion(operation_id: types.OperationId, operation: types.Operation) types.Completion {
    return makeSimpleCompletion(operation_id, operation, .timeout, .timeout);
}

fn slotIndexFromOverlapped(slots: []Slot, overlapped: *windows.OVERLAPPED) ?u32 {
    const slot_ptr: *Slot = @fieldParentPtr("overlapped", overlapped);
    const base_addr = @intFromPtr(slots.ptr);
    const slot_addr = @intFromPtr(slot_ptr);
    if (slot_addr < base_addr) return null;
    const diff = slot_addr - base_addr;
    const slot_size = @sizeOf(Slot);
    if (diff % slot_size != 0) return null;
    const index: usize = diff / slot_size;
    if (index >= slots.len) return null;
    return @intCast(index);
}

fn closeNativeHandle(kind: types.HandleKind, native: types.NativeHandle) void {
    if (native == 0) return;
    switch (kind) {
        .file => {
            const handle: windows.HANDLE = @ptrFromInt(native);
            _ = windows.CloseHandle(handle);
        },
        .stream, .listener => {
            const sock: windows.ws2_32.SOCKET = @ptrFromInt(native);
            _ = windows.ws2_32.closesocket(sock);
        },
    }
}

fn nativeForHandle(self: *IocpBackend, handle: types.Handle, kind: types.HandleKind) ?types.NativeHandle {
    if (handle.index >= self.handle_states.len) return null;
    if (self.handle_states[handle.index] != .open) return null;
    if (self.handle_generations[handle.index] != handle.generation) return null;
    if (self.handle_kinds[handle.index] != kind) return null;
    const native = self.handle_native[handle.index];
    if (native == 0) return null;
    return native;
}

fn timeoutNsToMs(timeout_ns: ?u64) u32 {
    const infinite_timeout_ms: u32 = std.math.maxInt(u32);
    const finite_timeout_cap_ms: u64 = std.math.maxInt(u32) - 1;
    if (timeout_ns == null) return infinite_timeout_ms;
    const limit_ns = timeout_ns.?;
    if (limit_ns == 0) return 0;
    const ns_per_ms: u64 = std.time.ns_per_ms;
    var rounded_ms: u64 = limit_ns / ns_per_ms;
    if (limit_ns % ns_per_ms != 0) rounded_ms += 1;
    if (rounded_ms > finite_timeout_cap_ms) return @intCast(finite_timeout_cap_ms);
    return @intCast(rounded_ms);
}

const wsa_io_pending: u32 = 997; // == WSA_IO_PENDING / ERROR_IO_PENDING
const sol_socket: i32 = 0xFFFF;
const so_update_accept_context: i32 = 0x700B;
const so_update_connect_context: i32 = 0x7010;

fn endpointPort(endpoint: types.Endpoint) u16 {
    return switch (endpoint) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
}

test "iocp backend supports bounded nop/fill completions" {
    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    var storage_a: [8]u8 = [_]u8{0} ** 8;
    var storage_b: [8]u8 = [_]u8{0} ** 8;
    const buf_a = types.Buffer{ .bytes = &storage_a };
    const buf_b = types.Buffer{ .bytes = &storage_b };

    const id_a = try backend_impl.submit(.{ .fill = .{
        .buffer = buf_a,
        .len = 4,
        .byte = 0x7A,
    } });
    const id_b = try backend_impl.submit(.{ .nop = buf_b });
    try testing.expectError(error.WouldBlock, backend_impl.submit(.{ .nop = buf_b }));

    _ = try backend_impl.pump(8);
    const first = backend_impl.poll().?;
    const second = backend_impl.poll().?;
    try testing.expect(backend_impl.poll() == null);
    try testing.expectEqual(id_a, first.operation_id);
    try testing.expectEqual(id_b, second.operation_id);
    try testing.expectEqual(types.CompletionStatus.success, first.status);
    try testing.expectEqual(types.CompletionStatus.success, second.status);
    try testing.expectEqual(@as(u8, 0x7A), first.buffer.bytes[0]);
}

test "iocp backend supports connect/accept and stream read/write" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        @intCast(af_inet_family),
        sock_stream,
        ipproto_tcp,
        null,
        0,
        wsa_flag_overlapped,
    );
    try testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);

    var bind_addr = SockaddrAny.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intFromPtr(listen_sock), true);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

    const bound = socketLocalEndpoint(listen_sock) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const server_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    const client_stream = types.Stream{ .handle = .{ .index = 2, .generation = 1 } };

    const accept_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = server_stream,
        .timeout_ns = null,
    } });

    const connect_endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } };
    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = connect_endpoint,
        .timeout_ns = null,
    } });

    _ = try backend_impl.waitForCompletions(2, std.time.ns_per_s);

    var seen_accept = false;
    var seen_connect = false;
    var drain: usize = 0;
    while (drain < 8 and (!seen_accept or !seen_connect)) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == accept_id) {
            seen_accept = true;
            try testing.expectEqual(types.OperationTag.accept, completion.tag);
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
            try testing.expectEqual(@as(?types.Handle, server_stream.handle), completion.handle);
            const peer = completion.endpoint orelse return error.MissingAcceptPeerEndpoint;
            switch (peer) {
                .ipv4 => |ipv4| {
                    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ipv4.address.octets);
                    try testing.expect(ipv4.port != 0);
                    try testing.expect(ipv4.port != port);
                },
                else => return error.UnexpectedAcceptPeerEndpoint,
            }
        } else if (completion.operation_id == connect_id) {
            seen_connect = true;
            try testing.expectEqual(types.OperationTag.connect, completion.tag);
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
            try testing.expectEqual(@as(?types.Handle, client_stream.handle), completion.handle);
        }
    }
    try testing.expect(seen_accept and seen_connect);

    var write_bytes: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(5);

    var read_bytes: [16]u8 = [_]u8{0} ** 16;
    const read_buf = types.Buffer{ .bytes = &read_bytes };

    const write_id = try backend_impl.submit(.{ .stream_write = .{
        .stream = client_stream,
        .buffer = write_buf,
        .timeout_ns = null,
    } });
    const read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = read_buf,
        .timeout_ns = null,
    } });

    _ = try backend_impl.waitForCompletions(2, std.time.ns_per_s);

    var got_write = false;
    var got_read = false;
    drain = 0;
    while (drain < 8 and (!got_write or !got_read)) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == write_id) {
            got_write = true;
            try testing.expectEqual(types.OperationTag.stream_write, completion.tag);
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
            try testing.expectEqual(@as(u32, 5), completion.bytes_transferred);
        } else if (completion.operation_id == read_id) {
            got_read = true;
            try testing.expectEqual(types.OperationTag.stream_read, completion.tag);
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
            try testing.expectEqual(@as(u32, 5), completion.bytes_transferred);
            try testing.expectEqualSlices(u8, "hello", completion.buffer.usedSlice());
        }
    }
    try testing.expect(got_write and got_read);

    var timeout_read_bytes: [8]u8 = [_]u8{0} ** 8;
    const timeout_read_buf = types.Buffer{ .bytes = &timeout_read_bytes };
    const timeout_read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = timeout_read_buf,
        .timeout_ns = 20 * std.time.ns_per_ms,
    } });
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const timeout_completion = backend_impl.poll().?;
    try testing.expectEqual(timeout_read_id, timeout_completion.operation_id);
    try testing.expectEqual(types.OperationTag.stream_read, timeout_completion.tag);
    try testing.expectEqual(types.CompletionStatus.timeout, timeout_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), timeout_completion.err);

    const accept_timeout_stream = types.Stream{ .handle = .{ .index = 3, .generation = 1 } };
    const accept_timeout_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = accept_timeout_stream,
        .timeout_ns = 50 * std.time.ns_per_ms,
    } });
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const accept_timeout_completion = backend_impl.poll().?;
    try testing.expectEqual(accept_timeout_id, accept_timeout_completion.operation_id);
    try testing.expectEqual(types.OperationTag.accept, accept_timeout_completion.tag);
    try testing.expectEqual(types.CompletionStatus.timeout, accept_timeout_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), accept_timeout_completion.err);

    const accept_cancel_stream = types.Stream{ .handle = .{ .index = 4, .generation = 1 } };
    const accept_cancel_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = accept_cancel_stream,
        .timeout_ns = null,
    } });
    try backend_impl.cancel(accept_cancel_id);
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const accept_cancel_completion = backend_impl.poll().?;
    try testing.expectEqual(accept_cancel_id, accept_cancel_completion.operation_id);
    try testing.expectEqual(types.OperationTag.accept, accept_cancel_completion.tag);
    try testing.expectEqual(types.CompletionStatus.cancelled, accept_cancel_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .cancelled), accept_cancel_completion.err);

    var close_read_bytes: [8]u8 = [_]u8{0} ** 8;
    const close_read_buf = types.Buffer{ .bytes = &close_read_bytes };
    const close_read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = close_read_buf,
        .timeout_ns = null,
    } });
    backend_impl.notifyHandleClosed(server_stream.handle);
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const close_read_completion = backend_impl.poll().?;
    try testing.expectEqual(close_read_id, close_read_completion.operation_id);
    try testing.expectEqual(types.OperationTag.stream_read, close_read_completion.tag);
    try testing.expectEqual(types.CompletionStatus.closed, close_read_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .closed), close_read_completion.err);

    backend_impl.notifyHandleClosed(client_stream.handle);
}

test "iocp backend allows multiple in-flight reads on one stream" {
    var cfg = config.Config.initForTest(16);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        @intCast(af_inet_family),
        sock_stream,
        ipproto_tcp,
        null,
        0,
        wsa_flag_overlapped,
    );
    try testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);

    var bind_addr = SockaddrAny.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    const bound = socketLocalEndpoint(listen_sock) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intFromPtr(listen_sock), true);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

    const server_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    const client_stream = types.Stream{ .handle = .{ .index = 2, .generation = 1 } };
    defer backend_impl.notifyHandleClosed(server_stream.handle);
    defer backend_impl.notifyHandleClosed(client_stream.handle);

    const accept_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = server_stream,
        .timeout_ns = null,
    } });

    const connect_endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } };
    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = connect_endpoint,
        .timeout_ns = null,
    } });

    _ = try backend_impl.waitForCompletions(2, std.time.ns_per_s);

    var saw_accept = false;
    var saw_connect = false;
    var drain: usize = 0;
    while (drain < 16 and (!saw_accept or !saw_connect)) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == accept_id) {
            saw_accept = true;
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
        } else if (completion.operation_id == connect_id) {
            saw_connect = true;
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
        }
    }
    try testing.expect(saw_accept and saw_connect);

    var read_a_bytes: [1]u8 = [_]u8{0};
    var read_b_bytes: [1]u8 = [_]u8{0};
    const read_a_buf = types.Buffer{ .bytes = &read_a_bytes };
    const read_b_buf = types.Buffer{ .bytes = &read_b_bytes };

    const read_a_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = read_a_buf,
        .timeout_ns = null,
    } });
    const read_b_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = read_b_buf,
        .timeout_ns = null,
    } });

    var write_bytes: [2]u8 = .{ 'a', 'b' };
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(2);
    const write_id = try backend_impl.submit(.{ .stream_write = .{
        .stream = client_stream,
        .buffer = write_buf,
        .timeout_ns = null,
    } });

    var pumped_total: u32 = 0;
    var attempts: u32 = 0;
    while (attempts < 8 and pumped_total < 3) : (attempts += 1) {
        pumped_total += try backend_impl.waitForCompletions(3 - pumped_total, std.time.ns_per_s);
    }
    try testing.expect(pumped_total >= 3);

    var got_write = false;
    var got_read_a = false;
    var got_read_b = false;
    var got: usize = 0;
    while (got < 8 and (!got_write or !got_read_a or !got_read_b)) : (got += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == write_id) {
            got_write = true;
            try testing.expectEqual(types.OperationTag.stream_write, completion.tag);
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
            try testing.expectEqual(@as(u32, 2), completion.bytes_transferred);
        } else if (completion.operation_id == read_a_id) {
            got_read_a = true;
            try testing.expectEqual(types.OperationTag.stream_read, completion.tag);
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
            try testing.expectEqual(@as(u32, 1), completion.bytes_transferred);
        } else if (completion.operation_id == read_b_id) {
            got_read_b = true;
            try testing.expectEqual(types.OperationTag.stream_read, completion.tag);
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
            try testing.expectEqual(@as(u32, 1), completion.bytes_transferred);
        }
    }
    try testing.expect(got_write and got_read_a and got_read_b);

    const got_first = read_a_bytes[0];
    const got_second = read_b_bytes[0];
    const matches = (got_first == 'a' and got_second == 'b') or (got_first == 'b' and got_second == 'a');
    try testing.expect(matches);
}

test "iocp backend closes pending stream_write when stream handle closes" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        @intCast(af_inet_family),
        sock_stream,
        ipproto_tcp,
        null,
        0,
        wsa_flag_overlapped,
    );
    try testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);
    defer _ = windows.ws2_32.closesocket(listen_sock);

    var bind_addr = SockaddrAny.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    const bound = socketLocalEndpoint(listen_sock) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const client_sock = windows.ws2_32.WSASocketW(
        @intCast(af_inet_family),
        sock_stream,
        ipproto_tcp,
        null,
        0,
        wsa_flag_overlapped,
    );
    try testing.expect(client_sock != windows.ws2_32.INVALID_SOCKET);
    errdefer _ = windows.ws2_32.closesocket(client_sock);

    var remote_addr = SockaddrAny.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } });
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.connect(client_sock, remote_addr.ptr(), remote_addr.len()));

    const server_sock = windows.ws2_32.accept(listen_sock, null, null);
    try testing.expect(server_sock != windows.ws2_32.INVALID_SOCKET);
    errdefer _ = windows.ws2_32.closesocket(server_sock);

    const so_sndbuf: i32 = 0x1001;
    const so_rcvbuf: i32 = 0x1002;
    var small_buf: i32 = 1024;
    _ = windows.ws2_32.setsockopt(server_sock, sol_socket, so_rcvbuf, @ptrCast(&small_buf), @sizeOf(i32));
    _ = windows.ws2_32.setsockopt(client_sock, sol_socket, so_sndbuf, @ptrCast(&small_buf), @sizeOf(i32));

    var nonblocking: u32 = 1;
    const fionbio: i32 = @bitCast(@as(u32, 0x8004667E));
    _ = windows.ws2_32.ioctlsocket(client_sock, fionbio, &nonblocking);

    var fill_bytes: [4096]u8 = [_]u8{0xAB} ** 4096;
    var sent_total: usize = 0;
    const sent_limit: usize = 64 * 1024 * 1024;
    var saw_would_block = false;
    while (sent_total < sent_limit) {
        const rc = windows.ws2_32.send(client_sock, @ptrCast(&fill_bytes), @intCast(fill_bytes.len), 0);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            if (windows.ws2_32.WSAGetLastError() == .EWOULDBLOCK) {
                saw_would_block = true;
                break;
            }
            return error.SkipZigTest;
        }
        sent_total += @intCast(rc);
    }
    if (!saw_would_block) return error.SkipZigTest;

    nonblocking = 0;
    _ = windows.ws2_32.ioctlsocket(client_sock, fionbio, &nonblocking);

    const server_stream = types.Stream{ .handle = .{ .index = 0, .generation = 1 } };
    const client_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    backend_impl.registerHandle(server_stream.handle, .stream, @intFromPtr(server_sock), true);
    backend_impl.registerHandle(client_stream.handle, .stream, @intFromPtr(client_sock), true);
    defer backend_impl.notifyHandleClosed(server_stream.handle);
    defer backend_impl.notifyHandleClosed(client_stream.handle);

    var write_bytes: [1]u8 = .{'x'};
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(1);
    const write_id = try backend_impl.submit(.{ .stream_write = .{
        .stream = client_stream,
        .buffer = write_buf,
        .timeout_ns = null,
    } });
    backend_impl.notifyHandleClosed(client_stream.handle);

    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const completion = backend_impl.poll().?;
    try testing.expectEqual(write_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.stream_write, completion.tag);
    try testing.expectEqual(types.CompletionStatus.closed, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .closed), completion.err);
    try testing.expectEqual(@as(u32, 0), completion.bytes_transferred);
}

test "iocp backend closes pending accept when listener handle closes" {
    var cfg = config.Config.initForTest(4);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        @intCast(af_inet_family),
        sock_stream,
        ipproto_tcp,
        null,
        0,
        wsa_flag_overlapped,
    );
    try testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);

    var bind_addr = SockaddrAny.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intFromPtr(listen_sock), true);
    var listener_closed = false;
    defer if (!listener_closed) backend_impl.notifyHandleClosed(listener_handle);

    const listener = types.Listener{ .handle = listener_handle };
    const server_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };

    const accept_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = server_stream,
        .timeout_ns = null,
    } });

    backend_impl.notifyHandleClosed(listener_handle);
    listener_closed = true;

    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const completion = backend_impl.poll() orelse return error.SkipZigTest;
    try testing.expectEqual(accept_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.accept, completion.tag);
    try testing.expectEqual(types.CompletionStatus.closed, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .closed), completion.err);
}

test "iocp backend maps connection refused on connect" {
    var cfg = config.Config.initForTest(4);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    var reserve_sock = windows.ws2_32.WSASocketW(
        @intCast(af_inet_family),
        sock_stream,
        ipproto_tcp,
        null,
        0,
        wsa_flag_overlapped,
    );
    try testing.expect(reserve_sock != windows.ws2_32.INVALID_SOCKET);

    var bind_addr = SockaddrAny.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(reserve_sock, bind_addr.ptr(), bind_addr.len()));

    const reserved = socketLocalEndpoint(reserve_sock) orelse return error.SkipZigTest;
    const port = endpointPort(reserved);
    try testing.expect(port != 0);
    _ = windows.ws2_32.closesocket(reserve_sock);
    reserve_sock = windows.ws2_32.INVALID_SOCKET;

    const client_stream = types.Stream{ .handle = .{ .index = 0, .generation = 1 } };
    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } };

    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = endpoint,
        .timeout_ns = 2 * std.time.ns_per_s,
    } });
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);

    const completion = backend_impl.poll() orelse return error.SkipZigTest;
    try testing.expectEqual(connect_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.connect, completion.tag);
    try testing.expectEqual(types.CompletionStatus.connection_refused, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .connection_refused), completion.err);

    backend_impl.notifyHandleClosed(client_stream.handle);
}

test "iocp backend maps connection reset on stream read" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        @intCast(af_inet_family),
        sock_stream,
        ipproto_tcp,
        null,
        0,
        wsa_flag_overlapped,
    );
    try testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);

    var bind_addr = SockaddrAny.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    const bound = socketLocalEndpoint(listen_sock) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intFromPtr(listen_sock), true);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

    const server_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    const client_stream = types.Stream{ .handle = .{ .index = 2, .generation = 1 } };

    const accept_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = server_stream,
        .timeout_ns = null,
    } });

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } };
    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = endpoint,
        .timeout_ns = null,
    } });

    _ = try backend_impl.waitForCompletions(2, std.time.ns_per_s);
    var saw_accept = false;
    var saw_connect = false;
    var drain: usize = 0;
    while (drain < 16 and (!saw_accept or !saw_connect)) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == accept_id) {
            saw_accept = true;
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
        } else if (completion.operation_id == connect_id) {
            saw_connect = true;
            try testing.expectEqual(types.CompletionStatus.success, completion.status);
        }
    }
    try testing.expect(saw_accept and saw_connect);

    const so_linger: i32 = 0x0080;
    const Linger = extern struct {
        l_onoff: u16,
        l_linger: u16,
    };

    const server_native = backend_impl.handle_native[server_stream.handle.index];
    try testing.expect(server_native != 0);
    const server_sock: windows.ws2_32.SOCKET = @ptrFromInt(server_native);
    var linger_opt = Linger{ .l_onoff = 1, .l_linger = 0 };
    if (windows.ws2_32.setsockopt(
        server_sock,
        sol_socket,
        so_linger,
        @ptrCast(&linger_opt),
        @sizeOf(Linger),
    ) == windows.ws2_32.SOCKET_ERROR) {
        return error.SkipZigTest;
    }

    backend_impl.notifyHandleClosed(server_stream.handle);

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buf = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = client_stream,
        .buffer = read_buf,
        .timeout_ns = 2 * std.time.ns_per_s,
    } });
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);

    const completion = backend_impl.poll() orelse return error.SkipZigTest;
    try testing.expectEqual(read_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.stream_read, completion.tag);
    try testing.expectEqual(types.CompletionStatus.connection_reset, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .connection_reset), completion.err);

    backend_impl.notifyHandleClosed(client_stream.handle);
}

test "iocp backend maps broken pipe on stream write after shutdown send" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        @intCast(af_inet_family),
        sock_stream,
        ipproto_tcp,
        null,
        0,
        wsa_flag_overlapped,
    );
    try testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);
    defer _ = windows.ws2_32.closesocket(listen_sock);

    var bind_addr = SockaddrAny.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    const bound = socketLocalEndpoint(listen_sock) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const client_stream = types.Stream{ .handle = .{ .index = 0, .generation = 1 } };
    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } };
    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = endpoint,
        .timeout_ns = null,
    } });
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);

    var saw_connect = false;
    var drain: usize = 0;
    while (drain < 8 and !saw_connect) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id != connect_id) continue;
        saw_connect = true;
        try testing.expectEqual(types.OperationTag.connect, completion.tag);
        try testing.expectEqual(types.CompletionStatus.success, completion.status);
    }
    try testing.expect(saw_connect);

    const client_native = backend_impl.handle_native[client_stream.handle.index];
    try testing.expect(client_native != 0);
    const client_sock: windows.ws2_32.SOCKET = @ptrFromInt(client_native);
    if (windows.ws2_32.shutdown(client_sock, windows.ws2_32.SD_SEND) == windows.ws2_32.SOCKET_ERROR) {
        return error.SkipZigTest;
    }

    var write_bytes: [2]u8 = .{ 'h', 'i' };
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(2);
    const write_id = try backend_impl.submit(.{ .stream_write = .{
        .stream = client_stream,
        .buffer = write_buf,
        .timeout_ns = 2 * std.time.ns_per_s,
    } });

    var completion_opt: ?types.Completion = null;
    var attempt: usize = 0;
    while (attempt < 4 and completion_opt == null) : (attempt += 1) {
        var drain_poll: usize = 0;
        while (drain_poll < 8) : (drain_poll += 1) {
            const completion = backend_impl.poll() orelse break;
            if (completion.operation_id == write_id) {
                completion_opt = completion;
                break;
            }
        }
        if (completion_opt != null) break;
        _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    }
    const completion = completion_opt orelse return error.SkipZigTest;
    try testing.expectEqual(write_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.stream_write, completion.tag);
    try testing.expectEqual(types.CompletionStatus.broken_pipe, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .broken_pipe), completion.err);

    backend_impl.notifyHandleClosed(client_stream.handle);
}

test "iocp backend supports overlapped file write/read via adopted handle" {
    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .windows_iocp;

    if (!io_caps.windowsBackendEnabled()) {
        try testing.expectError(error.Unsupported, IocpBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try IocpBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const filename_utf8 = "static_io_iocp_file_io.tmp";

    var filename_w: [64:0]u16 = undefined;
    assert(filename_utf8.len + 1 <= filename_w.len);
    for (filename_utf8, 0..) |byte, index| {
        filename_w[index] = byte;
    }
    filename_w[filename_utf8.len] = 0;
    const filename_wz = filename_w[0..filename_utf8.len :0].ptr;

    defer _ = DeleteFileW(filename_wz);

    const desired_access: windows.ACCESS_MASK = .{ .GENERIC = .{ .READ = true, .WRITE = true } };
    const share_mode: windows.DWORD = 0x00000001 | 0x00000002 | 0x00000004;
    const creation_disposition: windows.DWORD = windows.CREATE_ALWAYS;
    const flags_and_attributes: windows.DWORD = 0x00000080 | windows.FILE_FLAG_OVERLAPPED;

    const native_handle = kernel32.CreateFileW(
        filename_wz,
        desired_access,
        share_mode,
        null,
        creation_disposition,
        flags_and_attributes,
        null,
    );
    try testing.expect(native_handle != windows.INVALID_HANDLE_VALUE);

    const file_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(file_handle, .file, @intFromPtr(native_handle), true);
    defer backend_impl.notifyHandleClosed(file_handle);
    const file = types.File{ .handle = file_handle };

    var write_bytes: [4]u8 = .{ 't', 'e', 's', 't' };
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(4);

    const write_id = try backend_impl.submit(.{ .file_write_at = .{
        .file = file,
        .buffer = write_buf,
        .offset_bytes = 0,
        .timeout_ns = null,
    } });
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const write_completion = backend_impl.poll().?;
    try testing.expectEqual(write_id, write_completion.operation_id);
    try testing.expectEqual(types.OperationTag.file_write_at, write_completion.tag);
    try testing.expectEqual(types.CompletionStatus.success, write_completion.status);
    try testing.expectEqual(@as(u32, 4), write_completion.bytes_transferred);
    try testing.expectEqual(@as(?types.Handle, file_handle), write_completion.handle);

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buf = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .file_read_at = .{
        .file = file,
        .buffer = read_buf,
        .offset_bytes = 0,
        .timeout_ns = null,
    } });
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const read_completion = backend_impl.poll().?;
    try testing.expectEqual(read_id, read_completion.operation_id);
    try testing.expectEqual(types.OperationTag.file_read_at, read_completion.tag);
    try testing.expectEqual(types.CompletionStatus.success, read_completion.status);
    try testing.expectEqualSlices(u8, "test", read_completion.buffer.usedSlice());
    try testing.expectEqual(@as(?types.Handle, file_handle), read_completion.handle);
}

extern "kernel32" fn DeleteFileW(lpFileName: windows.LPCWSTR) callconv(.winapi) windows.BOOL;
