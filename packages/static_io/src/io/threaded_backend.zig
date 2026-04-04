//! Threaded backend for legacy `nop`/`fill` operations.

const std = @import("std");
const builtin = @import("builtin");
const io_caps = @import("caps.zig");
const static_queues = @import("static_queues");
const backend = @import("backend.zig");
const config = @import("config.zig");
const types = @import("types.zig");
const error_map = @import("error_map.zig");
const operation_helpers = @import("operation_helpers.zig");
const operation_ids = @import("operation_ids.zig");
const static_net_native = @import("static_net_native");

const posix = std.posix;
const SockaddrAnyPosix = static_net_native.posix.SockaddrAny;
const SockaddrAnyWindows = static_net_native.windows.SockaddrAny;

const IdQueue = static_queues.ring_buffer.RingBuffer(u32);
const decodeOperationId = operation_ids.decodeExternalOperationId;
const elapsedSince = operation_helpers.elapsedSince;
const encodeOperationId = operation_ids.encodeExternalOperationId;
const nextGeneration = operation_ids.nextGeneration;
const operationUsesHandle = operation_helpers.operationUsesHandle;
const validateOperation = operation_helpers.validateOperation;

const SlotState = enum {
    free,
    pending,
    running,
    completed,
};

const Slot = struct {
    generation: u32 = 1,
    state: SlotState = .free,
    operation_id: types.OperationId = 0,
    operation: types.Operation = undefined,
    completion: types.Completion = undefined,
    cancelled: bool = false,
    closed_on_pump: bool = false,
};

const HandleState = enum {
    free,
    open,
    closed,
};

const Shared = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    slots: []Slot,
    free_slots: []u32,
    free_len: u32,
    pending: IdQueue,
    worker_completed: IdQueue,
    completed: IdQueue,
    workers: []std.Thread,

    handle_states: []HandleState,
    handle_generations: []u32,
    handle_kinds: []types.HandleKind,
    handle_native: []types.NativeHandle,
    handle_owned: []bool,

    wake_read_fd: i32 = -1,
    wake_write_fd: i32 = -1,

    closed: bool = false,
    wakeup_pending: bool = false,
    wsa_started: bool = false,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
};

pub const ThreadedBackend = struct {
    shared: *Shared,

    const Wake = if (builtin.os.tag == .windows) struct {
        fn create() ?[2]i32 {
            return null;
        }

        fn closeAll(_: [2]i32) void {}

        fn signal(_: i32) void {}

        fn drain(_: i32) void {}
    } else struct {
        fn setNonblocking(fd: posix.fd_t) void {
            const getfl_rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
            const flags: i32 = switch (posix.errno(getfl_rc)) {
                .SUCCESS => @intCast(getfl_rc),
                else => return,
            };
            const flags_u32: u32 = @bitCast(flags);
            const nonblock_mask: u32 = @as(u32, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
            const set_flags: usize = @as(usize, flags_u32 | nonblock_mask);
            _ = posix.system.fcntl(fd, posix.F.SETFL, set_flags);
        }

        fn setCloexec(fd: posix.fd_t) void {
            const getfd_rc = posix.system.fcntl(fd, posix.F.GETFD, @as(usize, 0));
            const flags: i32 = switch (posix.errno(getfd_rc)) {
                .SUCCESS => @intCast(getfd_rc),
                else => return,
            };
            const flags_u32: u32 = @bitCast(flags);
            const set_flags: usize = @as(usize, flags_u32 | posix.FD_CLOEXEC);
            _ = posix.system.fcntl(fd, posix.F.SETFD, set_flags);
        }

        fn create() ?[2]i32 {
            var fds: [2]posix.fd_t = undefined;
            const pipe_rc = posix.system.pipe(&fds);
            switch (posix.errno(pipe_rc)) {
                .SUCCESS => {},
                else => return null,
            }
            setNonblocking(fds[0]);
            setNonblocking(fds[1]);
            setCloexec(fds[0]);
            setCloexec(fds[1]);
            return .{ fds[0], fds[1] };
        }

        fn closeAll(fds: [2]i32) void {
            posix.close(@intCast(fds[0]));
            posix.close(@intCast(fds[1]));
        }

        fn signal(write_fd: i32) void {
            if (write_fd < 0) return;
            var byte: [1]u8 = .{0};
            const rc = posix.system.write(@intCast(write_fd), &byte, 1);
            _ = rc;
        }

        fn drain(read_fd: i32) void {
            if (read_fd < 0) return;
            var buf: [64]u8 = undefined;
            while (true) {
                const rc = posix.system.read(@intCast(read_fd), &buf, buf.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        if (rc == 0) break;
                        continue;
                    },
                    .AGAIN => break,
                    else => break,
                }
            }
        }
    };

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

    /// Initializes worker threads and bounded backend state.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!ThreadedBackend {
        if (!io_caps.threadedBackendEnabled()) return error.Unsupported;
        config.validate(cfg) catch |cfg_err| switch (cfg_err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
        };
        if (cfg.backend_kind == .threaded and cfg.threaded_worker_count == 0) return error.InvalidConfig;
        std.debug.assert(cfg.max_in_flight > 0);
        std.debug.assert(cfg.threaded_worker_count > 0);

        var wsa_started = false;
        if (comptime builtin.os.tag == .windows) {
            const windows = std.os.windows;
            var wsa_data: windows.ws2_32.WSADATA = undefined;
            const wsa_version: windows.WORD = 0x0202;
            if (windows.ws2_32.WSAStartup(wsa_version, &wsa_data) != 0) {
                return error.Unsupported;
            }
            wsa_started = true;
        }
        errdefer if (wsa_started) {
            if (comptime builtin.os.tag == .windows) {
                const windows = std.os.windows;
                _ = windows.ws2_32.WSACleanup();
            }
        };

        const shared = allocator.create(Shared) catch return error.OutOfMemory;
        errdefer allocator.destroy(shared);

        const wake_fds = Wake.create();
        errdefer if (wake_fds) |fds| Wake.closeAll(fds);

        const slot_count: usize = cfg.max_in_flight;
        const slots = allocator.alloc(Slot, slot_count) catch return error.OutOfMemory;
        errdefer allocator.free(slots);
        @memset(slots, .{});

        const free_slots = allocator.alloc(u32, slot_count) catch return error.OutOfMemory;
        errdefer allocator.free(free_slots);
        var free_index: usize = 0;
        while (free_index < slot_count) : (free_index += 1) {
            free_slots[free_index] = @intCast(slot_count - 1 - free_index);
        }

        var pending = IdQueue.init(allocator, .{ .capacity = cfg.submission_queue_capacity }) catch |queue_err| switch (queue_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
            error.NoSpaceLeft, error.WouldBlock => return error.InvalidConfig,
        };
        errdefer pending.deinit();

        var worker_completed = IdQueue.init(allocator, .{ .capacity = cfg.max_in_flight }) catch |queue_err| switch (queue_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
            error.NoSpaceLeft, error.WouldBlock => return error.InvalidConfig,
        };
        errdefer worker_completed.deinit();

        var completed = IdQueue.init(allocator, .{ .capacity = cfg.completion_queue_capacity }) catch |queue_err| switch (queue_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
            error.NoSpaceLeft, error.WouldBlock => return error.InvalidConfig,
        };
        errdefer completed.deinit();

        const worker_count: usize = cfg.threaded_worker_count;
        const workers = allocator.alloc(std.Thread, worker_count) catch return error.OutOfMemory;
        errdefer allocator.free(workers);
        @memset(workers, undefined);

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

        shared.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .slots = slots,
            .free_slots = free_slots,
            .free_len = cfg.max_in_flight,
            .pending = pending,
            .worker_completed = worker_completed,
            .completed = completed,
            .workers = workers,
            .handle_states = handle_states,
            .handle_generations = handle_generations,
            .handle_kinds = handle_kinds,
            .handle_native = handle_native,
            .handle_owned = handle_owned,
            .wake_read_fd = if (wake_fds) |fds| fds[0] else -1,
            .wake_write_fd = if (wake_fds) |fds| fds[1] else -1,
            .wsa_started = wsa_started,
        };

        var spawned_count: usize = 0;
        errdefer {
            shared.closed = true;
            shared.cond.broadcast();
            while (spawned_count > 0) {
                spawned_count -= 1;
                shared.workers[spawned_count].join();
            }
        }

        while (spawned_count < worker_count) : (spawned_count += 1) {
            shared.workers[spawned_count] = std.Thread.spawn(.{}, workerMain, .{shared}) catch return error.OutOfMemory;
        }

        return .{ .shared = shared };
    }

    /// Closes backend workers and releases all allocations.
    pub fn deinit(self: *ThreadedBackend) void {
        self.close();
        const shared = self.shared;
        var index: usize = 0;
        while (index < shared.workers.len) : (index += 1) {
            shared.workers[index].join();
        }
        if (shared.wake_read_fd >= 0 and shared.wake_write_fd >= 0) {
            Wake.closeAll(.{ shared.wake_read_fd, shared.wake_write_fd });
        }
        shared.completed.deinit();
        shared.worker_completed.deinit();
        shared.pending.deinit();
        if (shared.wsa_started and builtin.os.tag == .windows) {
            const windows = std.os.windows;
            _ = windows.ws2_32.WSACleanup();
        }
        shared.allocator.free(shared.handle_owned);
        shared.allocator.free(shared.handle_native);
        shared.allocator.free(shared.handle_kinds);
        shared.allocator.free(shared.handle_generations);
        shared.allocator.free(shared.handle_states);
        shared.allocator.free(shared.workers);
        shared.allocator.free(shared.free_slots);
        shared.allocator.free(shared.slots);
        shared.allocator.destroy(shared);
        self.* = undefined;
    }

    /// Returns a type-erased backend interface for runtime dispatch.
    pub fn asBackend(self: *ThreadedBackend) backend.Backend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    /// Returns an optional wake FD suitable for external polling loops.
    pub fn completionWakeFd(self: *const ThreadedBackend) ?posix.fd_t {
        if (builtin.os.tag == .windows) return null;
        const fd: i32 = self.shared.wake_read_fd;
        if (fd < 0) return null;
        return @intCast(fd);
    }

    /// Submits one operation to the worker queue.
    pub fn submit(self: *ThreadedBackend, op: types.Operation) backend.SubmitError!types.OperationId {
        const checked_op = try validateOperation(op);
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();

        if (shared.closed) return error.Closed;
        const slot_index = allocSlotLocked(shared) catch return error.WouldBlock;
        errdefer freeSlotLocked(shared, slot_index);

        var slot = &shared.slots[slot_index];
        std.debug.assert(slot.state == .free);
        std.debug.assert(slot.generation != 0);
        const operation_id = encodeOperationId(slot_index, slot.generation);
        slot.state = .pending;
        slot.operation_id = operation_id;
        slot.operation = checked_op;
        slot.cancelled = false;
        slot.closed_on_pump = false;

        shared.pending.tryPush(slot_index) catch {
            return error.WouldBlock;
        };
        shared.cond.signal();
        return operation_id;
    }

    /// Moves worker completions into the public completion queue.
    pub fn pump(self: *ThreadedBackend, max_completions: u32) backend.PumpError!u32 {
        std.debug.assert(max_completions > 0);
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();

        const moved = moveCompletionsLocked(shared, max_completions);
        if (shared.wake_read_fd >= 0) {
            Wake.drain(shared.wake_read_fd);
        }
        if (moved > 0) shared.cond.broadcast();
        return moved;
    }

    /// Blocks for completions until woken or timeout expires.
    pub fn waitForCompletions(
        self: *ThreadedBackend,
        max_completions: u32,
        timeout_ns: ?u64,
    ) backend.PumpError!u32 {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();

        var moved = moveCompletionsLocked(shared, max_completions);
        if (moved > 0) return moved;

        if (shared.wakeup_pending) {
            shared.wakeup_pending = false;
            return 0;
        }

        if (timeout_ns) |limit_ns| {
            if (limit_ns == 0) return 0;

            const start = std.time.Instant.now() catch return error.Unsupported;
            while (true) {
                const elapsed_ns = elapsedSince(start) orelse return error.Unsupported;
                if (elapsed_ns >= limit_ns) return 0;
                const remaining_ns = limit_ns - elapsed_ns;

                shared.cond.timedWait(&shared.mutex, remaining_ns) catch |err| switch (err) {
                    error.Timeout => return 0,
                };

                moved = moveCompletionsLocked(shared, max_completions);
                if (moved > 0) return moved;

                if (shared.wakeup_pending) {
                    shared.wakeup_pending = false;
                    return 0;
                }
            }
        }

        while (true) {
            shared.cond.wait(&shared.mutex);

            moved = moveCompletionsLocked(shared, max_completions);
            if (moved > 0) return moved;

            if (shared.wakeup_pending) {
                shared.wakeup_pending = false;
                return 0;
            }
        }
    }

    /// Wakes waiters and workers blocked on the condition variable.
    pub fn wakeup(self: *ThreadedBackend) void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();

        shared.wakeup_pending = true;
        shared.cond.broadcast();
    }

    /// Pops one ready completion from the queue.
    pub fn poll(self: *ThreadedBackend) ?types.Completion {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();

        const slot_index = shared.completed.tryPop() catch return null;
        const slot = &shared.slots[slot_index];
        if (slot.state != .completed) {
            std.debug.assert(slot.state == .completed);
            return null;
        }
        const completion = slot.completion;
        freeSlotLocked(shared, slot_index);
        return completion;
    }

    /// Marks a pending/running operation as cancelled.
    pub fn cancel(self: *ThreadedBackend, operation_id: types.OperationId) backend.CancelError!void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        if (shared.closed) return error.Closed;
        const decoded = decodeOperationId(operation_id) orelse return error.NotFound;
        if (decoded.index >= shared.slots.len) return error.NotFound;
        var slot = &shared.slots[decoded.index];
        if (slot.generation != decoded.generation) return error.NotFound;
        if (slot.state != .pending and slot.state != .running) return error.NotFound;
        if (slot.operation_id != operation_id) return error.NotFound;
        slot.cancelled = true;
    }

    /// Requests backend shutdown.
    pub fn close(self: *ThreadedBackend) void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();

        if (shared.closed) return;
        shared.closed = true;

        var index: usize = 0;
        while (index < shared.slots.len) : (index += 1) {
            if (shared.slots[index].state == .pending or shared.slots[index].state == .running) {
                shared.slots[index].closed_on_pump = true;
            }
        }
        shared.cond.broadcast();
    }

    /// Returns backend capability flags.
    pub fn capabilities(self: *const ThreadedBackend) types.CapabilityFlags {
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

    /// Registers runtime handle metadata for worker operations.
    pub fn registerHandle(
        self: *ThreadedBackend,
        handle: types.Handle,
        kind: types.HandleKind,
        native: types.NativeHandle,
        owned: bool,
    ) void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        if (handle.index >= shared.handle_states.len) return;

        shared.handle_states[handle.index] = .open;
        shared.handle_generations[handle.index] = handle.generation;
        shared.handle_kinds[handle.index] = kind;
        shared.handle_native[handle.index] = native;
        shared.handle_owned[handle.index] = owned;
    }

    /// Marks a runtime handle closed and flags dependent operations.
    pub fn notifyHandleClosed(self: *ThreadedBackend, handle: types.Handle) void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        if (handle.index >= shared.handle_states.len) return;
        if (shared.handle_generations[handle.index] != handle.generation) return;

        shared.handle_states[handle.index] = .closed;

        var index: usize = 0;
        while (index < shared.slots.len) : (index += 1) {
            var slot = &shared.slots[index];
            if (slot.state != .pending and slot.state != .running) continue;
            if (!operationUsesHandle(slot.operation, handle)) continue;
            slot.closed_on_pump = true;
        }

        if (shared.handle_owned[handle.index]) {
            if (builtin.os.tag != .windows or shared.handle_native[handle.index] != 0) {
                closeNativeHandle(shared.handle_kinds[handle.index], shared.handle_native[handle.index]);
            }
            shared.handle_native[handle.index] = 0;
            shared.handle_owned[handle.index] = false;
        }
    }

    /// Returns true while pending/running work still references `handle`.
    pub fn handleInUse(self: *ThreadedBackend, handle: types.Handle) bool {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        if (handle.index >= shared.handle_states.len) return false;
        if (shared.handle_generations[handle.index] != handle.generation) return false;

        var index: usize = 0;
        while (index < shared.slots.len) : (index += 1) {
            const slot = shared.slots[index];
            if (slot.state != .pending and slot.state != .running) continue;
            if (operationUsesHandle(slot.operation, handle)) return true;
        }
        return false;
    }

    fn workerMain(shared: *Shared) void {
        while (true) {
            shared.mutex.lock();
            while (true) {
                if (shared.closed and shared.pending.len() == 0) {
                    shared.mutex.unlock();
                    return;
                }
                const slot_index = shared.pending.tryPop() catch {
                    shared.cond.wait(&shared.mutex);
                    continue;
                };
                var slot = &shared.slots[slot_index];
                if (slot.state != .pending) continue;
                slot.state = .running;
                const operation_id = slot.operation_id;
                const operation = slot.operation;
                const native_snapshot = snapshotNativeLocked(shared, operation);
                const cancelled = slot.cancelled;
                const closed_on_pump = slot.closed_on_pump or shared.closed;
                shared.mutex.unlock();

                const completion = if (cancelled)
                    makeSimpleCompletion(operation_id, operation, .cancelled, .cancelled)
                else if (closed_on_pump)
                    makeSimpleCompletion(operation_id, operation, .closed, .closed)
                else switch (operation) {
                    .nop, .fill => executeOperation(operation_id, operation),
                    .stream_read => |stream_op| executeStreamRead(operation_id, stream_op, native_snapshot.stream),
                    .stream_write => |stream_op| executeStreamWrite(operation_id, stream_op, native_snapshot.stream),
                    .accept => |accept_op| executeAccept(shared, operation_id, accept_op, native_snapshot.listener),
                    .connect => |connect_op| executeConnect(shared, operation_id, connect_op, native_snapshot.stream),
                    .file_read_at => |file_op| executeFileReadAt(operation_id, file_op, native_snapshot.file),
                    .file_write_at => |file_op| executeFileWriteAt(operation_id, file_op, native_snapshot.file),
                };

                shared.mutex.lock();
                slot = &shared.slots[slot_index];
                const final_completion = if (slot.closed_on_pump or shared.closed)
                    makeSimpleCompletion(operation_id, operation, .closed, .closed)
                else if (slot.cancelled)
                    makeSimpleCompletion(operation_id, operation, .cancelled, .cancelled)
                else
                    completion;
                slot.completion = final_completion;
                slot.state = .completed;
                while (true) {
                    shared.worker_completed.tryPush(slot_index) catch {
                        shared.cond.wait(&shared.mutex);
                        continue;
                    };
                    break;
                }
                if (shared.wake_write_fd >= 0) {
                    Wake.signal(shared.wake_write_fd);
                }
                shared.cond.broadcast();
                shared.mutex.unlock();
                break;
            }
        }
    }

    fn moveCompletionsLocked(shared: *Shared, max_completions: u32) u32 {
        var moved: u32 = 0;
        while (moved < max_completions) : (moved += 1) {
            const slot_index = shared.worker_completed.tryPop() catch break;
            shared.completed.tryPush(slot_index) catch {
                shared.worker_completed.tryPush(slot_index) catch unreachable;
                break;
            };
        }
        return moved;
    }

    fn allocSlotLocked(shared: *Shared) error{WouldBlock}!u32 {
        std.debug.assert(shared.free_len <= shared.free_slots.len);
        if (shared.free_len == 0) return error.WouldBlock;
        shared.free_len -= 1;
        const slot_index = shared.free_slots[shared.free_len];
        std.debug.assert(slot_index < shared.slots.len);
        std.debug.assert(shared.slots[slot_index].state == .free);
        return slot_index;
    }

    fn freeSlotLocked(shared: *Shared, slot_index: u32) void {
        std.debug.assert(slot_index < shared.slots.len);
        std.debug.assert(shared.free_len < shared.free_slots.len);
        const next_generation = nextGeneration(shared.slots[slot_index].generation);
        shared.slots[slot_index] = .{
            .generation = next_generation,
        };
        shared.free_slots[shared.free_len] = slot_index;
        shared.free_len += 1;
        std.debug.assert(shared.free_len <= shared.free_slots.len);
    }

    fn executeOperation(operation_id: types.OperationId, operation: types.Operation) types.Completion {
        return switch (operation) {
            .nop => |buffer| .{
                .operation_id = operation_id,
                .tag = .nop,
                .status = .success,
                .bytes_transferred = buffer.used_len,
                .buffer = buffer,
            },
            .fill => |fill| blk: {
                var buffer = fill.buffer;
                if (fill.len > 0) @memset(buffer.bytes[0..fill.len], fill.byte);
                buffer.used_len = fill.len;
                break :blk .{
                    .operation_id = operation_id,
                    .tag = .fill,
                    .status = .success,
                    .bytes_transferred = fill.len,
                    .buffer = buffer,
                };
            },
            else => unreachable,
        };
    }

    fn makeSimpleCompletion(
        operation_id: types.OperationId,
        operation: types.Operation,
        status: types.CompletionStatus,
        err: types.CompletionErrorTag,
    ) types.Completion {
        return operation_helpers.makeSimpleCompletion(operation_id, operation, status, err);
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const ThreadedBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *ThreadedBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};

fn closeNativeHandle(kind: types.HandleKind, native: types.NativeHandle) void {
    if (native == 0 and builtin.os.tag == .windows) return;
    switch (builtin.os.tag) {
        .windows => closeNativeHandleWindows(kind, native),
        else => closeNativeHandlePosix(kind, native),
    }
}

fn closeNativeHandleWindows(kind: types.HandleKind, native: types.NativeHandle) void {
    const windows = std.os.windows;
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

fn closeNativeHandlePosix(kind: types.HandleKind, native: types.NativeHandle) void {
    _ = kind;
    const fd: std.posix.fd_t = @intCast(native);
    std.posix.close(fd);
}

const NativeSnapshot = struct {
    file: ?types.NativeHandle = null,
    stream: ?types.NativeHandle = null,
    listener: ?types.NativeHandle = null,
};

fn snapshotNativeLocked(shared: *Shared, operation: types.Operation) NativeSnapshot {
    return switch (operation) {
        .file_read_at => |op| .{ .file = nativeForHandleLocked(shared, op.file.handle, .file) },
        .file_write_at => |op| .{ .file = nativeForHandleLocked(shared, op.file.handle, .file) },
        .stream_read => |op| .{ .stream = nativeForHandleLocked(shared, op.stream.handle, .stream) },
        .stream_write => |op| .{ .stream = nativeForHandleLocked(shared, op.stream.handle, .stream) },
        .accept => |op| .{ .listener = nativeForHandleLocked(shared, op.listener.handle, .listener) },
        .connect => |op| .{ .stream = nativeForHandleLocked(shared, op.stream.handle, .stream) },
        else => .{},
    };
}

fn nativeForHandleLocked(shared: *Shared, handle: types.Handle, expected_kind: types.HandleKind) ?types.NativeHandle {
    if (handle.index >= shared.handle_states.len) return null;
    if (shared.handle_states[handle.index] != .open) return null;
    if (shared.handle_generations[handle.index] != handle.generation) return null;
    if (shared.handle_kinds[handle.index] != expected_kind) return null;
    const native = shared.handle_native[handle.index];
    if (native == 0 and builtin.os.tag == .windows) return null;
    return native;
}

fn executeStreamRead(operation_id: types.OperationId, op: @FieldType(types.Operation, "stream_read"), native: ?types.NativeHandle) types.Completion {
    const stream_native = native orelse return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, .invalid_input, .invalid_input);
    if (op.timeout_ns != null and op.timeout_ns.? == 0) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, .timeout, .timeout);
    }
    if (op.buffer.bytes.len > std.math.maxInt(u32)) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, .invalid_input, .invalid_input);
    }
    var buffer = op.buffer;
    buffer.used_len = 0;
    const request_len: u32 = @intCast(buffer.bytes.len);
    std.debug.assert(request_len > 0);

    return switch (builtin.os.tag) {
        .windows => executeStreamReadWindows(operation_id, op, stream_native, buffer, request_len),
        else => executeStreamReadPosix(operation_id, op, stream_native, buffer, request_len),
    };
}

fn executeStreamWrite(operation_id: types.OperationId, op: @FieldType(types.Operation, "stream_write"), native: ?types.NativeHandle) types.Completion {
    const stream_native = native orelse return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, .invalid_input, .invalid_input);
    if (op.timeout_ns != null and op.timeout_ns.? == 0) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, .timeout, .timeout);
    }
    if (op.buffer.bytes.len > std.math.maxInt(u32)) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, .invalid_input, .invalid_input);
    }
    const request_len: u32 = op.buffer.used_len;
    std.debug.assert(request_len > 0);

    return switch (builtin.os.tag) {
        .windows => executeStreamWriteWindows(operation_id, op, stream_native, request_len),
        else => executeStreamWritePosix(operation_id, op, stream_native, request_len),
    };
}

fn executeAccept(shared: *Shared, operation_id: types.OperationId, op: @FieldType(types.Operation, "accept"), listener_native: ?types.NativeHandle) types.Completion {
    const native = listener_native orelse return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .invalid_input, .invalid_input);
    if (op.timeout_ns != null and op.timeout_ns.? == 0) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .timeout, .timeout);
    }

    return switch (builtin.os.tag) {
        .windows => executeAcceptWindows(shared, operation_id, op, native),
        else => executeAcceptPosix(shared, operation_id, op, native),
    };
}

fn executeConnect(shared: *Shared, operation_id: types.OperationId, op: @FieldType(types.Operation, "connect"), existing_native: ?types.NativeHandle) types.Completion {
    if (existing_native != null) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input);
    }
    if (op.timeout_ns != null and op.timeout_ns.? == 0) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .timeout, .timeout);
    }

    return switch (builtin.os.tag) {
        .windows => executeConnectWindows(shared, operation_id, op),
        else => executeConnectPosix(shared, operation_id, op),
    };
}

fn timeoutNsToPollMs(timeout_ns: ?u64) i32 {
    if (timeout_ns == null) return -1;
    const ns = timeout_ns.?;
    if (ns == 0) return 0;
    const ns_per_ms: u64 = std.time.ns_per_ms;
    var ms: u64 = ns / ns_per_ms;
    if (ns % ns_per_ms != 0) ms += 1;
    if (ms > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(ms);
}

const poll_in: i16 = if (builtin.os.tag == .windows)
    @intCast(std.os.windows.ws2_32.POLL.IN)
else
    0x0001;
const poll_out: i16 = if (builtin.os.tag == .windows)
    @intCast(std.os.windows.ws2_32.POLL.OUT)
else
    0x0004;

fn executeStreamReadWindows(
    operation_id: types.OperationId,
    op: @FieldType(types.Operation, "stream_read"),
    native: types.NativeHandle,
    buffer: types.Buffer,
    request_len: u32,
) types.Completion {
    const windows = std.os.windows;
    const sock: windows.ws2_32.SOCKET = @ptrFromInt(native);

    if (op.timeout_ns != null) {
        var pfd: windows.ws2_32.WSAPOLLFD = .{ .fd = sock, .events = poll_in, .revents = 0 };
        const poll_rc = windows.ws2_32.WSAPoll(@ptrCast(&pfd), 1, timeoutNsToPollMs(op.timeout_ns));
        if (poll_rc == 0) {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, .timeout, .timeout);
        }
        if (poll_rc == windows.ws2_32.SOCKET_ERROR) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, mapped.status, mapped.tag);
        }
    }

    const rc: i32 = windows.ws2_32.recv(sock, @ptrCast(buffer.bytes.ptr), @intCast(request_len), 0);
    if (rc == windows.ws2_32.SOCKET_ERROR) {
        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, mapped.status, mapped.tag);
    }
    var out_buffer = buffer;
    out_buffer.used_len = @intCast(@as(u32, @intCast(rc)));
    return .{
        .operation_id = operation_id,
        .tag = .stream_read,
        .status = .success,
        .bytes_transferred = @intCast(rc),
        .buffer = out_buffer,
        .handle = op.stream.handle,
    };
}

fn executeStreamWriteWindows(
    operation_id: types.OperationId,
    op: @FieldType(types.Operation, "stream_write"),
    native: types.NativeHandle,
    request_len: u32,
) types.Completion {
    const windows = std.os.windows;
    const sock: windows.ws2_32.SOCKET = @ptrFromInt(native);

    if (op.timeout_ns != null) {
        var pfd: windows.ws2_32.WSAPOLLFD = .{ .fd = sock, .events = poll_out, .revents = 0 };
        const poll_rc = windows.ws2_32.WSAPoll(@ptrCast(&pfd), 1, timeoutNsToPollMs(op.timeout_ns));
        if (poll_rc == 0) {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, .timeout, .timeout);
        }
        if (poll_rc == windows.ws2_32.SOCKET_ERROR) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, mapped.status, mapped.tag);
        }
    }

    const rc: i32 = windows.ws2_32.send(sock, @ptrCast(op.buffer.bytes.ptr), @intCast(request_len), 0);
    if (rc == windows.ws2_32.SOCKET_ERROR) {
        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, mapped.status, mapped.tag);
    }
    return .{
        .operation_id = operation_id,
        .tag = .stream_write,
        .status = .success,
        .bytes_transferred = @intCast(rc),
        .buffer = op.buffer,
        .handle = op.stream.handle,
    };
}

fn executeAcceptWindows(shared: *Shared, operation_id: types.OperationId, op: @FieldType(types.Operation, "accept"), listener_native: types.NativeHandle) types.Completion {
    const windows = std.os.windows;
    const listen_sock: windows.ws2_32.SOCKET = @ptrFromInt(listener_native);

    if (op.timeout_ns != null) {
        var pfd: windows.ws2_32.WSAPOLLFD = .{ .fd = listen_sock, .events = poll_in, .revents = 0 };
        const poll_rc = windows.ws2_32.WSAPoll(@ptrCast(&pfd), 1, timeoutNsToPollMs(op.timeout_ns));
        if (poll_rc == 0) {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .timeout, .timeout);
        }
        if (poll_rc == windows.ws2_32.SOCKET_ERROR) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, mapped.status, mapped.tag);
        }
    }

    var peer_storage: windows.ws2_32.sockaddr.storage = undefined;
    var peer_len: i32 = @intCast(@sizeOf(windows.ws2_32.sockaddr.storage));
    const accepted = windows.ws2_32.accept(listen_sock, @ptrCast(&peer_storage), &peer_len);
    if (accepted == windows.ws2_32.INVALID_SOCKET) {
        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, mapped.status, mapped.tag);
    }
    const accepted_native: types.NativeHandle = @intFromPtr(accepted);
    const peer_endpoint: ?types.Endpoint = static_net_native.windows.endpointFromStorage(&peer_storage);

    shared.mutex.lock();
    defer shared.mutex.unlock();
    if (op.stream.handle.index >= shared.handle_states.len) {
        closeNativeHandleWindows(.stream, accepted_native);
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .invalid_input, .invalid_input);
    }
    if (shared.handle_states[op.stream.handle.index] == .open and shared.handle_native[op.stream.handle.index] != 0) {
        closeNativeHandleWindows(.stream, accepted_native);
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .invalid_input, .invalid_input);
    }

    shared.handle_states[op.stream.handle.index] = .open;
    shared.handle_generations[op.stream.handle.index] = op.stream.handle.generation;
    shared.handle_kinds[op.stream.handle.index] = .stream;
    shared.handle_native[op.stream.handle.index] = accepted_native;
    shared.handle_owned[op.stream.handle.index] = true;

    return .{
        .operation_id = operation_id,
        .tag = .accept,
        .status = .success,
        .bytes_transferred = 0,
        .buffer = .{ .bytes = &[_]u8{} },
        .handle = op.stream.handle,
        .endpoint = peer_endpoint,
    };
}

fn executeConnectWindows(shared: *Shared, operation_id: types.OperationId, op: @FieldType(types.Operation, "connect")) types.Completion {
    const windows = std.os.windows;
    const family: i32 = switch (op.endpoint) {
        .ipv4 => windows.ws2_32.AF.INET,
        .ipv6 => windows.ws2_32.AF.INET6,
    };
    const sock = windows.ws2_32.WSASocketW(family, windows.ws2_32.SOCK.STREAM, windows.ws2_32.IPPROTO.TCP, null, 0, 0);
    if (sock == windows.ws2_32.INVALID_SOCKET) {
        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
    }
    errdefer _ = windows.ws2_32.closesocket(sock);

    var remote = SockaddrAnyWindows.fromEndpoint(op.endpoint);
    if (op.timeout_ns == null) {
        if (windows.ws2_32.connect(sock, remote.ptr(), remote.len()) == windows.ws2_32.SOCKET_ERROR) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
        }
    } else {
        var nonblocking: u32 = 1;
        const fionbio: i32 = @bitCast(@as(u32, 0x8004667E));
        if (windows.ws2_32.ioctlsocket(sock, fionbio, &nonblocking) == windows.ws2_32.SOCKET_ERROR) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
        }

        const rc = windows.ws2_32.connect(sock, remote.ptr(), remote.len());
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            const wsa_err = windows.ws2_32.WSAGetLastError();
            if (wsa_err != .EWOULDBLOCK and wsa_err != .EINPROGRESS and wsa_err != .EALREADY) {
                const mapped = error_map.fromWindowsErrorCode(@intFromEnum(wsa_err));
                return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
            }
        }

        var pfd: windows.ws2_32.WSAPOLLFD = .{ .fd = sock, .events = poll_out, .revents = 0 };
        const poll_rc = windows.ws2_32.WSAPoll(@ptrCast(&pfd), 1, timeoutNsToPollMs(op.timeout_ns));
        if (poll_rc == 0) {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .timeout, .timeout);
        }
        if (poll_rc == windows.ws2_32.SOCKET_ERROR) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
        }

        var so_error: i32 = 0;
        var opt_len: i32 = @sizeOf(i32);
        if (windows.ws2_32.getsockopt(sock, windows.ws2_32.SOL.SOCKET, windows.ws2_32.SO.ERROR, @ptrCast(&so_error), &opt_len) == windows.ws2_32.SOCKET_ERROR) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.ws2_32.WSAGetLastError()));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
        }
        if (so_error != 0) {
            const mapped = error_map.fromWindowsErrorCode(@intCast(so_error));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
        }

        nonblocking = 0;
        _ = windows.ws2_32.ioctlsocket(sock, fionbio, &nonblocking);
    }

    const native: types.NativeHandle = @intFromPtr(sock);
    shared.mutex.lock();
    defer shared.mutex.unlock();
    if (op.stream.handle.index >= shared.handle_states.len) {
        closeNativeHandleWindows(.stream, native);
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input);
    }
    if (shared.handle_states[op.stream.handle.index] == .open and shared.handle_native[op.stream.handle.index] != 0) {
        closeNativeHandleWindows(.stream, native);
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input);
    }

    shared.handle_states[op.stream.handle.index] = .open;
    shared.handle_generations[op.stream.handle.index] = op.stream.handle.generation;
    shared.handle_kinds[op.stream.handle.index] = .stream;
    shared.handle_native[op.stream.handle.index] = native;
    shared.handle_owned[op.stream.handle.index] = true;

    return .{
        .operation_id = operation_id,
        .tag = .connect,
        .status = .success,
        .bytes_transferred = 0,
        .buffer = .{ .bytes = &[_]u8{} },
        .handle = op.stream.handle,
        .endpoint = op.endpoint,
    };
}

fn executeStreamReadPosix(
    operation_id: types.OperationId,
    op: @FieldType(types.Operation, "stream_read"),
    native: types.NativeHandle,
    buffer: types.Buffer,
    request_len: u32,
) types.Completion {
    const fd: std.posix.fd_t = @intCast(native);
    if (op.timeout_ns != null) {
        const pfd: std.posix.pollfd = .{ .fd = fd, .events = poll_in, .revents = 0 };
        var pfds = [_]std.posix.pollfd{pfd};
        const ready_count = std.posix.poll(&pfds, timeoutNsToPollMs(op.timeout_ns)) catch {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, .invalid_input, .invalid_input);
        };
        if (ready_count == 0) {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, .timeout, .timeout);
        }
    }

    const read_len: usize = while (true) {
        const read_rc = std.posix.system.read(fd, buffer.bytes.ptr, request_len);
        const read_err = std.posix.errno(read_rc);
        switch (read_err) {
            .SUCCESS => break @intCast(read_rc),
            .INTR => continue,
            else => {
                const mapped = error_map.fromPosixErrno(read_err);
                return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_read = op }, mapped.status, mapped.tag);
            },
        }
    };
    var out_buffer = buffer;
    out_buffer.used_len = @intCast(read_len);
    return .{
        .operation_id = operation_id,
        .tag = .stream_read,
        .status = .success,
        .bytes_transferred = @intCast(read_len),
        .buffer = out_buffer,
        .handle = op.stream.handle,
    };
}

fn executeStreamWritePosix(
    operation_id: types.OperationId,
    op: @FieldType(types.Operation, "stream_write"),
    native: types.NativeHandle,
    request_len: u32,
) types.Completion {
    const fd: std.posix.fd_t = @intCast(native);
    if (op.timeout_ns != null) {
        const pfd: std.posix.pollfd = .{ .fd = fd, .events = poll_out, .revents = 0 };
        var pfds = [_]std.posix.pollfd{pfd};
        const ready_count = std.posix.poll(&pfds, timeoutNsToPollMs(op.timeout_ns)) catch {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, .invalid_input, .invalid_input);
        };
        if (ready_count == 0) {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, .timeout, .timeout);
        }
    }

    const send_flags: u32 = if (@hasDecl(std.posix.MSG, "NOSIGNAL")) std.posix.MSG.NOSIGNAL else 0;
    const send_rc = if (@hasDecl(std.posix.system, "send"))
        std.posix.system.send(fd, op.buffer.bytes.ptr, request_len, send_flags)
    else
        std.posix.system.sendto(fd, op.buffer.bytes.ptr, request_len, send_flags, null, 0);
    const send_err = std.posix.errno(send_rc);
    const written: usize = switch (send_err) {
        .SUCCESS => @intCast(send_rc),
        else => {
            const mapped = error_map.fromPosixErrno(send_err);
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .stream_write = op }, mapped.status, mapped.tag);
        },
    };
    return .{
        .operation_id = operation_id,
        .tag = .stream_write,
        .status = .success,
        .bytes_transferred = @intCast(written),
        .buffer = op.buffer,
        .handle = op.stream.handle,
    };
}

fn executeAcceptPosix(shared: *Shared, operation_id: types.OperationId, op: @FieldType(types.Operation, "accept"), listener_native: types.NativeHandle) types.Completion {
    const fd: std.posix.fd_t = @intCast(listener_native);
    if (op.timeout_ns != null) {
        const pfd: std.posix.pollfd = .{ .fd = fd, .events = poll_in, .revents = 0 };
        var pfds = [_]std.posix.pollfd{pfd};
        const ready_count = std.posix.poll(&pfds, timeoutNsToPollMs(op.timeout_ns)) catch {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .invalid_input, .invalid_input);
        };
        if (ready_count == 0) {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .timeout, .timeout);
        }
    }

    var peer_storage: std.posix.sockaddr.storage = undefined;
    var peer_len: std.posix.socklen_t = @intCast(@sizeOf(std.posix.sockaddr.storage));
    const accept_rc = std.posix.system.accept(fd, @ptrCast(&peer_storage), &peer_len);
    const accept_err = std.posix.errno(accept_rc);
    const accepted_fd: std.posix.fd_t = switch (accept_err) {
        .SUCCESS => @intCast(accept_rc),
        else => {
            const mapped = error_map.fromPosixErrno(accept_err);
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, mapped.status, mapped.tag);
        },
    };
    if (@hasDecl(std.posix.SO, "NOSIGPIPE")) {
        var one: i32 = 1;
        std.posix.setsockopt(accepted_fd, @intCast(std.posix.SOL.SOCKET), @intCast(std.posix.SO.NOSIGPIPE), std.mem.asBytes(&one)) catch {};
    }
    const accepted_native: types.NativeHandle = @intCast(accepted_fd);
    const peer_endpoint: ?types.Endpoint = static_net_native.posix.endpointFromStorage(&peer_storage);

    shared.mutex.lock();
    defer shared.mutex.unlock();
    if (op.stream.handle.index >= shared.handle_states.len) {
        closeNativeHandlePosix(.stream, accepted_native);
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .invalid_input, .invalid_input);
    }
    if (shared.handle_states[op.stream.handle.index] == .open and shared.handle_native[op.stream.handle.index] != 0) {
        closeNativeHandlePosix(.stream, accepted_native);
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .accept = op }, .invalid_input, .invalid_input);
    }

    shared.handle_states[op.stream.handle.index] = .open;
    shared.handle_generations[op.stream.handle.index] = op.stream.handle.generation;
    shared.handle_kinds[op.stream.handle.index] = .stream;
    shared.handle_native[op.stream.handle.index] = accepted_native;
    shared.handle_owned[op.stream.handle.index] = true;

    return .{
        .operation_id = operation_id,
        .tag = .accept,
        .status = .success,
        .bytes_transferred = 0,
        .buffer = .{ .bytes = &[_]u8{} },
        .handle = op.stream.handle,
        .endpoint = peer_endpoint,
    };
}

fn executeConnectPosix(shared: *Shared, operation_id: types.OperationId, op: @FieldType(types.Operation, "connect")) types.Completion {
    const family: u32 = switch (op.endpoint) {
        .ipv4 => std.posix.AF.INET,
        .ipv6 => std.posix.AF.INET6,
    };
    const sock_rc = std.posix.system.socket(family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    const sock_err = std.posix.errno(sock_rc);
    const sock: std.posix.socket_t = switch (sock_err) {
        .SUCCESS => @intCast(sock_rc),
        else => {
            const mapped = error_map.fromPosixErrno(sock_err);
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
        },
    };
    errdefer std.posix.close(sock);

    if (@hasDecl(std.posix.SO, "NOSIGPIPE")) {
        var one: i32 = 1;
        std.posix.setsockopt(sock, @intCast(std.posix.SOL.SOCKET), @intCast(std.posix.SO.NOSIGPIPE), std.mem.asBytes(&one)) catch {};
    }

    var remote = SockaddrAnyPosix.fromEndpoint(op.endpoint);

    if (op.timeout_ns == null) {
        while (true) {
            const connect_rc = std.posix.system.connect(sock, remote.ptr(), remote.len());
            const connect_err = std.posix.errno(connect_rc);
            switch (connect_err) {
                .SUCCESS => break,
                .INTR => continue,
                else => {
                    const mapped = error_map.fromPosixErrno(connect_err);
                    return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
                },
            }
        }
    } else {
        const old_flags = std.posix.fcntl(sock, std.posix.F.GETFL, 0) catch {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input);
        };
        const nonblock_mask: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
        _ = std.posix.fcntl(sock, std.posix.F.SETFL, old_flags | nonblock_mask) catch {
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input);
        };
        defer _ = std.posix.fcntl(sock, std.posix.F.SETFL, old_flags) catch {};

        var pending = false;
        while (true) {
            const connect_rc = std.posix.system.connect(sock, remote.ptr(), remote.len());
            const connect_err = std.posix.errno(connect_rc);
            switch (connect_err) {
                .SUCCESS => break,
                .INTR => continue,
                .INPROGRESS, .AGAIN => {
                    pending = true;
                    break;
                },
                else => {
                    const mapped = error_map.fromPosixErrno(connect_err);
                    return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
                },
            }
        }

        if (pending) {
            const pfd: std.posix.pollfd = .{ .fd = sock, .events = poll_out, .revents = 0 };
            var pfds = [_]std.posix.pollfd{pfd};
            const ready_count = std.posix.poll(&pfds, timeoutNsToPollMs(op.timeout_ns)) catch {
                return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input);
            };
            if (ready_count == 0) {
                return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .timeout, .timeout);
            }

            var so_error: i32 = 0;
            var opt_len: std.posix.socklen_t = @intCast(@sizeOf(i32));
            const sockopt_rc = std.posix.system.getsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&so_error), &opt_len);
            const sockopt_err = std.posix.errno(sockopt_rc);
            switch (sockopt_err) {
                .SUCCESS => {},
                else => {
                    const mapped = error_map.fromPosixErrno(sockopt_err);
                    return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
                },
            }
            if (so_error != 0) {
                const so_err_u16: u16 = @intCast(@as(u32, @intCast(so_error)));
                const so_errno: std.posix.E = @enumFromInt(so_err_u16);
                const mapped = error_map.fromPosixErrno(so_errno);
                return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, mapped.status, mapped.tag);
            }
        }
    }

    shared.mutex.lock();
    defer shared.mutex.unlock();
    if (op.stream.handle.index >= shared.handle_states.len) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input);
    }
    if (shared.handle_states[op.stream.handle.index] == .open and shared.handle_native[op.stream.handle.index] != 0) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input);
    }

    shared.handle_states[op.stream.handle.index] = .open;
    shared.handle_generations[op.stream.handle.index] = op.stream.handle.generation;
    shared.handle_kinds[op.stream.handle.index] = .stream;
    shared.handle_native[op.stream.handle.index] = @intCast(sock);
    shared.handle_owned[op.stream.handle.index] = true;

    return .{
        .operation_id = operation_id,
        .tag = .connect,
        .status = .success,
        .bytes_transferred = 0,
        .buffer = .{ .bytes = &[_]u8{} },
        .handle = op.stream.handle,
        .endpoint = op.endpoint,
    };
}

fn endpointPort(endpoint: types.Endpoint) u16 {
    return switch (endpoint) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
}

fn executeFileReadAt(operation_id: types.OperationId, op: @FieldType(types.Operation, "file_read_at"), native: ?types.NativeHandle) types.Completion {
    const native_handle = native orelse return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_read_at = op }, .invalid_input, .invalid_input);
    if (op.timeout_ns != null and op.timeout_ns.? == 0) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_read_at = op }, .timeout, .timeout);
    }

    if (op.buffer.bytes.len > std.math.maxInt(u32)) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_read_at = op }, .invalid_input, .invalid_input);
    }
    var buffer = op.buffer;
    buffer.used_len = 0;
    const request_len: u32 = @intCast(buffer.bytes.len);
    if (request_len == 0) {
        return .{
            .operation_id = operation_id,
            .tag = .file_read_at,
            .status = .success,
            .bytes_transferred = 0,
            .buffer = buffer,
            .handle = op.file.handle,
        };
    }

    return switch (builtin.os.tag) {
        .windows => executeFileReadAtWindows(operation_id, op, native_handle, buffer, request_len),
        else => executeFileReadAtPosix(operation_id, op, native_handle, buffer, request_len),
    };
}

fn executeFileWriteAt(operation_id: types.OperationId, op: @FieldType(types.Operation, "file_write_at"), native: ?types.NativeHandle) types.Completion {
    const native_handle = native orelse return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_write_at = op }, .invalid_input, .invalid_input);
    if (op.timeout_ns != null and op.timeout_ns.? == 0) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_write_at = op }, .timeout, .timeout);
    }

    if (op.buffer.bytes.len > std.math.maxInt(u32)) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_write_at = op }, .invalid_input, .invalid_input);
    }
    const request_len: u32 = op.buffer.used_len;
    std.debug.assert(request_len > 0);

    return switch (builtin.os.tag) {
        .windows => executeFileWriteAtWindows(operation_id, op, native_handle, request_len),
        else => executeFileWriteAtPosix(operation_id, op, native_handle, request_len),
    };
}

fn setOverlappedOffset(overlapped: *std.os.windows.OVERLAPPED, offset_bytes: u64) void {
    overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @intCast(offset_bytes & 0xFFFF_FFFF);
    overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @intCast((offset_bytes >> 32) & 0xFFFF_FFFF);
}

fn executeFileReadAtWindows(
    operation_id: types.OperationId,
    op: @FieldType(types.Operation, "file_read_at"),
    native_handle: types.NativeHandle,
    buffer: types.Buffer,
    request_len: u32,
) types.Completion {
    const windows = std.os.windows;
    const kernel32 = windows.kernel32;
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    setOverlappedOffset(&overlapped, op.offset_bytes);

    const handle: windows.HANDLE = @ptrFromInt(native_handle);
    const submit_ok = kernel32.ReadFile(handle, @ptrCast(buffer.bytes.ptr), request_len, null, &overlapped);
    if (submit_ok == windows.FALSE) {
        const last_error = windows.GetLastError();
        if (last_error != windows.Win32Error.IO_PENDING) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(last_error));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_read_at = op }, mapped.status, mapped.tag);
        }
    }

    var bytes: windows.DWORD = 0;
    const finish_ok = kernel32.GetOverlappedResult(handle, &overlapped, &bytes, windows.TRUE);
    if (finish_ok == windows.FALSE) {
        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.GetLastError()));
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_read_at = op }, mapped.status, mapped.tag);
    }

    var out_buffer = buffer;
    out_buffer.used_len = @intCast(bytes);
    return .{
        .operation_id = operation_id,
        .tag = .file_read_at,
        .status = .success,
        .bytes_transferred = @intCast(bytes),
        .buffer = out_buffer,
        .handle = op.file.handle,
    };
}

fn executeFileWriteAtWindows(
    operation_id: types.OperationId,
    op: @FieldType(types.Operation, "file_write_at"),
    native_handle: types.NativeHandle,
    request_len: u32,
) types.Completion {
    const windows = std.os.windows;
    const kernel32 = windows.kernel32;
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    setOverlappedOffset(&overlapped, op.offset_bytes);

    const handle: windows.HANDLE = @ptrFromInt(native_handle);
    const submit_ok = kernel32.WriteFile(handle, @ptrCast(op.buffer.bytes.ptr), request_len, null, &overlapped);
    if (submit_ok == windows.FALSE) {
        const last_error = windows.GetLastError();
        if (last_error != windows.Win32Error.IO_PENDING) {
            const mapped = error_map.fromWindowsErrorCode(@intFromEnum(last_error));
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_write_at = op }, mapped.status, mapped.tag);
        }
    }

    var bytes: windows.DWORD = 0;
    const finish_ok = kernel32.GetOverlappedResult(handle, &overlapped, &bytes, windows.TRUE);
    if (finish_ok == windows.FALSE) {
        const mapped = error_map.fromWindowsErrorCode(@intFromEnum(windows.GetLastError()));
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_write_at = op }, mapped.status, mapped.tag);
    }

    return .{
        .operation_id = operation_id,
        .tag = .file_write_at,
        .status = .success,
        .bytes_transferred = @intCast(bytes),
        .buffer = op.buffer,
        .handle = op.file.handle,
    };
}

fn executeFileReadAtPosix(
    operation_id: types.OperationId,
    op: @FieldType(types.Operation, "file_read_at"),
    native_handle: types.NativeHandle,
    buffer: types.Buffer,
    request_len: u32,
) types.Completion {
    if (op.offset_bytes > std.math.maxInt(i64)) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_read_at = op }, .invalid_input, .invalid_input);
    }
    const fd: std.posix.fd_t = @intCast(native_handle);
    const rc = std.posix.system.pread(fd, buffer.bytes.ptr, request_len, @intCast(op.offset_bytes));
    const read_err = std.posix.errno(rc);
    const read_len: usize = switch (read_err) {
        .SUCCESS => @intCast(rc),
        else => {
            const mapped = error_map.fromPosixErrno(read_err);
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_read_at = op }, mapped.status, mapped.tag);
        },
    };
    var out_buffer = buffer;
    out_buffer.used_len = @intCast(read_len);
    return .{
        .operation_id = operation_id,
        .tag = .file_read_at,
        .status = .success,
        .bytes_transferred = @intCast(read_len),
        .buffer = out_buffer,
        .handle = op.file.handle,
    };
}

fn executeFileWriteAtPosix(
    operation_id: types.OperationId,
    op: @FieldType(types.Operation, "file_write_at"),
    native_handle: types.NativeHandle,
    request_len: u32,
) types.Completion {
    if (op.offset_bytes > std.math.maxInt(i64)) {
        return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_write_at = op }, .invalid_input, .invalid_input);
    }
    const fd: std.posix.fd_t = @intCast(native_handle);
    const rc = std.posix.system.pwrite(fd, op.buffer.bytes.ptr, request_len, @intCast(op.offset_bytes));
    const write_err = std.posix.errno(rc);
    const written: usize = switch (write_err) {
        .SUCCESS => @intCast(rc),
        else => {
            const mapped = error_map.fromPosixErrno(write_err);
            return ThreadedBackend.makeSimpleCompletion(operation_id, .{ .file_write_at = op }, mapped.status, mapped.tag);
        },
    };
    return .{
        .operation_id = operation_id,
        .tag = .file_write_at,
        .status = .success,
        .bytes_transferred = @intCast(written),
        .buffer = op.buffer,
        .handle = op.file.handle,
    };
}

test "threaded backend deterministic parity with single worker" {
    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 1;

    if (!io_caps.threadedBackendEnabled()) {
        try std.testing.expectError(error.Unsupported, ThreadedBackend.init(std.testing.allocator, cfg));
        return;
    }

    var backend_impl = try ThreadedBackend.init(std.testing.allocator, cfg);
    defer backend_impl.deinit();

    var storage_a: [8]u8 = [_]u8{0} ** 8;
    var storage_b: [8]u8 = [_]u8{0} ** 8;
    const buf_a = types.Buffer{ .bytes = &storage_a };
    const buf_b = types.Buffer{ .bytes = &storage_b };

    const id_a = try backend_impl.submit(.{ .fill = .{
        .buffer = buf_a,
        .len = 4,
        .byte = 0xBC,
    } });
    const id_b = try backend_impl.submit(.{ .nop = buf_b });

    var pumped_total: u32 = 0;
    var attempts: u32 = 0;
    while (attempts < 8 and pumped_total < 2) : (attempts += 1) {
        pumped_total += try backend_impl.waitForCompletions(2 - pumped_total, 2 * std.time.ns_per_s);
    }
    try std.testing.expect(pumped_total >= 2);

    const first = backend_impl.poll().?;
    const second = backend_impl.poll().?;
    try std.testing.expect(backend_impl.poll() == null);
    try std.testing.expectEqual(id_a, first.operation_id);
    try std.testing.expectEqual(id_b, second.operation_id);
    try std.testing.expectEqual(types.CompletionStatus.success, first.status);
    try std.testing.expectEqual(types.CompletionStatus.success, second.status);
    try std.testing.expectEqual(@as(u8, 0xBC), first.buffer.bytes[0]);
}

test "threaded backend returns WouldBlock when max_in_flight is exhausted" {
    var cfg = config.Config.initForTest(1);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 1;
    cfg.submission_queue_capacity = 2;
    cfg.completion_queue_capacity = 2;

    if (!io_caps.threadedBackendEnabled()) {
        try std.testing.expectError(error.Unsupported, ThreadedBackend.init(std.testing.allocator, cfg));
        return;
    }

    var backend_impl = try ThreadedBackend.init(std.testing.allocator, cfg);
    defer backend_impl.deinit();

    var storage: [8]u8 = [_]u8{0} ** 8;
    const buf = types.Buffer{ .bytes = &storage };
    _ = try backend_impl.submit(.{ .nop = buf });
    try std.testing.expectError(error.WouldBlock, backend_impl.submit(.{ .nop = buf }));

    try pumpUntilReady(&backend_impl, 1);
    _ = backend_impl.poll().?;
    _ = try backend_impl.submit(.{ .nop = buf });
}

test "threaded backend supports connect/accept and stream read/write" {
    var cfg = config.Config.initForTest(8);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 2;

    if (!io_caps.threadedBackendEnabled()) {
        try std.testing.expectError(error.Unsupported, ThreadedBackend.init(std.testing.allocator, cfg));
        return;
    }
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var backend_impl = try ThreadedBackend.init(std.testing.allocator, cfg);
    defer backend_impl.deinit();

    const windows = std.os.windows;
    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        windows.ws2_32.AF.INET,
        windows.ws2_32.SOCK.STREAM,
        windows.ws2_32.IPPROTO.TCP,
        null,
        0,
        wsa_flag_overlapped,
    );
    try std.testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);

    var bind_addr = SockaddrAnyWindows.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    var name: windows.ws2_32.sockaddr.in = undefined;
    var name_len: i32 = @sizeOf(windows.ws2_32.sockaddr.in);
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.getsockname(listen_sock, @ptrCast(&name), &name_len));
    const port: u16 = std.mem.bigToNative(u16, name.port);
    try std.testing.expect(port != 0);

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

    const connect_endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } };
    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = client_stream,
        .endpoint = connect_endpoint,
        .timeout_ns = null,
    } });

    try pumpUntilReady(&backend_impl, 2);
    var seen_accept = false;
    var seen_connect = false;
    var drained: usize = 0;
    while (drained < 8 and (!seen_accept or !seen_connect)) : (drained += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == accept_id) {
            seen_accept = true;
            try std.testing.expectEqual(types.OperationTag.accept, completion.tag);
            try std.testing.expectEqual(types.CompletionStatus.success, completion.status);
        } else if (completion.operation_id == connect_id) {
            seen_connect = true;
            try std.testing.expectEqual(types.OperationTag.connect, completion.tag);
            try std.testing.expectEqual(types.CompletionStatus.success, completion.status);
        }
    }
    try std.testing.expect(seen_accept and seen_connect);

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

    try pumpUntilReady(&backend_impl, 2);
    var got_write = false;
    var got_read = false;
    drained = 0;
    while (drained < 8 and (!got_write or !got_read)) : (drained += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == write_id) {
            got_write = true;
            try std.testing.expectEqual(types.OperationTag.stream_write, completion.tag);
            try std.testing.expectEqual(types.CompletionStatus.success, completion.status);
            try std.testing.expectEqual(@as(u32, 5), completion.bytes_transferred);
        } else if (completion.operation_id == read_id) {
            got_read = true;
            try std.testing.expectEqual(types.OperationTag.stream_read, completion.tag);
            try std.testing.expectEqual(types.CompletionStatus.success, completion.status);
            try std.testing.expectEqual(@as(u32, 5), completion.bytes_transferred);
            try std.testing.expectEqualSlices(u8, "hello", completion.buffer.usedSlice());
        }
    }
    try std.testing.expect(got_write and got_read);

    backend_impl.notifyHandleClosed(server_stream.handle);
    backend_impl.notifyHandleClosed(client_stream.handle);
}

test "threaded backend close of pending accept completes closed" {
    var cfg = config.Config.initForTest(4);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 1;

    if (!io_caps.threadedBackendEnabled()) {
        try std.testing.expectError(error.Unsupported, ThreadedBackend.init(std.testing.allocator, cfg));
        return;
    }
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var backend_impl = try ThreadedBackend.init(std.testing.allocator, cfg);
    defer backend_impl.deinit();

    const windows = std.os.windows;
    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        windows.ws2_32.AF.INET,
        windows.ws2_32.SOCK.STREAM,
        windows.ws2_32.IPPROTO.TCP,
        null,
        0,
        wsa_flag_overlapped,
    );
    try std.testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);

    var bind_addr = SockaddrAnyWindows.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, @intFromPtr(listen_sock), true);
    defer backend_impl.notifyHandleClosed(listener_handle);
    const listener = types.Listener{ .handle = listener_handle };

    const reserved_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    const accept_id = try backend_impl.submit(.{ .accept = .{
        .listener = listener,
        .stream = reserved_stream,
        .timeout_ns = null,
    } });
    backend_impl.notifyHandleClosed(listener_handle);

    try pumpUntilReady(&backend_impl, 1);
    const completion = backend_impl.poll().?;
    try std.testing.expectEqual(accept_id, completion.operation_id);
    try std.testing.expectEqual(types.OperationTag.accept, completion.tag);
    try std.testing.expectEqual(types.CompletionStatus.closed, completion.status);
    try std.testing.expectEqual(@as(?types.CompletionErrorTag, .closed), completion.err);
    try std.testing.expectEqual(@as(u32, 0), completion.bytes_transferred);
}

test "threaded backend close of in-flight stream_read completes closed" {
    var cfg = config.Config.initForTest(4);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 1;

    if (!io_caps.threadedBackendEnabled()) {
        try std.testing.expectError(error.Unsupported, ThreadedBackend.init(std.testing.allocator, cfg));
        return;
    }
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var backend_impl = try ThreadedBackend.init(std.testing.allocator, cfg);
    defer backend_impl.deinit();

    const windows = std.os.windows;
    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        windows.ws2_32.AF.INET,
        windows.ws2_32.SOCK.STREAM,
        windows.ws2_32.IPPROTO.TCP,
        null,
        0,
        wsa_flag_overlapped,
    );
    try std.testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);
    defer _ = windows.ws2_32.closesocket(listen_sock);

    var bind_addr = SockaddrAnyWindows.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    var name: windows.ws2_32.sockaddr.in = undefined;
    var name_len: i32 = @sizeOf(windows.ws2_32.sockaddr.in);
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.getsockname(listen_sock, @ptrCast(&name), &name_len));
    const port: u16 = std.mem.bigToNative(u16, name.port);
    try std.testing.expect(port != 0);

    const client_sock = windows.ws2_32.WSASocketW(
        windows.ws2_32.AF.INET,
        windows.ws2_32.SOCK.STREAM,
        windows.ws2_32.IPPROTO.TCP,
        null,
        0,
        wsa_flag_overlapped,
    );
    try std.testing.expect(client_sock != windows.ws2_32.INVALID_SOCKET);
    errdefer _ = windows.ws2_32.closesocket(client_sock);

    var remote_addr = SockaddrAnyWindows.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } });
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.connect(client_sock, remote_addr.ptr(), remote_addr.len()));

    const accepted = windows.ws2_32.accept(listen_sock, null, null);
    try std.testing.expect(accepted != windows.ws2_32.INVALID_SOCKET);
    errdefer _ = windows.ws2_32.closesocket(accepted);

    const server_stream = types.Stream{ .handle = .{ .index = 0, .generation = 1 } };
    const client_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    backend_impl.registerHandle(server_stream.handle, .stream, @intFromPtr(accepted), true);
    backend_impl.registerHandle(client_stream.handle, .stream, @intFromPtr(client_sock), true);
    defer backend_impl.notifyHandleClosed(server_stream.handle);
    defer backend_impl.notifyHandleClosed(client_stream.handle);

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buf = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = read_buf,
        .timeout_ns = null,
    } });

    backend_impl.notifyHandleClosed(server_stream.handle);

    try pumpUntilReady(&backend_impl, 1);
    const completion = backend_impl.poll().?;
    try std.testing.expectEqual(read_id, completion.operation_id);
    try std.testing.expectEqual(types.OperationTag.stream_read, completion.tag);
    try std.testing.expectEqual(types.CompletionStatus.closed, completion.status);
    try std.testing.expectEqual(@as(?types.CompletionErrorTag, .closed), completion.err);
    try std.testing.expectEqual(@as(u32, 0), completion.bytes_transferred);

    backend_impl.notifyHandleClosed(client_stream.handle);
}

test "threaded backend close of pending stream_write completes closed" {
    var cfg = config.Config.initForTest(4);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 1;

    if (!io_caps.threadedBackendEnabled()) {
        try std.testing.expectError(error.Unsupported, ThreadedBackend.init(std.testing.allocator, cfg));
        return;
    }
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var backend_impl = try ThreadedBackend.init(std.testing.allocator, cfg);
    defer backend_impl.deinit();

    const windows = std.os.windows;
    const wsa_flag_overlapped: windows.DWORD = 0x00000001;
    const listen_sock = windows.ws2_32.WSASocketW(
        windows.ws2_32.AF.INET,
        windows.ws2_32.SOCK.STREAM,
        windows.ws2_32.IPPROTO.TCP,
        null,
        0,
        wsa_flag_overlapped,
    );
    try std.testing.expect(listen_sock != windows.ws2_32.INVALID_SOCKET);
    defer _ = windows.ws2_32.closesocket(listen_sock);

    var bind_addr = SockaddrAnyWindows.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 0,
    } });
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.bind(listen_sock, bind_addr.ptr(), bind_addr.len()));
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.listen(listen_sock, 16));

    var name: windows.ws2_32.sockaddr.in = undefined;
    var name_len: i32 = @sizeOf(windows.ws2_32.sockaddr.in);
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.getsockname(listen_sock, @ptrCast(&name), &name_len));
    const port: u16 = std.mem.bigToNative(u16, name.port);
    try std.testing.expect(port != 0);

    const client_sock = windows.ws2_32.WSASocketW(
        windows.ws2_32.AF.INET,
        windows.ws2_32.SOCK.STREAM,
        windows.ws2_32.IPPROTO.TCP,
        null,
        0,
        wsa_flag_overlapped,
    );
    try std.testing.expect(client_sock != windows.ws2_32.INVALID_SOCKET);
    errdefer _ = windows.ws2_32.closesocket(client_sock);

    var remote_addr = SockaddrAnyWindows.fromEndpoint(.{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = port,
    } });
    try std.testing.expectEqual(@as(i32, 0), windows.ws2_32.connect(client_sock, remote_addr.ptr(), remote_addr.len()));

    const accepted = windows.ws2_32.accept(listen_sock, null, null);
    try std.testing.expect(accepted != windows.ws2_32.INVALID_SOCKET);
    errdefer _ = windows.ws2_32.closesocket(accepted);

    const server_stream = types.Stream{ .handle = .{ .index = 0, .generation = 1 } };
    const client_stream = types.Stream{ .handle = .{ .index = 1, .generation = 1 } };
    backend_impl.registerHandle(server_stream.handle, .stream, @intFromPtr(accepted), true);
    backend_impl.registerHandle(client_stream.handle, .stream, @intFromPtr(client_sock), true);
    defer backend_impl.notifyHandleClosed(server_stream.handle);
    defer backend_impl.notifyHandleClosed(client_stream.handle);

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buf = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = server_stream,
        .buffer = read_buf,
        .timeout_ns = null,
    } });

    var write_bytes: [1]u8 = .{'x'};
    var write_buf = types.Buffer{ .bytes = &write_bytes };
    try write_buf.setUsedLen(1);
    const write_id = try backend_impl.submit(.{ .stream_write = .{
        .stream = client_stream,
        .buffer = write_buf,
        .timeout_ns = null,
    } });

    backend_impl.notifyHandleClosed(client_stream.handle);
    backend_impl.notifyHandleClosed(server_stream.handle);

    try pumpUntilReady(&backend_impl, 2);
    var got_read = false;
    var got_write = false;
    var drained: u32 = 0;
    while (drained < 8 and (!got_read or !got_write)) : (drained += 1) {
        const completion = backend_impl.poll() orelse break;
        if (completion.operation_id == read_id) {
            got_read = true;
            try std.testing.expectEqual(types.CompletionStatus.closed, completion.status);
            try std.testing.expectEqual(@as(?types.CompletionErrorTag, .closed), completion.err);
        } else if (completion.operation_id == write_id) {
            got_write = true;
            try std.testing.expectEqual(types.CompletionStatus.closed, completion.status);
            try std.testing.expectEqual(@as(?types.CompletionErrorTag, .closed), completion.err);
        }
    }
    try std.testing.expect(got_read and got_write);
}

test "threaded backend supports file read/write via adopted handle" {
    var cfg = config.Config.initForTest(2);
    cfg.backend_kind = .threaded;
    cfg.threaded_worker_count = 1;

    if (!io_caps.threadedBackendEnabled()) {
        try std.testing.expectError(error.Unsupported, ThreadedBackend.init(std.testing.allocator, cfg));
        return;
    }
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var backend_impl = try ThreadedBackend.init(std.testing.allocator, cfg);
    defer backend_impl.deinit();

    const filename_utf8 = "static_io_threaded_file_io.tmp";

    var filename_w: [64:0]u16 = undefined;
    std.debug.assert(filename_utf8.len + 1 <= filename_w.len);
    for (filename_utf8, 0..) |byte, index| {
        filename_w[index] = byte;
    }
    filename_w[filename_utf8.len] = 0;
    const filename_wz = filename_w[0..filename_utf8.len :0].ptr;
    defer _ = DeleteFileW(filename_wz);

    const windows = std.os.windows;
    const kernel32 = windows.kernel32;
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
    try std.testing.expect(native_handle != windows.INVALID_HANDLE_VALUE);

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
    try pumpUntilReady(&backend_impl, 1);
    const write_completion = backend_impl.poll().?;
    try std.testing.expectEqual(write_id, write_completion.operation_id);
    try std.testing.expectEqual(types.OperationTag.file_write_at, write_completion.tag);
    try std.testing.expectEqual(types.CompletionStatus.success, write_completion.status);
    try std.testing.expectEqual(@as(u32, 4), write_completion.bytes_transferred);
    try std.testing.expectEqual(@as(?types.Handle, file_handle), write_completion.handle);

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buf = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .file_read_at = .{
        .file = file,
        .buffer = read_buf,
        .offset_bytes = 0,
        .timeout_ns = null,
    } });
    try pumpUntilReady(&backend_impl, 1);
    const read_completion = backend_impl.poll().?;
    try std.testing.expectEqual(read_id, read_completion.operation_id);
    try std.testing.expectEqual(types.OperationTag.file_read_at, read_completion.tag);
    try std.testing.expectEqual(types.CompletionStatus.success, read_completion.status);
    try std.testing.expectEqualSlices(u8, "test", read_completion.buffer.usedSlice());
    try std.testing.expectEqual(@as(?types.Handle, file_handle), read_completion.handle);
}

fn pumpUntilReady(backend_impl: *ThreadedBackend, target: u32) !void {
    var pumped_total: u32 = 0;
    var attempts: u32 = 0;
    while (attempts < 20_000 and pumped_total < target) : (attempts += 1) {
        pumped_total += try backend_impl.pump(target - pumped_total);
        std.Thread.yield() catch {};
    }
    try std.testing.expect(pumped_total >= target);
}

extern "kernel32" fn DeleteFileW(lpFileName: std.os.windows.LPCWSTR) callconv(.winapi) std.os.windows.BOOL;
