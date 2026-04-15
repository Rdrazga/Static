//! Linux `io_uring` backend.
//!
//! This backend is only enabled when:
//! - `enable_os_backends=true`
//! - `single_threaded=false`
//! - target OS is Linux
//!
//! It uses `std.os.linux.IoUring` for bounded setup and safe ring access.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const io_caps = @import("../../caps.zig");
const static_queues = @import("static_queues");
const backend = @import("../../backend.zig");
const config = @import("../../config.zig");
const operation_helpers = @import("../../operation_helpers.zig");
const operation_ids = @import("../../operation_ids.zig");
const types = @import("../../types.zig");
const error_map = @import("../../error_map.zig");
const static_net_native = @import("static_net_native");

const linux = std.os.linux;
const IdQueue = static_queues.ring_buffer.RingBuffer(u32);
const DecodedOperationId = operation_ids.DecodedOperationId;
const backend_internal_flag = operation_ids.internal_flag;
const decodeOperationId = operation_ids.decodeExternalOperationId;
const encodeInternalOperationId = operation_ids.encodeInternalOperationId;
const encodeOperationId = operation_ids.encodeExternalOperationId;
const makeSimpleCompletion = operation_helpers.makeSimpleCompletion;
const nextGeneration = operation_ids.nextGeneration;
const operationTimeoutNs = operation_helpers.operationTimeoutNs;
const operationUsesHandle = operation_helpers.operationUsesHandle;
const send_flags: u32 = linux.MSG.NOSIGNAL;
const SockaddrAnyLinux = static_net_native.linux.SockaddrAny;
const endpointFromSockaddrStorage = static_net_native.linux.endpointFromStorage;
const socketLocalEndpoint = static_net_native.linux.socketLocalEndpoint;

/// Host-selected io_uring backend type.
pub const IoUringBackend = if (builtin.os.tag == .linux) LinuxIoUringBackend else UnsupportedIoUringBackend;

const CancelReason = enum(u8) {
    none,
    cancelled,
    timeout,
    closed,
};

const SlotState = enum(u8) {
    free,
    in_flight,
    ready,
};

const Slot = struct {
    generation: u32 = 1,
    state: SlotState = .free,
    operation_id: types.OperationId = 0,
    operation: types.Operation = undefined,
    completion: types.Completion = undefined,
    cancel_reason: CancelReason = .none,
    has_link_timeout: bool = false,

    native_for_cancel: std.posix.fd_t = -1,

    timeout_spec: linux.kernel_timespec = undefined,
    connect_addr: SockaddrAnyLinux = undefined,
    accept_addr: linux.sockaddr.storage = undefined,
    accept_addr_len: linux.socklen_t = 0,
};

const HandleState = enum(u8) {
    free,
    open,
    closed,
};

const UserdataDecoded = struct {
    operation_id: types.OperationId,
    subkind: u32,
};

fn encodeUserdata(operation_id: types.OperationId, subkind: u32) u64 {
    return @as(u64, operation_id) | (@as(u64, subkind) << 32);
}

fn decodeUserdata(user_data: u64) UserdataDecoded {
    return .{
        .operation_id = @intCast(user_data & 0xFFFF_FFFF),
        .subkind = @intCast(user_data >> 32),
    };
}

const wakeup_subkind: u32 = 5;
const wakeup_operation_id: types.OperationId = encodeInternalOperationId(2);
const wakeup_user_data: u64 = encodeUserdata(wakeup_operation_id, wakeup_subkind);

fn timeoutNsToTimespec(timeout_ns: u64) linux.kernel_timespec {
    const ns_per_s: u64 = std.time.ns_per_s;
    return .{
        .sec = @intCast(timeout_ns / ns_per_s),
        .nsec = @intCast(timeout_ns % ns_per_s),
    };
}

fn errnoFromCqeRes(res: i32) linux.E {
    assert(res < 0);
    const errno_int: i32 = -res;
    assert(errno_int >= 0);
    assert(errno_int <= std.math.maxInt(u16));
    return @enumFromInt(@as(u16, @intCast(errno_int)));
}

fn endpointPort(endpoint: types.Endpoint) u16 {
    return switch (endpoint) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
}

fn closeNativeHandle(kind: types.HandleKind, native: std.posix.fd_t) void {
    _ = kind;
    if (native < 0) return;
    std.posix.close(native);
}

fn mapErrnoToCompletion(
    operation_id: types.OperationId,
    operation: types.Operation,
    cancel_reason: CancelReason,
    has_link_timeout: bool,
    err: linux.E,
) types.Completion {
    const mapped: error_map.MappedCompletionError = switch (err) {
        .CANCELED => switch (cancel_reason) {
            .timeout => error_map.fromTag(.timeout),
            .closed => error_map.fromTag(.closed),
            .cancelled => error_map.fromTag(.cancelled),
            .none => if (has_link_timeout) error_map.fromTag(.timeout) else error_map.fromTag(.cancelled),
        },
        else => error_map.fromLinuxErrno(err),
    };
    return makeSimpleCompletion(operation_id, operation, mapped.status, mapped.tag);
}

const LinuxIoUringBackend = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    io_uring: linux.IoUring,

    supports_link_timeout: bool,
    supports_async_cancel: bool,
    supports_timeout: bool,
    supports_timeout_remove: bool,

    slots: []Slot,
    free_slots: []u32,
    free_len: u32,
    completed: IdQueue,
    cqe_batch: []linux.io_uring_cqe,

    handle_states: []HandleState,
    handle_generations: []u32,
    handle_kinds: []types.HandleKind,
    handle_native: []std.posix.fd_t,
    handle_owned: []bool,

    wait_timeout_spec: linux.kernel_timespec = undefined,

    wakeup_fd: std.posix.fd_t = -1,

    closed: bool = false,

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

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!LinuxIoUringBackend {
        if (!io_caps.linuxBackendEnabled()) return error.Unsupported;
        if (cfg.backend_kind != .linux_io_uring and cfg.backend_kind != .platform) return error.Unsupported;

        config.validate(cfg) catch |cfg_err| switch (cfg_err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
        };

        const entries_u16: u16 = @intCast(cfg.uring_sq_entries);
        var io_uring = linux.IoUring.init(entries_u16, 0) catch return error.Unsupported;
        errdefer io_uring.deinit();

        const probe = io_uring.get_probe() catch return error.Unsupported;
        const supports_link_timeout = probe.is_supported(.LINK_TIMEOUT);
        const supports_async_cancel = probe.is_supported(.ASYNC_CANCEL);
        const supports_timeout = probe.is_supported(.TIMEOUT);
        const supports_timeout_remove = probe.is_supported(.TIMEOUT_REMOVE);

        const slots = allocator.alloc(Slot, cfg.max_in_flight) catch return error.OutOfMemory;
        errdefer allocator.free(slots);
        @memset(slots, .{});

        const free_slots = allocator.alloc(u32, cfg.max_in_flight) catch return error.OutOfMemory;
        errdefer allocator.free(free_slots);
        var free_index: usize = 0;
        while (free_index < cfg.max_in_flight) : (free_index += 1) {
            free_slots[free_index] = @intCast(cfg.max_in_flight - 1 - free_index);
        }

        var completed = IdQueue.init(allocator, .{ .capacity = cfg.completion_queue_capacity }) catch return error.OutOfMemory;
        errdefer completed.deinit();

        const cqe_batch = allocator.alloc(linux.io_uring_cqe, cfg.uring_cq_drain_max) catch return error.OutOfMemory;
        errdefer allocator.free(cqe_batch);

        const handle_states = allocator.alloc(HandleState, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_states);
        @memset(handle_states, .free);

        const handle_generations = allocator.alloc(u32, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_generations);
        @memset(handle_generations, 0);

        const handle_kinds = allocator.alloc(types.HandleKind, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_kinds);
        @memset(handle_kinds, .file);

        const handle_native = allocator.alloc(std.posix.fd_t, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_native);
        @memset(handle_native, -1);

        const handle_owned = allocator.alloc(bool, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_owned);
        @memset(handle_owned, false);

        const wake_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        const wakeup_fd: std.posix.fd_t = switch (std.posix.errno(wake_rc)) {
            .SUCCESS => @intCast(wake_rc),
            else => return error.Unsupported,
        };
        errdefer std.posix.close(wakeup_fd);

        _ = io_uring.poll_add(wakeup_user_data, @intCast(wakeup_fd), linux.POLL.IN) catch return error.Unsupported;
        _ = io_uring.submit() catch return error.Unsupported;

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .io_uring = io_uring,
            .supports_link_timeout = supports_link_timeout,
            .supports_async_cancel = supports_async_cancel,
            .supports_timeout = supports_timeout,
            .supports_timeout_remove = supports_timeout_remove,
            .slots = slots,
            .free_slots = free_slots,
            .free_len = cfg.max_in_flight,
            .completed = completed,
            .cqe_batch = cqe_batch,
            .handle_states = handle_states,
            .handle_generations = handle_generations,
            .handle_kinds = handle_kinds,
            .handle_native = handle_native,
            .handle_owned = handle_owned,
            .wakeup_fd = wakeup_fd,
        };
    }

    /// Returns allocator used by backend-owned memory.
    pub fn getAllocator(self: *const LinuxIoUringBackend) std.mem.Allocator {
        return self.allocator;
    }

    /// Releases io_uring resources and backend-owned allocations.
    pub fn deinit(self: *LinuxIoUringBackend) void {
        self.completed.deinit();
        self.allocator.free(self.cqe_batch);
        self.allocator.free(self.handle_owned);
        self.allocator.free(self.handle_native);
        self.allocator.free(self.handle_kinds);
        self.allocator.free(self.handle_generations);
        self.allocator.free(self.handle_states);
        self.allocator.free(self.free_slots);
        self.allocator.free(self.slots);
        if (self.wakeup_fd >= 0) std.posix.close(self.wakeup_fd);
        self.io_uring.deinit();
        self.* = undefined;
    }

    /// Returns a type-erased backend interface for runtime dispatch.
    pub fn asBackend(self: *LinuxIoUringBackend) backend.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Returns backend capability flags.
    pub fn capabilities(self: *const LinuxIoUringBackend) types.CapabilityFlags {
        return .{
            .supports_nop = true,
            .supports_fill = true,
            .supports_cancel = self.supports_async_cancel,
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
            .supports_timeouts = self.supports_link_timeout,
        };
    }

    fn allocSlot(self: *LinuxIoUringBackend) backend.SubmitError!u32 {
        assert(self.free_len <= self.free_slots.len);
        if (self.free_len == 0) return error.WouldBlock;
        self.free_len -= 1;
        const slot_index = self.free_slots[self.free_len];
        assert(slot_index < self.slots.len);
        assert(self.slots[slot_index].state == .free);
        return slot_index;
    }

    fn freeSlot(self: *LinuxIoUringBackend, slot_index: u32) void {
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

    fn completeImmediate(self: *LinuxIoUringBackend, op: types.Operation, completion: types.Completion) backend.SubmitError!types.OperationId {
        const slot_index = try self.allocSlot();
        const slot = &self.slots[slot_index];
        assert(slot.state == .free);

        const operation_id = encodeOperationId(slot_index, slot.generation);
        var out_completion = completion;
        out_completion.operation_id = operation_id;

        slot.* = .{
            .generation = slot.generation,
            .state = .ready,
            .operation_id = operation_id,
            .operation = op,
            .completion = out_completion,
            .cancel_reason = .none,
            .has_link_timeout = false,
            .native_for_cancel = -1,
            .accept_addr_len = 0,
        };

        self.completed.tryPush(slot_index) catch {
            self.freeSlot(slot_index);
            return error.WouldBlock;
        };
        return operation_id;
    }

    fn nativeForHandle(self: *const LinuxIoUringBackend, handle: types.Handle, expected_kind: types.HandleKind) ?std.posix.fd_t {
        if (handle.index >= self.handle_states.len) return null;
        if (self.handle_states[handle.index] != .open) return null;
        if (self.handle_generations[handle.index] != handle.generation) return null;
        if (self.handle_kinds[handle.index] != expected_kind) return null;
        const native = self.handle_native[handle.index];
        if (native < 0) return null;
        return native;
    }

    fn sqeAvailable(self: *const LinuxIoUringBackend) u32 {
        const head = @atomicLoad(u32, self.io_uring.sq.head, .acquire);
        const tail = self.io_uring.sq.sqe_tail;
        const pending = tail -% head;
        const cap: u32 = @intCast(self.io_uring.sq.sqes.len);
        if (pending >= cap) return 0;
        return cap - pending;
    }

    fn submitInternalCancel(self: *LinuxIoUringBackend, operation_id: types.OperationId) void {
        if (!self.supports_async_cancel) return;
        const sqe = self.io_uring.get_sqe() catch return;
        sqe.prep_cancel(encodeUserdata(operation_id, 0), 0);
        sqe.user_data = encodeUserdata(operation_id, 2);
    }

    /// Submits one operation into io_uring.
    pub fn submit(self: *LinuxIoUringBackend, op: types.Operation) backend.SubmitError!types.OperationId {
        if (self.closed) return error.Closed;

        switch (op) {
            .nop => |buffer| {
                if (buffer.used_len > buffer.bytes.len) return error.InvalidInput;
                return self.completeImmediate(op, .{
                    .operation_id = 0,
                    .tag = .nop,
                    .status = .success,
                    .bytes_transferred = buffer.used_len,
                    .buffer = buffer,
                });
            },
            .fill => |fill_op| {
                if (fill_op.buffer.used_len > fill_op.buffer.bytes.len) return error.InvalidInput;
                if (fill_op.len > fill_op.buffer.bytes.len) return error.InvalidInput;
                var out_buffer = fill_op.buffer;
                if (fill_op.len > 0) @memset(out_buffer.bytes[0..fill_op.len], fill_op.byte);
                out_buffer.used_len = fill_op.len;
                return self.completeImmediate(op, .{
                    .operation_id = 0,
                    .tag = .fill,
                    .status = .success,
                    .bytes_transferred = fill_op.len,
                    .buffer = out_buffer,
                });
            },
            else => {},
        }

        const timeout_ns = operationTimeoutNs(op);
        if (timeout_ns != null and timeout_ns.? == 0) {
            return self.completeImmediate(op, makeSimpleCompletion(0, op, .timeout, .timeout));
        }

        const needs_timeout = timeout_ns != null;
        if (needs_timeout and !self.supports_link_timeout) return error.Unsupported;

        const sqe_needed: u32 = if (needs_timeout) 2 else 1;
        if (self.free_len == 0) return error.WouldBlock;
        if (self.sqeAvailable() < sqe_needed) return error.WouldBlock;

        var native_fd: std.posix.fd_t = -1;
        var connect_sock: std.posix.fd_t = -1;
        var request_len: u32 = 0;

        switch (op) {
            .file_read_at => |file_op| {
                if (file_op.buffer.used_len > file_op.buffer.bytes.len) return error.InvalidInput;
                if (file_op.buffer.bytes.len > std.math.maxInt(u32)) return error.InvalidInput;
                request_len = @intCast(file_op.buffer.bytes.len);
                if (request_len == 0) {
                    return self.completeImmediate(op, .{
                        .operation_id = 0,
                        .tag = .file_read_at,
                        .status = .success,
                        .bytes_transferred = 0,
                        .buffer = file_op.buffer,
                        .handle = file_op.file.handle,
                    });
                }
                native_fd = self.nativeForHandle(file_op.file.handle, .file) orelse return error.InvalidInput;
            },
            .file_write_at => |file_op| {
                if (file_op.buffer.used_len > file_op.buffer.bytes.len) return error.InvalidInput;
                if (file_op.buffer.bytes.len == 0) return error.InvalidInput;
                if (file_op.buffer.bytes.len > std.math.maxInt(u32)) return error.InvalidInput;
                request_len = file_op.buffer.used_len;
                if (request_len == 0) return error.InvalidInput;
                native_fd = self.nativeForHandle(file_op.file.handle, .file) orelse return error.InvalidInput;
            },
            .stream_read => |stream_op| {
                if (stream_op.buffer.used_len > stream_op.buffer.bytes.len) return error.InvalidInput;
                if (stream_op.buffer.bytes.len == 0) return error.InvalidInput;
                if (stream_op.buffer.bytes.len > std.math.maxInt(u32)) return error.InvalidInput;
                request_len = @intCast(stream_op.buffer.bytes.len);
                native_fd = self.nativeForHandle(stream_op.stream.handle, .stream) orelse return error.InvalidInput;
            },
            .stream_write => |stream_op| {
                if (stream_op.buffer.used_len > stream_op.buffer.bytes.len) return error.InvalidInput;
                if (stream_op.buffer.bytes.len == 0) return error.InvalidInput;
                if (stream_op.buffer.bytes.len > std.math.maxInt(u32)) return error.InvalidInput;
                request_len = stream_op.buffer.used_len;
                if (request_len == 0) return error.InvalidInput;
                native_fd = self.nativeForHandle(stream_op.stream.handle, .stream) orelse return error.InvalidInput;
            },
            .accept => |accept_op| {
                if (accept_op.stream.handle.index >= self.handle_states.len) return error.InvalidInput;
                native_fd = self.nativeForHandle(accept_op.listener.handle, .listener) orelse return error.InvalidInput;
            },
            .connect => |connect_op| {
                if (connect_op.stream.handle.index >= self.handle_states.len) return error.InvalidInput;
                if (endpointPort(connect_op.endpoint) == 0) return error.InvalidInput;
                if (self.handle_states[connect_op.stream.handle.index] == .open and self.handle_native[connect_op.stream.handle.index] >= 0) return error.InvalidInput;

                const family: u32 = switch (connect_op.endpoint) {
                    .ipv4 => linux.AF.INET,
                    .ipv6 => linux.AF.INET6,
                };
                const sock_rc = std.posix.system.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
                connect_sock = switch (std.posix.errno(sock_rc)) {
                    .SUCCESS => @intCast(sock_rc),
                    else => return error.InvalidInput,
                };
            },
            else => unreachable,
        }

        const slot_index = try self.allocSlot();
        var slot = &self.slots[slot_index];
        assert(slot.state == .free);

        const operation_id = encodeOperationId(slot_index, slot.generation);
        slot.* = .{
            .generation = slot.generation,
            .state = .in_flight,
            .operation_id = operation_id,
            .operation = op,
            .cancel_reason = .none,
            .has_link_timeout = needs_timeout,
            .native_for_cancel = -1,
            .accept_addr_len = 0,
        };
        if (needs_timeout) {
            slot.timeout_spec = timeoutNsToTimespec(timeout_ns.?);
        }

        const main_sqe = self.io_uring.get_sqe() catch {
            self.freeSlot(slot_index);
            if (connect_sock >= 0) std.posix.close(connect_sock);
            return error.WouldBlock;
        };
        main_sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        main_sqe.user_data = encodeUserdata(operation_id, 0);
        if (needs_timeout) {
            main_sqe.flags |= linux.IOSQE_IO_LINK;
        }

        switch (op) {
            .file_read_at => |file_op| {
                slot.native_for_cancel = native_fd;
                main_sqe.prep_read(native_fd, file_op.buffer.bytes[0..request_len], file_op.offset_bytes);
            },
            .file_write_at => |file_op| {
                slot.native_for_cancel = native_fd;
                main_sqe.prep_write(native_fd, file_op.buffer.bytes[0..request_len], file_op.offset_bytes);
            },
            .stream_read => |stream_op| {
                slot.native_for_cancel = native_fd;
                main_sqe.prep_recv(native_fd, stream_op.buffer.bytes[0..request_len], 0);
            },
            .stream_write => |stream_op| {
                slot.native_for_cancel = native_fd;
                main_sqe.prep_send(native_fd, stream_op.buffer.bytes[0..request_len], send_flags);
            },
            .connect => |connect_op| {
                self.handle_states[connect_op.stream.handle.index] = .open;
                self.handle_generations[connect_op.stream.handle.index] = connect_op.stream.handle.generation;
                self.handle_kinds[connect_op.stream.handle.index] = .stream;
                self.handle_native[connect_op.stream.handle.index] = connect_sock;
                self.handle_owned[connect_op.stream.handle.index] = true;

                slot.native_for_cancel = connect_sock;
                slot.connect_addr = SockaddrAnyLinux.fromEndpoint(connect_op.endpoint);
                main_sqe.prep_connect(connect_sock, slot.connect_addr.ptr(), slot.connect_addr.len());
            },
            .accept => {
                slot.native_for_cancel = native_fd;
                slot.accept_addr_len = @intCast(@sizeOf(linux.sockaddr.storage));
                main_sqe.prep_accept(native_fd, @ptrCast(&slot.accept_addr), &slot.accept_addr_len, linux.SOCK.CLOEXEC);
            },
            else => {
                unreachable;
            },
        }

        if (needs_timeout) {
            const timeout_sqe = self.io_uring.get_sqe() catch unreachable;
            timeout_sqe.* = std.mem.zeroes(linux.io_uring_sqe);
            timeout_sqe.prep_link_timeout(&slot.timeout_spec, 0);
            timeout_sqe.user_data = encodeUserdata(operation_id, 1);
        }
        return operation_id;
    }

    /// Drains completion entries without blocking.
    pub fn pump(self: *LinuxIoUringBackend, max_completions: u32) backend.PumpError!u32 {
        if (max_completions == 0) return error.InvalidInput;
        if (self.closed) return 0;

        _ = self.io_uring.submit_and_wait(0) catch return error.Unsupported;

        const completed_cap = self.completed.capacity();
        const completed_len = self.completed.len();
        if (completed_len >= completed_cap) return 0;
        const free_space = completed_cap - completed_len;
        const drain_limit: usize = @min(@as(usize, max_completions), @min(self.cqe_batch.len, free_space));
        if (drain_limit == 0) return 0;
        const copied = self.io_uring.copy_cqes(self.cqe_batch[0..drain_limit], 0) catch return error.Unsupported;
        var pushed: u32 = 0;
        var index: usize = 0;
        while (index < copied) : (index += 1) {
            if (self.processCqe(self.cqe_batch[index])) {
                pushed += 1;
            }
        }
        return pushed;
    }

    fn processCqe(self: *LinuxIoUringBackend, cqe: linux.io_uring_cqe) bool {
        const decoded_ud = decodeUserdata(cqe.user_data);
        const operation_id = decoded_ud.operation_id;
        const subkind = decoded_ud.subkind;
        if (operation_id == wakeup_operation_id and subkind == wakeup_subkind) {
            self.drainWakeupFd();
            self.rearmWakeupPoll();
            return false;
        }
        if (subkind != 0) {
            if (subkind == 1) {
                const decoded = decodeOperationId(operation_id) orelse return false;
                if (decoded.index >= self.slots.len) return false;
                var slot = &self.slots[decoded.index];
                if (slot.generation != decoded.generation) return false;
                if (slot.state != .in_flight) return false;
                if (slot.operation_id != operation_id) return false;

                const res = cqe.res;
                if (res < 0) {
                    const err = errnoFromCqeRes(res);
                    switch (err) {
                        .TIME, .TIMEDOUT => {
                            if (slot.cancel_reason == .none) slot.cancel_reason = .timeout;
                        },
                        else => {},
                    }
                }
            }
            return false;
        }

        const decoded = decodeOperationId(operation_id) orelse return false;
        if (decoded.index >= self.slots.len) return false;
        var slot = &self.slots[decoded.index];
        if (slot.generation != decoded.generation) return false;
        if (slot.state != .in_flight) return false;
        if (slot.operation_id != operation_id) return false;

        const res = cqe.res;
        if (res < 0) {
            const err = errnoFromCqeRes(res);
            slot.completion = mapErrnoToCompletion(operation_id, slot.operation, slot.cancel_reason, slot.has_link_timeout, err);
            self.cleanupFailedOperation(slot);
        } else {
            slot.completion = self.finalizeSuccess(slot, @intCast(res));
        }

        slot.state = .ready;
        self.completed.tryPush(decoded.index) catch unreachable;
        return true;
    }

    fn drainWakeupFd(self: *LinuxIoUringBackend) void {
        if (self.wakeup_fd < 0) return;
        var value: u64 = 0;
        while (true) {
            const buf_ptr: [*]u8 = @ptrCast(&value);
            const rc = std.posix.system.read(self.wakeup_fd, buf_ptr, @sizeOf(u64));
            switch (std.posix.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => break,
                else => break,
            }
        }
    }

    fn rearmWakeupPoll(self: *LinuxIoUringBackend) void {
        if (self.wakeup_fd < 0) return;
        _ = self.io_uring.poll_add(wakeup_user_data, @intCast(self.wakeup_fd), linux.POLL.IN) catch return;
        _ = self.io_uring.submit() catch {};
    }

    fn finalizeSuccess(self: *LinuxIoUringBackend, slot: *Slot, res_u32: u32) types.Completion {
        return switch (slot.operation) {
            .file_read_at => |op| blk: {
                var buffer = op.buffer;
                buffer.used_len = res_u32;
                break :blk .{
                    .operation_id = slot.operation_id,
                    .tag = .file_read_at,
                    .status = .success,
                    .bytes_transferred = res_u32,
                    .buffer = buffer,
                    .handle = op.file.handle,
                };
            },
            .file_write_at => |op| .{
                .operation_id = slot.operation_id,
                .tag = .file_write_at,
                .status = .success,
                .bytes_transferred = res_u32,
                .buffer = op.buffer,
                .handle = op.file.handle,
            },
            .stream_read => |op| blk: {
                var buffer = op.buffer;
                buffer.used_len = res_u32;
                break :blk .{
                    .operation_id = slot.operation_id,
                    .tag = .stream_read,
                    .status = .success,
                    .bytes_transferred = res_u32,
                    .buffer = buffer,
                    .handle = op.stream.handle,
                };
            },
            .stream_write => |op| .{
                .operation_id = slot.operation_id,
                .tag = .stream_write,
                .status = .success,
                .bytes_transferred = res_u32,
                .buffer = op.buffer,
                .handle = op.stream.handle,
            },
            .connect => |op| .{
                .operation_id = slot.operation_id,
                .tag = .connect,
                .status = .success,
                .bytes_transferred = 0,
                .buffer = .{ .bytes = &[_]u8{} },
                .handle = op.stream.handle,
                .endpoint = op.endpoint,
            },
            .accept => |op| blk: {
                const accepted_fd: std.posix.fd_t = @intCast(res_u32);
                if (op.stream.handle.index >= self.handle_states.len) {
                    std.posix.close(accepted_fd);
                    break :blk makeSimpleCompletion(slot.operation_id, slot.operation, .invalid_input, .invalid_input);
                }
                if (self.handle_states[op.stream.handle.index] == .open and self.handle_native[op.stream.handle.index] >= 0) {
                    std.posix.close(accepted_fd);
                    break :blk makeSimpleCompletion(slot.operation_id, slot.operation, .invalid_input, .invalid_input);
                }

                self.handle_states[op.stream.handle.index] = .open;
                self.handle_generations[op.stream.handle.index] = op.stream.handle.generation;
                self.handle_kinds[op.stream.handle.index] = .stream;
                self.handle_native[op.stream.handle.index] = accepted_fd;
                self.handle_owned[op.stream.handle.index] = true;

                break :blk .{
                    .operation_id = slot.operation_id,
                    .tag = .accept,
                    .status = .success,
                    .bytes_transferred = 0,
                    .buffer = .{ .bytes = &[_]u8{} },
                    .handle = op.stream.handle,
                    .endpoint = endpointFromSockaddrStorage(&slot.accept_addr),
                };
            },
            else => makeSimpleCompletion(slot.operation_id, slot.operation, .unsupported, .unsupported),
        };
    }

    fn cleanupFailedOperation(self: *LinuxIoUringBackend, slot: *Slot) void {
        switch (slot.operation) {
            .connect => |op| {
                if (op.stream.handle.index >= self.handle_states.len) return;
                if (self.handle_generations[op.stream.handle.index] != op.stream.handle.generation) return;
                if (self.handle_kinds[op.stream.handle.index] != .stream) return;
                if (self.handle_owned[op.stream.handle.index] and self.handle_native[op.stream.handle.index] >= 0) {
                    closeNativeHandle(.stream, self.handle_native[op.stream.handle.index]);
                }
                self.handle_states[op.stream.handle.index] = .closed;
                self.handle_native[op.stream.handle.index] = -1;
                self.handle_owned[op.stream.handle.index] = false;
            },
            else => {},
        }
    }

    /// Pops one completion if available.
    pub fn poll(self: *LinuxIoUringBackend) ?types.Completion {
        const slot_index = self.completed.tryPop() catch return null;
        const slot = &self.slots[slot_index];
        if (slot.state != .ready) {
            assert(slot.state == .ready);
            return null;
        }
        const completion = slot.completion;
        self.freeSlot(slot_index);
        return completion;
    }

    /// Wakes waiters by writing to the internal eventfd.
    pub fn wakeup(self: *LinuxIoUringBackend) void {
        if (self.wakeup_fd < 0) return;
        var value: u64 = 1;
        const buf_ptr: [*]const u8 = @ptrCast(&value);
        _ = std.posix.system.write(self.wakeup_fd, buf_ptr, @sizeOf(u64));
    }

    /// Blocks for completions, optionally bounded by timeout.
    pub fn waitForCompletions(self: *LinuxIoUringBackend, max_completions: u32, timeout_ns: ?u64) backend.PumpError!u32 {
        if (max_completions == 0) return error.InvalidInput;
        if (self.closed) return 0;

        if (timeout_ns == null) {
            _ = self.io_uring.submit_and_wait(1) catch return error.Unsupported;
            return self.pump(max_completions);
        }

        if (!self.supports_timeout or !self.supports_timeout_remove) return error.Unsupported;

        const internal_operation_id: types.OperationId = encodeInternalOperationId(1);
        const timeout_user_data: u64 = encodeUserdata(internal_operation_id, 3);
        const remove_user_data: u64 = encodeUserdata(internal_operation_id, 4);

        self.wait_timeout_spec = timeoutNsToTimespec(timeout_ns.?);
        const timeout_sqe = self.io_uring.get_sqe() catch return error.Unsupported;
        timeout_sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        timeout_sqe.prep_timeout(&self.wait_timeout_spec, 0, 0);
        timeout_sqe.user_data = timeout_user_data;

        _ = self.io_uring.submit_and_wait(1) catch return error.Unsupported;

        const pumped = try self.pump(max_completions);
        if (pumped == 0) return 0;

        const remove_sqe = self.io_uring.get_sqe() catch return pumped;
        remove_sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        remove_sqe.prep_timeout_remove(timeout_user_data, 0);
        remove_sqe.user_data = remove_user_data;
        _ = self.io_uring.submit() catch {};

        return pumped;
    }

    /// Attempts to cancel one in-flight operation.
    pub fn cancel(self: *LinuxIoUringBackend, operation_id: types.OperationId) backend.CancelError!void {
        if (!self.supports_async_cancel) return error.Unsupported;
        if (self.closed) return error.Closed;
        const decoded = decodeOperationId(operation_id) orelse return error.NotFound;
        if (decoded.index >= self.slots.len) return error.NotFound;
        var slot = &self.slots[decoded.index];
        if (slot.generation != decoded.generation) return error.NotFound;
        if (slot.state != .in_flight) return error.NotFound;
        if (slot.operation_id != operation_id) return error.NotFound;
        if (slot.cancel_reason == .none) slot.cancel_reason = .cancelled;
        self.submitInternalCancel(operation_id);
    }

    /// Requests backend shutdown and cancels in-flight work.
    pub fn close(self: *LinuxIoUringBackend) void {
        if (self.closed) return;
        self.closed = true;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            var slot = &self.slots[index];
            if (slot.state != .in_flight) continue;
            if (slot.cancel_reason == .none) slot.cancel_reason = .closed;
            self.submitInternalCancel(slot.operation_id);
        }

        _ = self.io_uring.submit_and_wait(0) catch {};
    }

    /// Registers runtime handle metadata for io_uring operation prep.
    pub fn registerHandle(self: *LinuxIoUringBackend, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        if (handle.index >= self.handle_states.len) return;
        if (native > std.math.maxInt(std.posix.fd_t)) return;

        self.handle_states[handle.index] = .open;
        self.handle_generations[handle.index] = handle.generation;
        self.handle_kinds[handle.index] = kind;
        self.handle_native[handle.index] = @intCast(native);
        self.handle_owned[handle.index] = owned;
    }

    /// Marks a handle closed and cancels dependent in-flight operations.
    pub fn notifyHandleClosed(self: *LinuxIoUringBackend, handle: types.Handle) void {
        if (handle.index >= self.handle_states.len) return;
        if (self.handle_generations[handle.index] != handle.generation) return;

        self.handle_states[handle.index] = .closed;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            var slot = &self.slots[index];
            if (slot.state != .in_flight) continue;
            if (!operationUsesHandle(slot.operation, handle)) continue;
            if (slot.cancel_reason == .none) slot.cancel_reason = .closed;
            self.submitInternalCancel(slot.operation_id);
        }

        const native = self.handle_native[handle.index];
        if (self.handle_owned[handle.index] and native >= 0) {
            closeNativeHandle(self.handle_kinds[handle.index], native);
            self.handle_native[handle.index] = -1;
            self.handle_owned[handle.index] = false;
        }

        _ = self.io_uring.submit_and_wait(0) catch {};
    }

    /// Returns true while any in-flight operation references `handle`.
    pub fn handleInUse(self: *LinuxIoUringBackend, handle: types.Handle) bool {
        if (handle.index >= self.handle_states.len) return false;
        if (self.handle_generations[handle.index] != handle.generation) return false;
        if (self.handle_states[handle.index] != .open) return false;
        if (self.handle_native[handle.index] < 0) return false;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            const slot = &self.slots[index];
            if (slot.state != .in_flight) continue;
            if (operationUsesHandle(slot.operation, handle)) return true;
        }
        return false;
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *LinuxIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};

const UnsupportedIoUringBackend = struct {
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

    pub fn init(_: std.mem.Allocator, _: config.Config) backend.InitError!UnsupportedIoUringBackend {
        return error.Unsupported;
    }

    pub fn deinit(self: *UnsupportedIoUringBackend) void {
        self.* = undefined;
    }

    pub fn asBackend(self: *UnsupportedIoUringBackend) backend.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn getAllocator(_: *const UnsupportedIoUringBackend) std.mem.Allocator {
        return std.heap.page_allocator;
    }

    pub fn submit(_: *UnsupportedIoUringBackend, _: types.Operation) backend.SubmitError!types.OperationId {
        return error.Unsupported;
    }

    pub fn pump(_: *UnsupportedIoUringBackend, _: u32) backend.PumpError!u32 {
        return error.Unsupported;
    }

    pub fn poll(_: *UnsupportedIoUringBackend) ?types.Completion {
        return null;
    }

    pub fn waitForCompletions(_: *UnsupportedIoUringBackend, _: u32, _: ?u64) backend.PumpError!u32 {
        return error.Unsupported;
    }

    pub fn wakeup(_: *UnsupportedIoUringBackend) void {}

    pub fn cancel(_: *UnsupportedIoUringBackend, _: types.OperationId) backend.CancelError!void {
        return error.Unsupported;
    }

    pub fn close(_: *UnsupportedIoUringBackend) void {}

    pub fn capabilities(_: *const UnsupportedIoUringBackend) types.CapabilityFlags {
        return .{};
    }

    pub fn registerHandle(_: *UnsupportedIoUringBackend, _: types.Handle, _: types.HandleKind, _: types.NativeHandle, _: bool) void {}

    pub fn notifyHandleClosed(_: *UnsupportedIoUringBackend, _: types.Handle) void {}

    pub fn handleInUse(_: *UnsupportedIoUringBackend, _: types.Handle) bool {
        return false;
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *UnsupportedIoUringBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};

test "io_uring backend supports bounded nop/fill completions" {
    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
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

test "io_uring backend supports connect/accept, stream read/write, and stream read timeout" {
    var cfg = config.Config.initForTest(16);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer backend_impl.deinit();

    const listen_rc = std.posix.system.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const listen_fd: std.posix.fd_t = switch (std.posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    errdefer std.posix.close(listen_fd);

    var bind_addr = SockaddrAnyLinux.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = std.posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(bind_rc));

    const listen_rc2 = std.posix.system.listen(listen_fd, 16);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intCast(listen_fd), false);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

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
    while (drain < 16 and (!seen_accept or !seen_connect)) : (drain += 1) {
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
    while (drain < 16 and (!got_write or !got_read)) : (drain += 1) {
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

    if (!backend_impl.capabilities().supports_cancel) {
        backend_impl.notifyHandleClosed(server_stream.handle);
        backend_impl.notifyHandleClosed(client_stream.handle);
        std.posix.close(listen_fd);
        return error.SkipZigTest;
    }

    var cancel_read_bytes: [8]u8 = [_]u8{0} ** 8;
    const cancel_read_buf = types.Buffer{ .bytes = &cancel_read_bytes };
    const cancel_read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = cancel_read_buf,
        .timeout_ns = null,
    } });
    try backend_impl.cancel(cancel_read_id);
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const cancel_completion = backend_impl.poll().?;
    try testing.expectEqual(cancel_read_id, cancel_completion.operation_id);
    try testing.expectEqual(types.OperationTag.stream_read, cancel_completion.tag);
    try testing.expectEqual(types.CompletionStatus.cancelled, cancel_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .cancelled), cancel_completion.err);

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
    const accept_timeout_id = backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = accept_timeout_stream,
        .timeout_ns = 50 * std.time.ns_per_ms,
    } }) catch |err| switch (err) {
        error.Unsupported => {
            try testing.expect(!backend_impl.capabilities().supports_timeouts);
            backend_impl.notifyHandleClosed(server_stream.handle);
            backend_impl.notifyHandleClosed(client_stream.handle);
            std.posix.close(listen_fd);
            return;
        },
        else => return err,
    };
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const accept_timeout_completion = backend_impl.poll() orelse return error.SkipZigTest;
    try testing.expectEqual(accept_timeout_id, accept_timeout_completion.operation_id);
    try testing.expectEqual(types.OperationTag.accept, accept_timeout_completion.tag);
    try testing.expectEqual(types.CompletionStatus.timeout, accept_timeout_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), accept_timeout_completion.err);

    var close_read_bytes: [8]u8 = [_]u8{0} ** 8;
    const close_read_buf = types.Buffer{ .bytes = &close_read_bytes };
    const close_read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = close_read_buf,
        .timeout_ns = null,
    } });
    backend_impl.notifyHandleClosed(server_stream.handle);
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const close_completion = backend_impl.poll().?;
    try testing.expectEqual(close_read_id, close_completion.operation_id);
    try testing.expectEqual(types.OperationTag.stream_read, close_completion.tag);
    try testing.expectEqual(types.CompletionStatus.closed, close_completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .closed), close_completion.err);

    backend_impl.notifyHandleClosed(client_stream.handle);
    std.posix.close(listen_fd);
}

test "io_uring backend maps connection refused on connect" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer backend_impl.deinit();

    const reserve_rc = std.posix.system.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const reserve_fd: std.posix.fd_t = switch (std.posix.errno(reserve_rc)) {
        .SUCCESS => @intCast(reserve_rc),
        else => return error.SkipZigTest,
    };

    var bind_addr = SockaddrAnyLinux.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = std.posix.system.bind(reserve_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(bind_rc));

    const reserved = socketLocalEndpoint(reserve_fd) orelse return error.SkipZigTest;
    const port = endpointPort(reserved);
    try testing.expect(port != 0);
    std.posix.close(reserve_fd);

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

test "io_uring backend closes pending accept when listener handle closes" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer backend_impl.deinit();

    const listen_rc = std.posix.system.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const listen_fd: std.posix.fd_t = switch (std.posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    errdefer std.posix.close(listen_fd);

    var bind_addr = SockaddrAnyLinux.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = std.posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(bind_rc));

    const listen_rc2 = std.posix.system.listen(listen_fd, 16);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(listen_rc2));

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intCast(listen_fd), false);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

    const server_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    const accept_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = server_stream,
        .timeout_ns = null,
    } });

    backend_impl.notifyHandleClosed(listener_handle);
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    const completion = backend_impl.poll() orelse return error.SkipZigTest;
    try testing.expectEqual(accept_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.accept, completion.tag);
    try testing.expectEqual(types.CompletionStatus.closed, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .closed), completion.err);
    try testing.expectEqual(@as(?types.Handle, null), completion.handle);
    try testing.expectEqual(@as(u32, 0), completion.bytes_transferred);

    std.posix.close(listen_fd);
}

test "io_uring backend closes pending stream_write when stream handle closes" {
    var cfg = config.Config.initForTest(32);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer backend_impl.deinit();

    const listen_rc = std.posix.system.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const listen_fd: std.posix.fd_t = switch (std.posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    errdefer std.posix.close(listen_fd);

    var bind_addr = SockaddrAnyLinux.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = std.posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(bind_rc));

    const listen_rc2 = std.posix.system.listen(listen_fd, 16);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intCast(listen_fd), false);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

    const server_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    const client_stream = types.Stream{ .handle = .{ .index = 2, .generation = 1 } };

    const accept_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = server_stream,
        .timeout_ns = null,
    } });
    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = .{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = port } },
        .timeout_ns = null,
    } });
    _ = try backend_impl.waitForCompletions(2, std.time.ns_per_s);

    var saw_accept = false;
    var saw_connect = false;
    var drain: usize = 0;
    while (drain < 32 and (!saw_accept or !saw_connect)) : (drain += 1) {
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

    const server_fd = backend_impl.handle_native[server_stream.handle.index];
    const client_fd = backend_impl.handle_native[client_stream.handle.index];
    if (server_fd < 0 or client_fd < 0) return error.SkipZigTest;

    var small_buf: i32 = 1024;
    std.posix.setsockopt(server_fd, @intCast(std.posix.SOL.SOCKET), @intCast(std.posix.SO.RCVBUF), std.mem.asBytes(&small_buf)) catch {};
    std.posix.setsockopt(client_fd, @intCast(std.posix.SOL.SOCKET), @intCast(std.posix.SO.SNDBUF), std.mem.asBytes(&small_buf)) catch {};

    const getfl_rc = std.posix.system.fcntl(client_fd, std.posix.F.GETFL, @as(usize, 0));
    const flags: i32 = switch (std.posix.errno(getfl_rc)) {
        .SUCCESS => @intCast(getfl_rc),
        else => return error.SkipZigTest,
    };
    const flags_u32: u32 = @bitCast(flags);
    const nonblock_mask: u32 = @as(u32, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const set_flags: usize = @as(usize, flags_u32 | nonblock_mask);
    _ = std.posix.system.fcntl(client_fd, std.posix.F.SETFL, set_flags);

    var fill_bytes: [4096]u8 = [_]u8{0xAB} ** 4096;
    var sent_total: usize = 0;
    const sent_limit: usize = 64 * 1024 * 1024;
    var saw_again = false;
    while (sent_total < sent_limit) {
        const rc = std.posix.system.write(client_fd, &fill_bytes, fill_bytes.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => sent_total += @intCast(rc),
            .AGAIN => {
                saw_again = true;
                break;
            },
            else => return error.SkipZigTest,
        }
    }
    if (!saw_again) return error.SkipZigTest;

    _ = std.posix.system.fcntl(client_fd, std.posix.F.SETFL, @as(usize, flags_u32));

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

    backend_impl.notifyHandleClosed(server_stream.handle);
    std.posix.close(listen_fd);
}

test "io_uring backend allows multiple in-flight reads on one stream" {
    var cfg = config.Config.initForTest(32);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer backend_impl.deinit();

    const listen_rc = std.posix.system.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const listen_fd: std.posix.fd_t = switch (std.posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    errdefer std.posix.close(listen_fd);

    var bind_addr = SockaddrAnyLinux.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = std.posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(bind_rc));

    const listen_rc2 = std.posix.system.listen(listen_fd, 16);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intCast(listen_fd), false);
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
    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = .{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = port } },
        .timeout_ns = null,
    } });

    _ = try backend_impl.waitForCompletions(2, std.time.ns_per_s);
    var saw_accept = false;
    var saw_connect = false;
    var drain: usize = 0;
    while (drain < 32 and (!saw_accept or !saw_connect)) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == accept_id) saw_accept = completion.status == .success;
        if (completion.operation_id == connect_id) saw_connect = completion.status == .success;
    }
    if (!saw_accept or !saw_connect) return error.SkipZigTest;

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
    while (got < 16 and (!got_write or !got_read_a or !got_read_b)) : (got += 1) {
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

    std.posix.close(listen_fd);
}

test "io_uring backend maps connection reset on stream read" {
    var cfg = config.Config.initForTest(16);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer backend_impl.deinit();

    const listen_rc = std.posix.system.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const listen_fd: std.posix.fd_t = switch (std.posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    var listen_fd_to_close: ?std.posix.fd_t = listen_fd;
    errdefer if (listen_fd_to_close) |fd| std.posix.close(fd);

    var bind_addr = SockaddrAnyLinux.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = std.posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(bind_rc));

    const listen_rc2 = std.posix.system.listen(listen_fd, 16);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port = endpointPort(bound);
    try testing.expect(port != 0);

    const Server = struct {
        fn run(server_listen_fd: std.posix.fd_t) void {
            const poll_in: i16 = 0x0001;
            const accept_timeout_ms: i32 = 2000;
            const pfd: std.posix.pollfd = .{ .fd = server_listen_fd, .events = poll_in, .revents = 0 };
            var pfds = [_]std.posix.pollfd{pfd};
            const ready_count = std.posix.poll(&pfds, accept_timeout_ms) catch {
                std.posix.close(server_listen_fd);
                return;
            };
            if (ready_count == 0) {
                std.posix.close(server_listen_fd);
                return;
            }

            const accepted_fd: std.posix.fd_t = while (true) {
                const accept_rc = std.posix.system.accept(server_listen_fd, null, null);
                switch (std.posix.errno(accept_rc)) {
                    .SUCCESS => break @intCast(accept_rc),
                    .INTR => continue,
                    else => {
                        std.posix.close(server_listen_fd);
                        return;
                    },
                }
            };
            defer std.posix.close(accepted_fd);
            defer std.posix.close(server_listen_fd);

            const Linger = extern struct { l_onoff: c_int, l_linger: c_int };
            var linger_opt = Linger{ .l_onoff = 1, .l_linger = 0 };
            std.posix.setsockopt(
                accepted_fd,
                @intCast(std.posix.SOL.SOCKET),
                @intCast(std.posix.SO.LINGER),
                std.mem.asBytes(&linger_opt),
            ) catch {};
        }
    };

    var server_thread = try std.Thread.spawn(.{}, Server.run, .{listen_fd});
    listen_fd_to_close = null;
    defer server_thread.join();

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
    while (drain < 16 and !saw_connect) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id != connect_id) continue;
        saw_connect = true;
        try testing.expectEqual(types.OperationTag.connect, completion.tag);
        try testing.expectEqual(types.CompletionStatus.success, completion.status);
    }
    try testing.expect(saw_connect);

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

test "io_uring backend maps broken pipe on stream write after shutdown send" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer backend_impl.deinit();

    const listen_rc = std.posix.system.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const listen_fd: std.posix.fd_t = switch (std.posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    defer std.posix.close(listen_fd);

    var bind_addr = SockaddrAnyLinux.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = std.posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(bind_rc));

    const listen_rc2 = std.posix.system.listen(listen_fd, 16);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
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
    while (drain < 16 and !saw_connect) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id != connect_id) continue;
        saw_connect = true;
        try testing.expectEqual(types.OperationTag.connect, completion.tag);
        try testing.expectEqual(types.CompletionStatus.success, completion.status);
    }
    try testing.expect(saw_connect);

    const client_fd = backend_impl.handle_native[client_stream.handle.index];
    try testing.expect(client_fd >= 0);
    const shutdown_rc = std.posix.system.shutdown(client_fd, linux.SHUT.WR);
    if (std.posix.errno(shutdown_rc) != .SUCCESS) return error.SkipZigTest;

    var write_bytes: [2]u8 = .{ 'h', 'i' };
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(2);
    const write_id = try backend_impl.submit(.{ .stream_write = .{
        .stream = client_stream,
        .buffer = write_buf,
        .timeout_ns = 2 * std.time.ns_per_s,
    } });
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);

    var completion_opt: ?types.Completion = null;
    drain = 0;
    while (drain < 16 and completion_opt == null) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == write_id) {
            completion_opt = completion;
            break;
        }
    }
    const completion = completion_opt orelse return error.SkipZigTest;
    try testing.expectEqual(write_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.stream_write, completion.tag);
    try testing.expectEqual(types.CompletionStatus.broken_pipe, completion.status);
    try testing.expectEqual(@as(?types.CompletionErrorTag, .broken_pipe), completion.err);

    backend_impl.notifyHandleClosed(client_stream.handle);
}

test "io_uring backend supports file write/read via adopted handle" {
    var cfg = config.Config.initForTest(4);
    cfg.backend_kind = .linux_io_uring;

    if (!io_caps.linuxBackendEnabled()) {
        try testing.expectError(error.Unsupported, IoUringBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = IoUringBackend.init(testing.allocator, cfg) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer backend_impl.deinit();

    const filename = "static_io_io_uring_file_io.tmp";
    defer _ = std.posix.system.unlink(filename);

    const open_flags: linux.O = .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .CLOEXEC = true,
    };
    const open_rc = std.posix.system.open(filename, open_flags, @as(linux.mode_t, 0o600));
    const fd: std.posix.fd_t = switch (std.posix.errno(open_rc)) {
        .SUCCESS => @intCast(open_rc),
        else => return error.SkipZigTest,
    };

    const file_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(file_handle, .file, @intCast(fd), true);
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
