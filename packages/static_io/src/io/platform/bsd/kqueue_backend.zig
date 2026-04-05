//! BSD/macOS kqueue backend.
//!
//! This backend provides a bounded reactor for streams/listeners via `kqueue`,
//! plus a bounded threaded fallback for file operations (`pread`/`pwrite`).
//!
//! Enabled only when:
//! - `enable_os_backends=true`
//! - `single_threaded=false`
//! - target OS is macOS/BSD

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const io_caps = @import("../../caps.zig");
const static_queues = @import("static_queues");

const backend = @import("../../backend.zig");
const config = @import("../../config.zig");
const operation_helpers = @import("../../operation_helpers.zig");
const threaded_backend = @import("../../threaded_backend.zig");
const types = @import("../../types.zig");
const error_map = @import("../../error_map.zig");
const static_net_native = @import("static_net_native");

const posix = std.posix;
const elapsedSince = operation_helpers.elapsedSince;
const makeSimpleCompletion = operation_helpers.makeSimpleCompletion;
const operationTimeoutNs = operation_helpers.operationTimeoutNs;
const operationUsesHandle = operation_helpers.operationUsesHandle;
const validateOperation = operation_helpers.validateOperation;
const SockaddrAnyPosix = static_net_native.posix.SockaddrAny;
const socketLocalEndpoint = static_net_native.posix.socketLocalEndpoint;
const socketPeerEndpoint = static_net_native.posix.socketPeerEndpoint;

const IdQueue = static_queues.ring_buffer.RingBuffer(u32);
const file_backend_flag: u32 = 0x8000_0000;
const file_wake_udata: usize = std.math.maxInt(usize);
const user_wake_ident: usize = 1;
const operation_index_bits: u5 = 16;
const operation_index_mask: u32 = (1 << operation_index_bits) - 1;
const operation_generation_mask: u32 = 0x7FFF;

fn isBsdLike(tag: std.Target.Os.Tag) bool {
    return switch (tag) {
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };
}

pub const KqueueBackend = if (isBsdLike(builtin.os.tag)) BsdKqueueBackend else UnsupportedKqueueBackend;

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

const WaitKind = enum(u8) {
    none,
    read,
    write,
};

const Slot = struct {
    generation: u32 = 1,
    state: SlotState = .free,
    operation_id: types.OperationId = 0,
    operation: types.Operation = undefined,
    completion: types.Completion = undefined,
    cancel_reason: CancelReason = .none,
    wait_kind: WaitKind = .none,
    has_timer: bool = false,
    native_fd: posix.fd_t = -1,
    connect_addr: SockaddrAnyPosix = undefined,
};

const HandleState = enum(u8) {
    free,
    open,
    closed,
};

const DecodedOperationId = struct {
    index: u32,
    generation: u32,
};

fn encodeOperationId(slot_index: u32, generation: u32) types.OperationId {
    const generation_bits = generation & operation_generation_mask;
    return (generation_bits << operation_index_bits) | (slot_index & operation_index_mask);
}

fn decodeOperationId(operation_id: types.OperationId) ?DecodedOperationId {
    // Reserve the high bit for the threaded file-backend namespace.
    if ((operation_id & file_backend_flag) != 0) return null;
    return .{
        .index = operation_id & operation_index_mask,
        .generation = (operation_id >> operation_index_bits) & operation_generation_mask,
    };
}

fn nextGeneration(current: u32) u32 {
    var next = (current + 1) & operation_generation_mask;
    if (next == 0) next = 1;
    return next;
}

fn timeoutNsToTimespec(timeout_ns: u64) posix.timespec {
    const ns_per_s: u64 = std.time.ns_per_s;
    const sec_u64: u64 = timeout_ns / ns_per_s;
    const sec_max: u64 = std.math.maxInt(isize);
    const sec: isize = if (sec_u64 > sec_max) std.math.maxInt(isize) else @intCast(sec_u64);
    return .{
        .sec = sec,
        .nsec = @intCast(timeout_ns % ns_per_s),
    };
}

fn setNonblocking(fd: posix.fd_t) void {
    const getfl_rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    const flags: i32 = switch (posix.errno(getfl_rc)) {
        .SUCCESS => @intCast(getfl_rc),
        else => return,
    };
    const flags_u32: u32 = @bitCast(flags);
    const nonblock_mask: u32 = @as(u32, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    const set_flags: usize = @as(usize, flags_u32 | nonblock_mask);
    const setfl_rc = posix.system.fcntl(fd, posix.F.SETFL, set_flags);
    _ = setfl_rc;
}

fn setCloexec(fd: posix.fd_t) void {
    const getfd_rc = posix.system.fcntl(fd, posix.F.GETFD, @as(usize, 0));
    const flags: i32 = switch (posix.errno(getfd_rc)) {
        .SUCCESS => @intCast(getfd_rc),
        else => return,
    };
    const flags_u32: u32 = @bitCast(flags);
    const set_flags: usize = @as(usize, flags_u32 | posix.FD_CLOEXEC);
    const setfd_rc = posix.system.fcntl(fd, posix.F.SETFD, set_flags);
    _ = setfd_rc;
}

fn configureSocket(fd: posix.fd_t) void {
    setNonblocking(fd);
    setCloexec(fd);
    if (@hasDecl(posix.SO, "NOSIGPIPE")) {
        var one: i32 = 1;
        posix.setsockopt(fd, @intCast(posix.SOL.SOCKET), @intCast(posix.SO.NOSIGPIPE), std.mem.asBytes(&one)) catch {};
    }
}

fn closeNativeHandle(kind: types.HandleKind, native: posix.fd_t) void {
    _ = kind;
    if (native < 0) return;
    posix.close(native);
}

fn keventCall(
    kq_fd: posix.fd_t,
    changelist: []const posix.Kevent,
    eventlist: []posix.Kevent,
    timeout: ?*const posix.timespec,
) backend.PumpError!usize {
    return switch (comptime builtin.os.tag) {
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly => blk: {
            while (true) {
                const rc = posix.system.kevent(
                    kq_fd,
                    changelist.ptr,
                    std.math.cast(i32, changelist.len) orelse return error.InvalidInput,
                    eventlist.ptr,
                    std.math.cast(i32, eventlist.len) orelse return error.InvalidInput,
                    timeout,
                );
                switch (posix.errno(rc)) {
                    .SUCCESS => break :blk @intCast(rc),
                    .INTR => continue,
                    else => return error.Unsupported,
                }
            }
        },
        else => error.Unsupported,
    };
}

fn addKevent(kq_fd: posix.fd_t, change: posix.Kevent) backend.SubmitError!void {
    var changes = [_]posix.Kevent{change};
    _ = keventCall(kq_fd, &changes, &.{}, null) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.Unsupported => return error.Unsupported,
    };
}

fn deleteKevent(kq_fd: posix.fd_t, ident: usize, filter: i16) void {
    const change: posix.Kevent = .{
        .ident = ident,
        .filter = filter,
        .flags = std.c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    var changes = [_]posix.Kevent{change};
    _ = keventCall(kq_fd, &changes, &.{}, null) catch {};
}

const BsdKqueueBackend = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    kq_fd: posix.fd_t,
    events: []posix.Kevent,

    slots: []Slot,
    free_slots: []u32,
    free_len: u32,
    completed: IdQueue,

    handle_states: []HandleState,
    handle_generations: []u32,
    handle_kinds: []types.HandleKind,
    handle_native: []posix.fd_t,
    handle_owned: []bool,

    pending_read: []u32,
    pending_write: []u32,
    pending_accept: []u32,
    pending_connect: []u32,

    file_backend: threaded_backend.ThreadedBackend,
    file_wake_fd: posix.fd_t = -1,
    file_in_flight: u32 = 0,

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

    /// Initializes kqueue backend state and threaded file fallback.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!BsdKqueueBackend {
        if (!io_caps.bsdBackendEnabled(builtin.os.tag)) return error.Unsupported;
        if (cfg.backend_kind != .bsd_kqueue and cfg.backend_kind != .platform) return error.Unsupported;

        config.validate(cfg) catch |cfg_err| switch (cfg_err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
        };

        const kq_rc = posix.system.kqueue();
        const kq_fd: posix.fd_t = switch (posix.errno(kq_rc)) {
            .SUCCESS => @intCast(kq_rc),
            else => return error.Unsupported,
        };
        errdefer posix.close(kq_fd);

        const events = allocator.alloc(posix.Kevent, cfg.max_in_flight) catch return error.OutOfMemory;
        errdefer allocator.free(events);

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

        const handle_states = allocator.alloc(HandleState, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_states);
        @memset(handle_states, .free);

        const handle_generations = allocator.alloc(u32, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_generations);
        @memset(handle_generations, 0);

        const handle_kinds = allocator.alloc(types.HandleKind, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_kinds);
        @memset(handle_kinds, .file);

        const handle_native = allocator.alloc(posix.fd_t, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_native);
        @memset(handle_native, -1);

        const handle_owned = allocator.alloc(bool, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handle_owned);
        @memset(handle_owned, false);

        const pending_read = allocator.alloc(u32, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(pending_read);
        @memset(pending_read, 0);

        const pending_write = allocator.alloc(u32, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(pending_write);
        @memset(pending_write, 0);

        const pending_accept = allocator.alloc(u32, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(pending_accept);
        @memset(pending_accept, 0);

        const pending_connect = allocator.alloc(u32, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(pending_connect);
        @memset(pending_connect, 0);

        var file_backend = threaded_backend.ThreadedBackend.init(allocator, cfg) catch return error.Unsupported;
        errdefer file_backend.deinit();

        var file_wake_fd: posix.fd_t = -1;
        if (file_backend.completionWakeFd()) |wake_fd| {
            const change: posix.Kevent = .{
                .ident = @intCast(wake_fd),
                .filter = std.c.EVFILT.READ,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = file_wake_udata,
            };
            if (addKevent(kq_fd, change)) |_| {
                file_wake_fd = wake_fd;
            } else |_| {}
        }

        const user_wake_change: posix.Kevent = .{
            .ident = user_wake_ident,
            .filter = std.c.EVFILT.USER,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        addKevent(kq_fd, user_wake_change) catch return error.Unsupported;

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .kq_fd = kq_fd,
            .events = events,
            .slots = slots,
            .free_slots = free_slots,
            .free_len = cfg.max_in_flight,
            .completed = completed,
            .handle_states = handle_states,
            .handle_generations = handle_generations,
            .handle_kinds = handle_kinds,
            .handle_native = handle_native,
            .handle_owned = handle_owned,
            .pending_read = pending_read,
            .pending_write = pending_write,
            .pending_accept = pending_accept,
            .pending_connect = pending_connect,
            .file_backend = file_backend,
            .file_wake_fd = file_wake_fd,
        };
    }

    /// Releases kqueue resources and backend-owned allocations.
    pub fn deinit(self: *BsdKqueueBackend) void {
        self.file_backend.deinit();
        self.completed.deinit();
        self.allocator.free(self.pending_connect);
        self.allocator.free(self.pending_accept);
        self.allocator.free(self.pending_write);
        self.allocator.free(self.pending_read);
        self.allocator.free(self.handle_owned);
        self.allocator.free(self.handle_native);
        self.allocator.free(self.handle_kinds);
        self.allocator.free(self.handle_generations);
        self.allocator.free(self.handle_states);
        self.allocator.free(self.free_slots);
        self.allocator.free(self.slots);
        self.allocator.free(self.events);
        posix.close(self.kq_fd);
        self.* = undefined;
    }

    /// Returns a type-erased backend interface for runtime dispatch.
    pub fn asBackend(self: *BsdKqueueBackend) backend.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Returns allocator used by backend-owned memory.
    pub fn getAllocator(self: *const BsdKqueueBackend) std.mem.Allocator {
        return self.allocator;
    }

    /// Returns backend capability flags.
    pub fn capabilities(self: *const BsdKqueueBackend) types.CapabilityFlags {
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

    fn allocSlot(self: *BsdKqueueBackend) backend.SubmitError!u32 {
        assert(self.free_len <= self.free_slots.len);
        if (self.free_len == 0) return error.WouldBlock;
        self.free_len -= 1;
        const slot_index = self.free_slots[self.free_len];
        assert(slot_index < self.slots.len);
        assert(self.slots[slot_index].state == .free);
        return slot_index;
    }

    fn freeSlot(self: *BsdKqueueBackend, slot_index: u32) void {
        assert(slot_index < self.slots.len);
        assert(self.free_len < self.free_slots.len);
        const next_gen = nextGeneration(self.slots[slot_index].generation);
        self.slots[slot_index] = .{ .generation = next_gen };
        self.free_slots[self.free_len] = slot_index;
        self.free_len += 1;
        assert(self.free_len <= self.free_slots.len);
    }

    fn pushReady(self: *BsdKqueueBackend, slot_index: u32) void {
        self.slots[slot_index].state = .ready;
        self.completed.tryPush(slot_index) catch unreachable;
    }

    fn completeImmediate(self: *BsdKqueueBackend, op: types.Operation, completion: types.Completion) backend.SubmitError!types.OperationId {
        const slot_index = try self.allocSlot();
        var slot = &self.slots[slot_index];
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
            .wait_kind = .none,
            .has_timer = false,
            .native_fd = -1,
        };
        self.completed.tryPush(slot_index) catch unreachable;
        return operation_id;
    }

    fn armRead(self: *BsdKqueueBackend, fd: posix.fd_t, operation_id: types.OperationId) backend.SubmitError!void {
        const change: posix.Kevent = .{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = @intCast(operation_id),
        };
        try addKevent(self.kq_fd, change);
    }

    fn armWrite(self: *BsdKqueueBackend, fd: posix.fd_t, operation_id: types.OperationId) backend.SubmitError!void {
        const change: posix.Kevent = .{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.WRITE,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = @intCast(operation_id),
        };
        try addKevent(self.kq_fd, change);
    }

    fn armTimer(self: *BsdKqueueBackend, operation_id: types.OperationId, timeout_ns: u64) backend.SubmitError!void {
        if (timeout_ns == 0) return;

        var fflags: u32 = 0;
        var data: isize = 0;
        if (@hasDecl(std.c.NOTE, "NSECONDS") and timeout_ns <= std.math.maxInt(isize)) {
            fflags = std.c.NOTE.NSECONDS;
            data = @intCast(timeout_ns);
        } else {
            const timeout_ms_u64 = std.math.divCeil(u64, timeout_ns, std.time.ns_per_ms) catch return error.InvalidInput;
            if (timeout_ms_u64 == 0) return;
            if (timeout_ms_u64 > std.math.maxInt(isize)) return error.InvalidInput;
            data = @intCast(timeout_ms_u64);
        }

        const change: posix.Kevent = .{
            .ident = @intCast(operation_id),
            .filter = std.c.EVFILT.TIMER,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = fflags,
            .data = data,
            .udata = @intCast(operation_id),
        };
        try addKevent(self.kq_fd, change);
    }

    fn disarmSlot(self: *BsdKqueueBackend, slot: *Slot) void {
        if (slot.wait_kind != .none and slot.native_fd >= 0) {
            const filter: i16 = switch (slot.wait_kind) {
                .read => std.c.EVFILT.READ,
                .write => std.c.EVFILT.WRITE,
                .none => unreachable,
            };
            deleteKevent(self.kq_fd, @intCast(slot.native_fd), filter);
            slot.wait_kind = .none;
        }
        if (slot.has_timer) {
            deleteKevent(self.kq_fd, @intCast(slot.operation_id), std.c.EVFILT.TIMER);
            slot.has_timer = false;
        }
    }

    fn cancelSlot(self: *BsdKqueueBackend, slot_index: u32, reason: CancelReason) void {
        var slot = &self.slots[slot_index];
        if (slot.state != .in_flight) return;
        if (slot.cancel_reason == .none) slot.cancel_reason = reason;

        switch (slot.operation) {
            .stream_read => |op| if (op.stream.handle.index < self.pending_read.len and self.pending_read[op.stream.handle.index] == slot_index + 1) {
                self.pending_read[op.stream.handle.index] = 0;
            },
            .stream_write => |op| if (op.stream.handle.index < self.pending_write.len and self.pending_write[op.stream.handle.index] == slot_index + 1) {
                self.pending_write[op.stream.handle.index] = 0;
            },
            .accept => |op| if (op.listener.handle.index < self.pending_accept.len and self.pending_accept[op.listener.handle.index] == slot_index + 1) {
                self.pending_accept[op.listener.handle.index] = 0;
            },
            .connect => |op| if (op.stream.handle.index < self.pending_connect.len and self.pending_connect[op.stream.handle.index] == slot_index + 1) {
                self.pending_connect[op.stream.handle.index] = 0;
            },
            else => {},
        }

        self.disarmSlot(slot);

        if (slot.operation == .connect) {
            const op = slot.operation.connect;
            if (op.stream.handle.index < self.handle_states.len and self.handle_generations[op.stream.handle.index] == op.stream.handle.generation) {
                if (self.handle_owned[op.stream.handle.index] and self.handle_native[op.stream.handle.index] >= 0) {
                    closeNativeHandle(.stream, self.handle_native[op.stream.handle.index]);
                }
                self.handle_states[op.stream.handle.index] = .closed;
                self.handle_native[op.stream.handle.index] = -1;
                self.handle_owned[op.stream.handle.index] = false;
            }
        }

        const completion: types.Completion = switch (slot.cancel_reason) {
            .timeout => makeSimpleCompletion(slot.operation_id, slot.operation, .timeout, .timeout),
            .closed => makeSimpleCompletion(slot.operation_id, slot.operation, .closed, .closed),
            .cancelled => makeSimpleCompletion(slot.operation_id, slot.operation, .cancelled, .cancelled),
            .none => makeSimpleCompletion(slot.operation_id, slot.operation, .cancelled, .cancelled),
        };
        slot.completion = completion;
        self.pushReady(slot_index);
    }

    fn cleanupConnectHandle(self: *BsdKqueueBackend, handle: types.Handle) void {
        if (handle.index >= self.handle_states.len) return;
        if (self.handle_generations[handle.index] != handle.generation) return;
        if (self.handle_owned[handle.index] and self.handle_native[handle.index] >= 0) {
            closeNativeHandle(.stream, self.handle_native[handle.index]);
        }
        self.handle_states[handle.index] = .closed;
        self.handle_native[handle.index] = -1;
        self.handle_owned[handle.index] = false;
    }

    pub fn submit(self: *BsdKqueueBackend, op: types.Operation) backend.SubmitError!types.OperationId {
        if (self.closed) return error.Closed;

        const checked_op = try validateOperation(op);

        if (checked_op == .file_read_at or checked_op == .file_write_at) {
            self.file_in_flight += 1;
            const inner_id = self.file_backend.submit(checked_op) catch |err| {
                self.file_in_flight -= 1;
                return err;
            };
            assert((inner_id & file_backend_flag) == 0);
            return inner_id | file_backend_flag;
        }

        const timeout_ns = operationTimeoutNs(checked_op);
        if (timeout_ns) |ns| {
            if (ns == 0) {
                return self.completeImmediate(checked_op, makeSimpleCompletion(0, checked_op, .timeout, .timeout));
            }
        }

        const slot_index = try self.allocSlot();
        errdefer self.freeSlot(slot_index);

        var slot = &self.slots[slot_index];
        assert(slot.state == .free);

        const operation_id = encodeOperationId(slot_index, slot.generation);
        slot.* = .{
            .generation = slot.generation,
            .state = .in_flight,
            .operation_id = operation_id,
            .operation = checked_op,
            .completion = undefined,
            .cancel_reason = .none,
            .wait_kind = .none,
            .has_timer = false,
            .native_fd = -1,
        };

        if (timeout_ns) |ns| {
            try self.armTimer(operation_id, ns);
            slot.has_timer = ns != 0;
        }

        switch (checked_op) {
            .nop => return self.completeImmediate(checked_op, .{
                .operation_id = 0,
                .tag = .nop,
                .status = .success,
                .bytes_transferred = 0,
                .buffer = checked_op.nop,
            }),
            .fill => |fill_op| {
                var buffer = fill_op.buffer;
                const want: u32 = @min(fill_op.len, buffer.capacity());
                @memset(buffer.bytes[0..want], fill_op.byte);
                buffer.used_len = want;
                return self.completeImmediate(checked_op, .{
                    .operation_id = 0,
                    .tag = .fill,
                    .status = .success,
                    .bytes_transferred = want,
                    .buffer = buffer,
                });
            },
            .stream_read => |read_op| {
                if (read_op.stream.handle.index >= self.handle_states.len) {
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return operation_id;
                }
                if (self.pending_read[read_op.stream.handle.index] != 0) return error.WouldBlock;

                const fd = self.handle_native[read_op.stream.handle.index];
                if (fd < 0) {
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return operation_id;
                }
                slot.native_fd = fd;

                const recv_rc = posix.system.recv(fd, read_op.buffer.bytes.ptr, read_op.buffer.bytes.len, 0);
                const recv_err = posix.errno(recv_rc);
                switch (recv_err) {
                    .SUCCESS => {
                        const n: usize = @intCast(recv_rc);
                        var buffer = read_op.buffer;
                        buffer.used_len = @intCast(n);
                        slot.completion = .{
                            .operation_id = operation_id,
                            .tag = .stream_read,
                            .status = .success,
                            .bytes_transferred = @intCast(n),
                            .buffer = buffer,
                            .handle = read_op.stream.handle,
                        };
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                    .AGAIN => {},
                    else => {
                        const mapped = error_map.fromPosixErrno(recv_err);
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                }

                try self.armRead(fd, operation_id);
                slot.wait_kind = .read;
                self.pending_read[read_op.stream.handle.index] = slot_index + 1;
                return operation_id;
            },
            .stream_write => |write_op| {
                if (write_op.stream.handle.index >= self.handle_states.len) {
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return operation_id;
                }
                if (self.pending_write[write_op.stream.handle.index] != 0) return error.WouldBlock;

                const fd = self.handle_native[write_op.stream.handle.index];
                if (fd < 0) {
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return operation_id;
                }
                slot.native_fd = fd;

                const write_slice = write_op.buffer.usedSlice();
                const send_rc = posix.system.send(fd, write_slice.ptr, write_slice.len, 0);
                const send_err = posix.errno(send_rc);
                switch (send_err) {
                    .SUCCESS => {
                        const n: usize = @intCast(send_rc);
                        slot.completion = .{
                            .operation_id = operation_id,
                            .tag = .stream_write,
                            .status = .success,
                            .bytes_transferred = @intCast(n),
                            .buffer = write_op.buffer,
                            .handle = write_op.stream.handle,
                        };
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                    .AGAIN => {},
                    else => {
                        const mapped = error_map.fromPosixErrno(send_err);
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                }

                try self.armWrite(fd, operation_id);
                slot.wait_kind = .write;
                self.pending_write[write_op.stream.handle.index] = slot_index + 1;
                return operation_id;
            },
            .accept => |accept_op| {
                if (accept_op.listener.handle.index >= self.handle_states.len) {
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return operation_id;
                }
                if (self.pending_accept[accept_op.listener.handle.index] != 0) return error.WouldBlock;

                const fd = self.handle_native[accept_op.listener.handle.index];
                if (fd < 0) {
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return operation_id;
                }
                slot.native_fd = fd;

                const accept_rc = posix.system.accept(fd, null, null);
                const accept_err = posix.errno(accept_rc);
                switch (accept_err) {
                    .SUCCESS => {
                        const accepted_fd: posix.fd_t = @intCast(accept_rc);
                        configureSocket(accepted_fd);
                        const peer_endpoint = socketPeerEndpoint(accepted_fd);

                        if (accept_op.stream.handle.index >= self.handle_states.len) {
                            posix.close(accepted_fd);
                            slot.completion = makeSimpleCompletion(operation_id, op, .invalid_input, .invalid_input);
                            self.disarmSlot(slot);
                            self.pushReady(slot_index);
                            return operation_id;
                        }
                        if (self.handle_states[accept_op.stream.handle.index] == .open and self.handle_native[accept_op.stream.handle.index] >= 0) {
                            posix.close(accepted_fd);
                            slot.completion = makeSimpleCompletion(operation_id, op, .invalid_input, .invalid_input);
                            self.disarmSlot(slot);
                            self.pushReady(slot_index);
                            return operation_id;
                        }

                        self.handle_states[accept_op.stream.handle.index] = .open;
                        self.handle_generations[accept_op.stream.handle.index] = accept_op.stream.handle.generation;
                        self.handle_kinds[accept_op.stream.handle.index] = .stream;
                        self.handle_native[accept_op.stream.handle.index] = accepted_fd;
                        self.handle_owned[accept_op.stream.handle.index] = true;

                        slot.completion = .{
                            .operation_id = operation_id,
                            .tag = .accept,
                            .status = .success,
                            .bytes_transferred = 0,
                            .buffer = .{ .bytes = &[_]u8{} },
                            .handle = accept_op.stream.handle,
                            .endpoint = peer_endpoint,
                        };
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                    .AGAIN => {},
                    else => {
                        const mapped = error_map.fromPosixErrno(accept_err);
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                }

                try self.armRead(fd, operation_id);
                slot.wait_kind = .read;
                self.pending_accept[accept_op.listener.handle.index] = slot_index + 1;
                return operation_id;
            },
            .connect => |connect_op| {
                if (connect_op.stream.handle.index >= self.handle_states.len) {
                    slot.completion = makeSimpleCompletion(operation_id, checked_op, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return operation_id;
                }
                if (self.pending_connect[connect_op.stream.handle.index] != 0) return error.WouldBlock;

                const family: u32 = switch (connect_op.endpoint) {
                    .ipv4 => posix.AF.INET,
                    .ipv6 => posix.AF.INET6,
                };
                const sock_rc = posix.system.socket(family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
                const sock_err = posix.errno(sock_rc);
                const sock: posix.fd_t = switch (sock_err) {
                    .SUCCESS => @intCast(sock_rc),
                    else => {
                        const mapped = error_map.fromPosixErrno(sock_err);
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                };
                errdefer posix.close(sock);
                configureSocket(sock);

                if (self.handle_states[connect_op.stream.handle.index] == .open and self.handle_native[connect_op.stream.handle.index] >= 0) {
                    slot.completion = makeSimpleCompletion(operation_id, op, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return operation_id;
                }

                // Store the socket now so cancellation/close can clean it up.
                self.handle_states[connect_op.stream.handle.index] = .open;
                self.handle_generations[connect_op.stream.handle.index] = connect_op.stream.handle.generation;
                self.handle_kinds[connect_op.stream.handle.index] = .stream;
                self.handle_native[connect_op.stream.handle.index] = sock;
                self.handle_owned[connect_op.stream.handle.index] = true;

                slot.native_fd = sock;

                slot.connect_addr = SockaddrAnyPosix.fromEndpoint(connect_op.endpoint);
                const connect_rc = posix.system.connect(sock, slot.connect_addr.ptr(), slot.connect_addr.len());
                const connect_err = posix.errno(connect_rc);
                switch (connect_err) {
                    .SUCCESS => {
                        slot.completion = .{
                            .operation_id = operation_id,
                            .tag = .connect,
                            .status = .success,
                            .bytes_transferred = 0,
                            .buffer = .{ .bytes = &[_]u8{} },
                            .handle = connect_op.stream.handle,
                            .endpoint = connect_op.endpoint,
                        };
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                    .INPROGRESS => {},
                    else => {
                        const mapped = error_map.fromPosixErrno(connect_err);
                        self.cleanupConnectHandle(connect_op.stream.handle);
                        slot.completion = makeSimpleCompletion(operation_id, checked_op, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return operation_id;
                    },
                }

                try self.armWrite(sock, operation_id);
                slot.wait_kind = .write;
                self.pending_connect[connect_op.stream.handle.index] = slot_index + 1;
                return operation_id;
            },
            else => unreachable,
        }
    }

    fn processEvent(self: *BsdKqueueBackend, kev: posix.Kevent) bool {
        if (kev.udata == file_wake_udata) return false;
        if (kev.udata == 0) return false;
        const operation_id: types.OperationId = @intCast(kev.udata);
        const decoded = decodeOperationId(operation_id) orelse return false;
        if (decoded.index >= self.slots.len) return false;
        const slot_index: u32 = @intCast(decoded.index);
        var slot = &self.slots[slot_index];
        if (slot.generation != decoded.generation) return false;
        if (slot.state != .in_flight) return false;
        if (slot.operation_id != operation_id) return false;

        if (kev.filter == std.c.EVFILT.TIMER) {
            self.cancelSlot(slot_index, .timeout);
            return true;
        }

        if ((kev.flags & std.c.EV.ERROR) != 0) {
            self.cancelSlot(slot_index, .closed);
            return true;
        }

        switch (slot.operation) {
            .stream_read => |op| {
                self.pending_read[op.stream.handle.index] = 0;
                slot.wait_kind = .none;

                const recv_rc = posix.system.recv(slot.native_fd, op.buffer.bytes.ptr, op.buffer.bytes.len, 0);
                const recv_err = posix.errno(recv_rc);
                switch (recv_err) {
                    .SUCCESS => {
                        const n: usize = @intCast(recv_rc);
                        var buffer = op.buffer;
                        buffer.used_len = @intCast(n);
                        slot.completion = .{
                            .operation_id = slot.operation_id,
                            .tag = .stream_read,
                            .status = .success,
                            .bytes_transferred = @intCast(n),
                            .buffer = buffer,
                            .handle = op.stream.handle,
                        };
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return true;
                    },
                    .AGAIN => {
                        self.pending_read[op.stream.handle.index] = slot_index + 1;
                        slot.wait_kind = .read;
                        self.armRead(slot.native_fd, slot.operation_id) catch {};
                        return false;
                    },
                    else => {
                        const mapped = error_map.fromPosixErrno(recv_err);
                        slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return true;
                    },
                }
            },
            .stream_write => |op| {
                self.pending_write[op.stream.handle.index] = 0;
                slot.wait_kind = .none;

                if (op.buffer.used_len == 0) {
                    slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, .invalid_input, .invalid_input);
                    self.disarmSlot(slot);
                    self.pushReady(slot_index);
                    return true;
                }

                const write_slice = op.buffer.usedSlice();
                const send_rc = posix.system.send(slot.native_fd, write_slice.ptr, write_slice.len, 0);
                const send_err = posix.errno(send_rc);
                switch (send_err) {
                    .SUCCESS => {
                        const n: usize = @intCast(send_rc);
                        slot.completion = .{
                            .operation_id = slot.operation_id,
                            .tag = .stream_write,
                            .status = .success,
                            .bytes_transferred = @intCast(n),
                            .buffer = op.buffer,
                            .handle = op.stream.handle,
                        };
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return true;
                    },
                    .AGAIN => {
                        self.pending_write[op.stream.handle.index] = slot_index + 1;
                        slot.wait_kind = .write;
                        self.armWrite(slot.native_fd, slot.operation_id) catch {};
                        return false;
                    },
                    else => {
                        const mapped = error_map.fromPosixErrno(send_err);
                        slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return true;
                    },
                }
            },
            .accept => |op| {
                self.pending_accept[op.listener.handle.index] = 0;
                slot.wait_kind = .none;

                const accept_rc = posix.system.accept(slot.native_fd, null, null);
                const accept_err = posix.errno(accept_rc);
                switch (accept_err) {
                    .SUCCESS => {
                        const accepted_fd: posix.fd_t = @intCast(accept_rc);
                        configureSocket(accepted_fd);
                        const peer_endpoint = socketPeerEndpoint(accepted_fd);

                        if (op.stream.handle.index >= self.handle_states.len) {
                            posix.close(accepted_fd);
                            slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, .invalid_input, .invalid_input);
                            self.disarmSlot(slot);
                            self.pushReady(slot_index);
                            return true;
                        }
                        if (self.handle_states[op.stream.handle.index] == .open and self.handle_native[op.stream.handle.index] >= 0) {
                            posix.close(accepted_fd);
                            slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, .invalid_input, .invalid_input);
                            self.disarmSlot(slot);
                            self.pushReady(slot_index);
                            return true;
                        }

                        self.handle_states[op.stream.handle.index] = .open;
                        self.handle_generations[op.stream.handle.index] = op.stream.handle.generation;
                        self.handle_kinds[op.stream.handle.index] = .stream;
                        self.handle_native[op.stream.handle.index] = accepted_fd;
                        self.handle_owned[op.stream.handle.index] = true;

                        slot.completion = .{
                            .operation_id = slot.operation_id,
                            .tag = .accept,
                            .status = .success,
                            .bytes_transferred = 0,
                            .buffer = .{ .bytes = &[_]u8{} },
                            .handle = op.stream.handle,
                            .endpoint = peer_endpoint,
                        };
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return true;
                    },
                    .AGAIN => {
                        self.pending_accept[op.listener.handle.index] = slot_index + 1;
                        slot.wait_kind = .read;
                        self.armRead(slot.native_fd, slot.operation_id) catch {};
                        return false;
                    },
                    else => {
                        const mapped = error_map.fromPosixErrno(accept_err);
                        slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return true;
                    },
                }
            },
            .connect => |op| {
                self.pending_connect[op.stream.handle.index] = 0;
                slot.wait_kind = .none;

                const connect_rc = posix.system.connect(slot.native_fd, slot.connect_addr.ptr(), slot.connect_addr.len());
                const connect_err = posix.errno(connect_rc);
                switch (connect_err) {
                    .SUCCESS, .ISCONN => {
                        slot.completion = .{
                            .operation_id = slot.operation_id,
                            .tag = .connect,
                            .status = .success,
                            .bytes_transferred = 0,
                            .buffer = .{ .bytes = &[_]u8{} },
                            .handle = op.stream.handle,
                            .endpoint = op.endpoint,
                        };
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return true;
                    },
                    .INPROGRESS, .ALREADY => {
                        self.pending_connect[op.stream.handle.index] = slot_index + 1;
                        slot.wait_kind = .write;
                        self.armWrite(slot.native_fd, slot.operation_id) catch {};
                        return false;
                    },
                    else => {
                        const mapped = error_map.fromPosixErrno(connect_err);
                        self.cleanupConnectHandle(op.stream.handle);
                        slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, mapped.status, mapped.tag);
                        self.disarmSlot(slot);
                        self.pushReady(slot_index);
                        return true;
                    },
                }
            },
            else => {},
        }

        return false;
    }

    fn drain(self: *BsdKqueueBackend, max_completions: u32, timeout: ?posix.timespec) backend.PumpError!u32 {
        const completed_cap = self.completed.capacity();
        const completed_len = self.completed.len();
        if (completed_len >= completed_cap) return 0;
        const free_space = completed_cap - completed_len;
        const drain_limit: usize = @min(@as(usize, max_completions), @min(self.events.len, free_space));
        if (drain_limit == 0) return 0;

        var timeout_storage: posix.timespec = undefined;
        const timeout_ptr: ?*const posix.timespec = if (timeout) |ts| blk: {
            timeout_storage = ts;
            break :blk &timeout_storage;
        } else null;

        const got = try keventCall(self.kq_fd, &.{}, self.events[0..drain_limit], timeout_ptr);
        if (got == 0) return 0;

        var pushed: u32 = 0;
        var index: usize = 0;
        while (index < got) : (index += 1) {
            if (self.processEvent(self.events[index])) {
                pushed += 1;
            }
        }
        return pushed;
    }

    /// Drains completion entries without blocking.
    pub fn pump(self: *BsdKqueueBackend, max_completions: u32) backend.PumpError!u32 {
        if (max_completions == 0) return error.InvalidInput;
        if (self.closed) return 0;

        const reactor = try self.drain(max_completions, timeoutNsToTimespec(0));
        const file_count = self.file_backend.pump(max_completions - reactor) catch 0;
        return reactor + file_count;
    }

    /// Blocks for completions, optionally bounded by timeout.
    pub fn waitForCompletions(self: *BsdKqueueBackend, max_completions: u32, timeout_ns: ?u64) backend.PumpError!u32 {
        if (max_completions == 0) return error.InvalidInput;
        if (self.closed) return 0;
        if (self.file_in_flight != 0 and self.file_wake_fd < 0) return error.Unsupported;

        if (timeout_ns == null) {
            const reactor = try self.drain(max_completions, null);
            const file_count = self.file_backend.pump(max_completions - reactor) catch 0;
            return reactor + file_count;
        }

        const limit_ns: u64 = timeout_ns.?;
        if (limit_ns == 0) return 0;
        const reactor = try self.drain(max_completions, timeoutNsToTimespec(limit_ns));
        const file_count = self.file_backend.pump(max_completions - reactor) catch 0;
        return reactor + file_count;
    }

    /// Wakes a blocked `kevent` wait via EVFILT_USER trigger.
    pub fn wakeup(self: *BsdKqueueBackend) void {
        if (self.closed) return;
        const change: posix.Kevent = .{
            .ident = user_wake_ident,
            .filter = std.c.EVFILT.USER,
            .flags = 0,
            .fflags = std.c.NOTE.TRIGGER,
            .data = 0,
            .udata = 0,
        };
        var changes = [_]posix.Kevent{change};
        _ = keventCall(self.kq_fd, &changes, &.{}, null) catch {};
    }

    /// Pops one completion if available.
    pub fn poll(self: *BsdKqueueBackend) ?types.Completion {
        const slot_index = self.completed.tryPop() catch {
            const inner = self.file_backend.poll() orelse return null;
            var out = inner;
            out.operation_id |= file_backend_flag;
            if (self.file_in_flight > 0) self.file_in_flight -= 1;
            return out;
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

    /// Attempts to cancel an in-flight operation.
    pub fn cancel(self: *BsdKqueueBackend, operation_id: types.OperationId) backend.CancelError!void {
        if ((operation_id & file_backend_flag) != 0) {
            return self.file_backend.cancel(operation_id & ~file_backend_flag);
        }

        if (self.closed) return error.Closed;
        const decoded = decodeOperationId(operation_id) orelse return error.NotFound;
        if (decoded.index >= self.slots.len) return error.NotFound;
        const slot_index: u32 = @intCast(decoded.index);
        var slot = &self.slots[slot_index];
        if (slot.generation != decoded.generation) return error.NotFound;
        if (slot.state != .in_flight) return error.NotFound;
        if (slot.operation_id != operation_id) return error.NotFound;

        self.cancelSlot(slot_index, .cancelled);
    }

    /// Requests backend shutdown and cancellation of in-flight work.
    pub fn close(self: *BsdKqueueBackend) void {
        if (self.closed) return;
        self.closed = true;

        self.file_backend.close();

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            if (self.slots[index].state != .in_flight) continue;
            self.cancelSlot(@intCast(index), .closed);
        }
    }

    /// Registers runtime handle metadata for kqueue operations.
    pub fn registerHandle(
        self: *BsdKqueueBackend,
        handle: types.Handle,
        kind: types.HandleKind,
        native: types.NativeHandle,
        owned: bool,
    ) void {
        if (handle.index >= self.handle_states.len) return;
        const fd: posix.fd_t = @intCast(native);
        if (fd < 0) return;

        self.handle_states[handle.index] = .open;
        self.handle_generations[handle.index] = handle.generation;
        self.handle_kinds[handle.index] = kind;
        self.handle_native[handle.index] = fd;
        self.handle_owned[handle.index] = owned;

        switch (kind) {
            .stream, .listener => configureSocket(fd),
            .file => self.file_backend.registerHandle(handle, kind, native, owned),
        }
    }

    /// Marks handle closed and cancels dependent operations.
    pub fn notifyHandleClosed(self: *BsdKqueueBackend, handle: types.Handle) void {
        if (handle.index >= self.handle_states.len) return;
        if (self.handle_generations[handle.index] != handle.generation) return;
        if (self.handle_states[handle.index] == .closed) return;

        const kind = self.handle_kinds[handle.index];
        if (kind == .file) {
            self.file_backend.notifyHandleClosed(handle);
        }

        self.handle_states[handle.index] = .closed;
        if (self.handle_owned[handle.index]) {
            closeNativeHandle(kind, self.handle_native[handle.index]);
        }
        self.handle_native[handle.index] = -1;
        self.handle_owned[handle.index] = false;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            if (self.slots[index].state != .in_flight) continue;
            if (operationUsesHandle(self.slots[index].operation, handle)) {
                self.cancelSlot(@intCast(index), .closed);
            }
        }
    }

    /// Returns true while an in-flight operation references `handle`.
    pub fn handleInUse(self: *BsdKqueueBackend, handle: types.Handle) bool {
        if (handle.index >= self.handle_states.len) return false;
        if (self.handle_generations[handle.index] != handle.generation) return false;
        if (self.handle_states[handle.index] != .open) return false;

        if (self.file_backend.handleInUse(handle)) return true;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            const slot = &self.slots[index];
            if (slot.state != .in_flight) continue;
            if (operationUsesHandle(slot.operation, handle)) return true;
        }
        return false;
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *BsdKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};

const UnsupportedKqueueBackend = struct {
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

    pub fn init(_: std.mem.Allocator, _: config.Config) backend.InitError!UnsupportedKqueueBackend {
        return error.Unsupported;
    }

    pub fn deinit(self: *UnsupportedKqueueBackend) void {
        self.* = undefined;
    }

    pub fn asBackend(self: *UnsupportedKqueueBackend) backend.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn getAllocator(_: *const UnsupportedKqueueBackend) std.mem.Allocator {
        return std.heap.page_allocator;
    }

    pub fn capabilities(_: *const UnsupportedKqueueBackend) types.CapabilityFlags {
        return .{};
    }

    pub fn submit(_: *UnsupportedKqueueBackend, _: types.Operation) backend.SubmitError!types.OperationId {
        return error.Unsupported;
    }

    pub fn pump(_: *UnsupportedKqueueBackend, _: u32) backend.PumpError!u32 {
        return error.Unsupported;
    }

    pub fn waitForCompletions(_: *UnsupportedKqueueBackend, _: u32, _: ?u64) backend.PumpError!u32 {
        return error.Unsupported;
    }

    pub fn wakeup(_: *UnsupportedKqueueBackend) void {}

    pub fn poll(_: *UnsupportedKqueueBackend) ?types.Completion {
        return null;
    }

    pub fn cancel(_: *UnsupportedKqueueBackend, _: types.OperationId) backend.CancelError!void {
        return error.Unsupported;
    }

    pub fn close(_: *UnsupportedKqueueBackend) void {}

    pub fn registerHandle(_: *UnsupportedKqueueBackend, _: types.Handle, _: types.HandleKind, _: types.NativeHandle, _: bool) void {}

    pub fn notifyHandleClosed(_: *UnsupportedKqueueBackend, _: types.Handle) void {}

    pub fn handleInUse(_: *UnsupportedKqueueBackend, _: types.Handle) bool {
        return false;
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *UnsupportedKqueueBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};

test "kqueue backend supports bounded nop/fill completions" {
    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .bsd_kqueue;

    if (!io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
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

test "kqueue backend supports connect/accept, stream read/write, and stream read timeout" {
    var cfg = config.Config.initForTest(32);
    cfg.backend_kind = .bsd_kqueue;

    if (!io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const listen_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const listen_fd: posix.fd_t = switch (posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    errdefer posix.close(listen_fd);

    var bind_addr = SockaddrAnyPosix.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(bind_rc));

    const listen_rc2 = posix.system.listen(listen_fd, 16);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port: u16 = switch (bound) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
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
    while (drain < 32 and (!seen_accept or !seen_connect)) : (drain += 1) {
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
    while (drain < 32 and (!got_write or !got_read)) : (drain += 1) {
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
    posix.close(listen_fd);
}

test "kqueue backend enforces one pending read and one pending write per stream" {
    var cfg = config.Config.initForTest(64);
    cfg.backend_kind = .bsd_kqueue;

    if (comptime !io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const listen_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const listen_fd: posix.fd_t = switch (posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    errdefer posix.close(listen_fd);

    var bind_addr = SockaddrAnyPosix.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(bind_rc));

    const listen_rc2 = posix.system.listen(listen_fd, 16);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port: u16 = switch (bound) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
    try testing.expect(port != 0);

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intCast(listen_fd), false);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

    const server_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    const client_stream = types.Stream{ .handle = .{ .index = 2, .generation = 1 } };

    _ = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = server_stream,
        .timeout_ns = null,
    } });
    _ = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = .{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = port } },
        .timeout_ns = null,
    } });
    _ = try backend_impl.waitForCompletions(2, std.time.ns_per_s);
    while (backend_impl.poll() != null) {}

    // Saturate the client send buffer until nonblocking send reports EAGAIN.
    const client_fd: posix.fd_t = backend_impl.handle_native[client_stream.handle.index];
    if (client_fd < 0) return error.SkipZigTest;

    var fill_bytes: [4096]u8 = [_]u8{0xAB} ** 4096;
    var sent_total: usize = 0;
    const sent_limit: usize = 8 * 1024 * 1024;
    var saw_again = false;
    while (sent_total < sent_limit) {
        const rc = posix.system.send(client_fd, &fill_bytes, fill_bytes.len, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => sent_total += @intCast(rc),
            .AGAIN => {
                saw_again = true;
                break;
            },
            else => return error.SkipZigTest,
        }
    }
    if (!saw_again) return error.SkipZigTest;

    var write_bytes: [32]u8 = [_]u8{0xCD} ** 32;
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(write_bytes.len);

    const write_id = try backend_impl.submit(.{ .stream_write = .{
        .stream = client_stream,
        .buffer = write_buf,
        .timeout_ns = null,
    } });
    try testing.expectError(error.WouldBlock, backend_impl.submit(.{ .stream_write = .{
        .stream = client_stream,
        .buffer = write_buf,
        .timeout_ns = null,
    } }));
    try backend_impl.cancel(write_id);
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);

    // Reads: when no data is present, the first read is armed; the second read is backpressured.
    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buf = types.Buffer{ .bytes = &read_bytes };

    const read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = read_buf,
        .timeout_ns = null,
    } });
    try testing.expectError(error.WouldBlock, backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = read_buf,
        .timeout_ns = null,
    } }));
    try backend_impl.cancel(read_id);
    _ = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
}

test "kqueue backend closes pending accept when listener handle closes" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .bsd_kqueue;

    if (comptime !io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const listen_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const listen_fd: posix.fd_t = switch (posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    errdefer posix.close(listen_fd);

    var bind_addr = SockaddrAnyPosix.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(bind_rc));

    const listen_rc2 = posix.system.listen(listen_fd, 16);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(listen_rc2));

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intCast(listen_fd), false);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

    const reserved_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    const accept_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = reserved_stream,
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

    posix.close(listen_fd);
}

test "kqueue backend closes pending stream_write when stream handle closes" {
    var cfg = config.Config.initForTest(32);
    cfg.backend_kind = .bsd_kqueue;

    if (comptime !io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const listen_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const listen_fd: posix.fd_t = switch (posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    errdefer posix.close(listen_fd);

    var bind_addr = SockaddrAnyPosix.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(bind_rc));

    const listen_rc2 = posix.system.listen(listen_fd, 16);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port: u16 = switch (bound) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
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

    const server_fd: posix.fd_t = backend_impl.handle_native[server_stream.handle.index];
    const client_fd: posix.fd_t = backend_impl.handle_native[client_stream.handle.index];
    if (server_fd < 0 or client_fd < 0) return error.SkipZigTest;

    var small_buf: i32 = 1024;
    posix.setsockopt(server_fd, @intCast(posix.SOL.SOCKET), @intCast(posix.SO.RCVBUF), std.mem.asBytes(&small_buf)) catch {};
    posix.setsockopt(client_fd, @intCast(posix.SOL.SOCKET), @intCast(posix.SO.SNDBUF), std.mem.asBytes(&small_buf)) catch {};

    var fill_bytes: [4096]u8 = [_]u8{0xAB} ** 4096;
    var sent_total: usize = 0;
    const sent_limit: usize = 64 * 1024 * 1024;
    var saw_again = false;
    while (sent_total < sent_limit) {
        const rc = posix.system.send(client_fd, &fill_bytes, fill_bytes.len, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => sent_total += @intCast(rc),
            .AGAIN => {
                saw_again = true;
                break;
            },
            else => return error.SkipZigTest,
        }
    }
    if (!saw_again) return error.SkipZigTest;

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
    posix.close(listen_fd);
}

test "kqueue backend maps connection refused on connect" {
    var cfg = config.Config.initForTest(16);
    cfg.backend_kind = .bsd_kqueue;

    if (!io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const reserve_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const reserve_fd: posix.fd_t = switch (posix.errno(reserve_rc)) {
        .SUCCESS => @intCast(reserve_rc),
        else => return error.SkipZigTest,
    };

    var bind_addr = SockaddrAnyPosix.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = posix.system.bind(reserve_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(bind_rc));

    const reserved = socketLocalEndpoint(reserve_fd) orelse return error.SkipZigTest;
    const port: u16 = switch (reserved) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
    try testing.expect(port != 0);
    posix.close(reserve_fd);

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

test "kqueue backend maps connection reset on stream read" {
    var cfg = config.Config.initForTest(16);
    cfg.backend_kind = .bsd_kqueue;

    if (!io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const listen_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const listen_fd: posix.fd_t = switch (posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    var listen_fd_to_close: ?posix.fd_t = listen_fd;
    errdefer if (listen_fd_to_close) |fd| posix.close(fd);

    var bind_addr = SockaddrAnyPosix.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(bind_rc));

    const listen_rc2 = posix.system.listen(listen_fd, 16);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port: u16 = switch (bound) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
    try testing.expect(port != 0);

    const Server = struct {
        fn run(server_listen_fd: posix.fd_t) void {
            const poll_in: i16 = 0x0001;
            const accept_timeout_ms: i32 = 2000;
            const pfd: posix.pollfd = .{ .fd = server_listen_fd, .events = poll_in, .revents = 0 };
            var pfds = [_]posix.pollfd{pfd};
            const ready_count = posix.poll(&pfds, accept_timeout_ms) catch {
                posix.close(server_listen_fd);
                return;
            };
            if (ready_count == 0) {
                posix.close(server_listen_fd);
                return;
            }

            const accepted_fd: posix.fd_t = while (true) {
                const accept_rc = posix.system.accept(server_listen_fd, null, null);
                switch (posix.errno(accept_rc)) {
                    .SUCCESS => break @intCast(accept_rc),
                    .INTR => continue,
                    else => {
                        posix.close(server_listen_fd);
                        return;
                    },
                }
            };
            defer posix.close(accepted_fd);
            defer posix.close(server_listen_fd);

            const Linger = extern struct { l_onoff: c_int, l_linger: c_int };
            var linger_opt = Linger{ .l_onoff = 1, .l_linger = 0 };
            posix.setsockopt(
                accepted_fd,
                @intCast(posix.SOL.SOCKET),
                @intCast(posix.SO.LINGER),
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
    while (drain < 32 and !saw_connect) : (drain += 1) {
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

test "kqueue backend maps broken pipe on stream write after shutdown send" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .bsd_kqueue;

    if (!io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const listen_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const listen_fd: posix.fd_t = switch (posix.errno(listen_rc)) {
        .SUCCESS => @intCast(listen_rc),
        else => return error.SkipZigTest,
    };
    defer posix.close(listen_fd);

    var bind_addr = SockaddrAnyPosix.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    const bind_rc = posix.system.bind(listen_fd, bind_addr.ptr(), bind_addr.len());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(bind_rc));

    const listen_rc2 = posix.system.listen(listen_fd, 16);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(listen_rc2));

    const bound = socketLocalEndpoint(listen_fd) orelse return error.SkipZigTest;
    const port: u16 = switch (bound) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
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
    while (drain < 32 and !saw_connect) : (drain += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id != connect_id) continue;
        saw_connect = true;
        try testing.expectEqual(types.OperationTag.connect, completion.tag);
        try testing.expectEqual(types.CompletionStatus.success, completion.status);
    }
    try testing.expect(saw_connect);

    const client_fd = backend_impl.handle_native[client_stream.handle.index];
    try testing.expect(client_fd >= 0);
    const shutdown_rc = posix.system.shutdown(client_fd, posix.SHUT.WR);
    if (posix.errno(shutdown_rc) != .SUCCESS) return error.SkipZigTest;

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
    while (drain < 32 and completion_opt == null) : (drain += 1) {
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

test "kqueue backend waitForCompletions returns delegated file completions" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .bsd_kqueue;

    if (!io_caps.bsdBackendEnabled(builtin.os.tag)) {
        try testing.expectError(error.Unsupported, KqueueBackend.init(testing.allocator, cfg));
        return;
    }

    var backend_impl = try KqueueBackend.init(testing.allocator, cfg);
    defer backend_impl.deinit();

    const filename = "static_io_kqueue_file_io.tmp";
    defer _ = posix.system.unlink(filename);

    const open_flags: posix.O = .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const open_rc = posix.system.open(filename, open_flags, @as(posix.mode_t, 0o600));
    const fd: posix.fd_t = switch (posix.errno(open_rc)) {
        .SUCCESS => @intCast(open_rc),
        else => return error.SkipZigTest,
    };

    const file_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(file_handle, .file, @intCast(fd), true);
    defer backend_impl.notifyHandleClosed(file_handle);
    const io_file = types.File{ .handle = file_handle };

    var write_bytes: [4]u8 = .{ 't', 'e', 's', 't' };
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(4);

    const write_id = try backend_impl.submit(.{ .file_write_at = .{
        .file = io_file,
        .buffer = write_buf,
        .offset_bytes = 0,
        .timeout_ns = null,
    } });

    const waited = try backend_impl.waitForCompletions(1, std.time.ns_per_s);
    try testing.expect(waited > 0);

    const completion = backend_impl.poll().?;
    try testing.expectEqual(write_id, completion.operation_id);
    try testing.expectEqual(types.OperationTag.file_write_at, completion.tag);
    try testing.expectEqual(types.CompletionStatus.success, completion.status);
    try testing.expectEqual(@as(u32, 4), completion.bytes_transferred);
}
