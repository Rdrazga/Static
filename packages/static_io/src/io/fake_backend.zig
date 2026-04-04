//! Deterministic fake backend used as the runtime parity baseline.
//!
//! The fake backend provides bounded, deterministic in-memory implementations for
//! the typed IO operations (`stream_*`, `file_*`, `accept`, `connect`) so the
//! Runtime does not need an in-memory simulator.

const std = @import("std");
const static_queues = @import("static_queues");
const backend = @import("backend.zig");
const config = @import("config.zig");
const error_map = @import("error_map.zig");
const operation_helpers = @import("operation_helpers.zig");
const operation_ids = @import("operation_ids.zig");
const types = @import("types.zig");

const IdQueue = static_queues.ring_buffer.RingBuffer(u32);
const decodeOperationId = operation_ids.decodeExternalOperationId;
const elapsedSince = operation_helpers.elapsedSince;
const encodeOperationId = operation_ids.encodeExternalOperationId;
const makeSimpleCompletion = operation_helpers.makeSimpleCompletion;
const nextGeneration = operation_ids.nextGeneration;
const operationHasFiniteTimeout = operation_helpers.operationHasFiniteTimeout;
const operationHasImmediateTimeout = operation_helpers.operationHasImmediateTimeout;
const operationTimeoutNs = operation_helpers.operationTimeoutNs;
const operationUsesHandle = operation_helpers.operationUsesHandle;
const validateOperation = operation_helpers.validateOperation;

const stream_capacity: usize = 4096;
const file_capacity: usize = 8192;

const SlotState = enum {
    free,
    pending,
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
    submitted_at: ?std.time.Instant = null,
};

const HandleState = enum {
    free,
    open,
    closed,
};

const HandleSlot = struct {
    generation: u32 = 0,
    state: HandleState = .free,
    kind: types.HandleKind = .file,

    file_size: u32 = 0,
    file_bytes: [file_capacity]u8 = [_]u8{0} ** file_capacity,

    stream_head: u32 = 0,
    stream_len: u32 = 0,
    stream_bytes: [stream_capacity]u8 = [_]u8{0} ** stream_capacity,
};

const ExecResult = union(enum) {
    completed: types.Completion,
    pending,
};

pub const FakeBackend = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    slots: []Slot,
    free_slots: []u32,
    free_len: u32,
    pending: IdQueue,
    completed: IdQueue,

    handles: []HandleSlot,

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

    /// Initializes deterministic in-memory backend state.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!FakeBackend {
        config.validate(cfg) catch |cfg_err| switch (cfg_err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
        };
        std.debug.assert(cfg.max_in_flight > 0);
        std.debug.assert(cfg.submission_queue_capacity > 0);
        std.debug.assert(cfg.completion_queue_capacity > 0);
        std.debug.assert(cfg.handles_max > 0);

        const slot_count: usize = cfg.max_in_flight;
        const queue_cap_pending: usize = cfg.submission_queue_capacity;
        const queue_cap_completed: usize = cfg.completion_queue_capacity;

        const slots = allocator.alloc(Slot, slot_count) catch return error.OutOfMemory;
        errdefer allocator.free(slots);
        @memset(slots, .{});

        const free_slots = allocator.alloc(u32, slot_count) catch return error.OutOfMemory;
        errdefer allocator.free(free_slots);

        var index: usize = 0;
        while (index < free_slots.len) : (index += 1) {
            free_slots[index] = @intCast(index);
        }

        var pending = IdQueue.init(allocator, .{ .capacity = queue_cap_pending }) catch |queue_err| switch (queue_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoSpaceLeft => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
            error.WouldBlock => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
        };
        errdefer pending.deinit();

        var completed = IdQueue.init(allocator, .{ .capacity = queue_cap_completed }) catch |queue_err| switch (queue_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoSpaceLeft => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
            error.WouldBlock => return error.InvalidConfig,
            error.Overflow => return error.Overflow,
        };
        errdefer completed.deinit();

        const handles = allocator.alloc(HandleSlot, cfg.handles_max) catch return error.OutOfMemory;
        errdefer allocator.free(handles);
        @memset(handles, .{});

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .slots = slots,
            .free_slots = free_slots,
            .free_len = cfg.max_in_flight,
            .pending = pending,
            .completed = completed,
            .handles = handles,
        };
    }

    /// Releases all backend-owned allocations.
    pub fn deinit(self: *FakeBackend) void {
        self.allocator.free(self.handles);
        self.completed.deinit();
        self.pending.deinit();
        self.allocator.free(self.free_slots);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Returns a type-erased backend interface for runtime dispatch.
    pub fn asBackend(self: *FakeBackend) backend.Backend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    /// Queues one operation for deterministic execution.
    pub fn submit(self: *FakeBackend, op: types.Operation) backend.SubmitError!types.OperationId {
        if (self.closed) return error.Closed;

        const checked_op = try validateOperation(op);
        const slot_index = try self.allocSlot();
        errdefer self.freeSlot(slot_index);

        const slot = &self.slots[slot_index];
        std.debug.assert(slot.state == .free);
        std.debug.assert(slot.generation != 0);
        const operation_id = encodeOperationId(slot_index, slot.generation);
        slot.state = .pending;
        slot.operation_id = operation_id;
        slot.operation = checked_op;
        slot.cancelled = false;
        slot.closed_on_pump = false;
        slot.submitted_at = if (operationHasFiniteTimeout(checked_op))
            std.time.Instant.now() catch null
        else
            null;

        self.pending.tryPush(slot_index) catch |queue_err| switch (queue_err) {
            error.WouldBlock => return error.WouldBlock,
        };

        return operation_id;
    }

    /// Processes pending operations and queues completed entries.
    pub fn pump(self: *FakeBackend, max_completions: u32) backend.PumpError!u32 {
        std.debug.assert(self.free_len <= self.free_slots.len);
        var completed_count: u32 = 0;
        const pending_budget: usize = self.pending.len();
        var processed: usize = 0;
        while (completed_count < max_completions and processed < pending_budget) : (processed += 1) {
            const slot_index = self.pending.tryPop() catch |queue_err| switch (queue_err) {
                error.WouldBlock => break,
            };

            if (self.processSlot(slot_index)) {
                self.completed.tryPush(slot_index) catch |queue_err| switch (queue_err) {
                    error.WouldBlock => {
                        self.slots[slot_index].state = .pending;
                        self.pending.tryPush(slot_index) catch unreachable;
                        break;
                    },
                };
                completed_count += 1;
            } else {
                self.pending.tryPush(slot_index) catch unreachable;
            }
        }
        return completed_count;
    }

    /// Pops one completed operation, if available.
    pub fn poll(self: *FakeBackend) ?types.Completion {
        const slot_index = self.completed.tryPop() catch |queue_err| switch (queue_err) {
            error.WouldBlock => return null,
        };

        const slot = &self.slots[slot_index];
        if (slot.state != .completed) {
            std.debug.assert(slot.state == .completed);
            return null;
        }
        const completion = slot.completion;
        self.freeSlot(slot_index);
        return completion;
    }

    /// Marks a pending operation as cancelled.
    pub fn cancel(self: *FakeBackend, operation_id: types.OperationId) backend.CancelError!void {
        if (self.closed) return error.Closed;
        const decoded = decodeOperationId(operation_id) orelse return error.NotFound;
        if (decoded.index >= self.slots.len) return error.NotFound;
        const slot = &self.slots[decoded.index];
        if (slot.generation != decoded.generation) return error.NotFound;
        if (slot.state != .pending) return error.NotFound;
        if (slot.operation_id != operation_id) return error.NotFound;
        slot.cancelled = true;
    }

    /// Marks backend as closed and schedules close completions.
    pub fn close(self: *FakeBackend) void {
        if (self.closed) return;
        self.closed = true;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            const slot = &self.slots[index];
            if (slot.state != .pending) continue;
            slot.closed_on_pump = true;
        }
    }

    /// Returns capabilities implemented by the fake backend.
    pub fn capabilities(self: *const FakeBackend) types.CapabilityFlags {
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

    /// Registers runtime handle state for operation validation and emulation.
    pub fn registerHandle(self: *FakeBackend, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        _ = native;
        _ = owned;
        if (!handle.isValid()) return;
        if (handle.index >= self.handles.len) return;
        var slot = &self.handles[handle.index];
        slot.generation = handle.generation;
        slot.state = .open;
        slot.kind = kind;
        switch (kind) {
            .file => self.resetFile(slot),
            .stream => self.resetStream(slot),
            .listener => {},
        }
    }

    /// Marks a handle closed and flags dependent pending operations.
    pub fn notifyHandleClosed(self: *FakeBackend, handle: types.Handle) void {
        if (!handle.isValid()) return;
        if (handle.index >= self.handles.len) return;
        var handle_slot = &self.handles[handle.index];
        if (handle_slot.generation != handle.generation) return;
        handle_slot.state = .closed;

        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            var slot = &self.slots[index];
            if (slot.state != .pending) continue;
            if (!operationUsesHandle(slot.operation, handle)) continue;
            slot.closed_on_pump = true;
        }
    }

    /// Returns true while any pending operation still references `handle`.
    pub fn handleInUse(self: *FakeBackend, handle: types.Handle) bool {
        var index: usize = 0;
        while (index < self.slots.len) : (index += 1) {
            const slot = self.slots[index];
            if (slot.state != .pending) continue;
            if (operationUsesHandle(slot.operation, handle)) return true;
        }
        return false;
    }

    fn allocSlot(self: *FakeBackend) backend.SubmitError!u32 {
        std.debug.assert(self.free_len <= self.free_slots.len);
        if (self.free_len == 0) return error.WouldBlock;
        self.free_len -= 1;
        const slot_index = self.free_slots[self.free_len];
        std.debug.assert(slot_index < self.slots.len);
        std.debug.assert(self.slots[slot_index].state == .free);
        return slot_index;
    }

    fn freeSlot(self: *FakeBackend, slot_index: u32) void {
        std.debug.assert(slot_index < self.slots.len);
        std.debug.assert(self.free_len < self.free_slots.len);
        const slot = &self.slots[slot_index];
        const next_generation = nextGeneration(slot.generation);
        self.slots[slot_index] = .{
            .generation = next_generation,
        };
        self.free_slots[self.free_len] = slot_index;
        self.free_len += 1;
        std.debug.assert(self.free_len <= self.free_slots.len);
    }

    fn processSlot(self: *FakeBackend, slot_index: u32) bool {
        var slot = &self.slots[slot_index];
        std.debug.assert(slot.state == .pending);

        if (slot.cancelled) {
            slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, .cancelled, .cancelled);
            slot.state = .completed;
            return true;
        }

        if (slot.closed_on_pump or self.closed) {
            slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, .closed, .closed);
            slot.state = .completed;
            return true;
        }

        if (operationHasImmediateTimeout(slot.operation)) {
            slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, .timeout, .timeout);
            slot.state = .completed;
            return true;
        }

        switch (self.executeOperation(slot.operation_id, slot.operation)) {
            .completed => |completion| {
                slot.completion = completion;
                slot.state = .completed;
                return true;
            },
            .pending => {
                if (hasOperationTimedOut(slot.operation, slot.submitted_at)) {
                    slot.completion = makeSimpleCompletion(slot.operation_id, slot.operation, .timeout, .timeout);
                    slot.state = .completed;
                    return true;
                }
                return false;
            },
        }
    }

    fn executeOperation(self: *FakeBackend, operation_id: types.OperationId, op: types.Operation) ExecResult {
        return switch (op) {
            .nop => |buf| .{ .completed = .{
                .operation_id = operation_id,
                .tag = .nop,
                .status = .success,
                .bytes_transferred = buf.used_len,
                .buffer = buf,
            } },
            .fill => |fill| blk: {
                var buffer = fill.buffer;
                const write_len: usize = fill.len;
                if (write_len > 0) @memset(buffer.bytes[0..write_len], fill.byte);
                buffer.used_len = fill.len;
                break :blk .{ .completed = .{
                    .operation_id = operation_id,
                    .tag = .fill,
                    .status = .success,
                    .bytes_transferred = fill.len,
                    .buffer = buffer,
                } };
            },
            .stream_read => |read_op| self.execStreamRead(operation_id, read_op),
            .stream_write => |write_op| self.execStreamWrite(operation_id, write_op),
            .file_read_at => |read_op| self.execFileReadAt(operation_id, read_op),
            .file_write_at => |write_op| self.execFileWriteAt(operation_id, write_op),
            .accept => |accept_op| self.execAccept(operation_id, accept_op),
            .connect => |connect_op| self.execConnect(operation_id, connect_op),
        };
    }

    fn execStreamRead(self: *FakeBackend, operation_id: types.OperationId, op: @FieldType(types.Operation, "stream_read")) ExecResult {
        var stream_slot = self.handleForStream(op.stream.handle) catch |err| {
            return .{ .completed = completionFromHandleError(operation_id, .stream_read, op.buffer, err, op.stream.handle) };
        };

        var buffer = op.buffer;
        const available = stream_slot.stream_len;
        if (available == 0) return .pending;
        const read_len: u32 = @intCast(@min(@as(usize, available), buffer.bytes.len));

        if (read_len > 0) {
            copyFromRing(stream_slot.stream_bytes[0..], stream_slot.stream_head, buffer.bytes[0..read_len], read_len);
            const cap_u32: u32 = @intCast(stream_capacity);
            stream_slot.stream_head = (stream_slot.stream_head + read_len) % cap_u32;
            stream_slot.stream_len -= read_len;
        }
        buffer.used_len = read_len;

        return .{ .completed = .{
            .operation_id = operation_id,
            .tag = .stream_read,
            .status = .success,
            .bytes_transferred = read_len,
            .buffer = buffer,
            .handle = op.stream.handle,
        } };
    }

    fn execStreamWrite(self: *FakeBackend, operation_id: types.OperationId, op: @FieldType(types.Operation, "stream_write")) ExecResult {
        var stream_slot = self.handleForStream(op.stream.handle) catch |err| {
            return .{ .completed = completionFromHandleError(operation_id, .stream_write, op.buffer, err, op.stream.handle) };
        };

        const request_len: u32 = op.buffer.used_len;
        const available: u32 = @intCast(stream_capacity - stream_slot.stream_len);
        if (request_len > 0 and available == 0) return .pending;
        const write_len: u32 = @intCast(@min(@as(usize, request_len), @as(usize, available)));
        if (write_len > 0) {
            const cap_u32: u32 = @intCast(stream_capacity);
            const tail = (stream_slot.stream_head + stream_slot.stream_len) % cap_u32;
            copyIntoRing(stream_slot.stream_bytes[0..], tail, op.buffer.bytes[0..write_len], write_len);
            stream_slot.stream_len += write_len;
        }

        return .{ .completed = .{
            .operation_id = operation_id,
            .tag = .stream_write,
            .status = .success,
            .bytes_transferred = write_len,
            .buffer = op.buffer,
            .handle = op.stream.handle,
        } };
    }

    fn execFileReadAt(self: *FakeBackend, operation_id: types.OperationId, op: @FieldType(types.Operation, "file_read_at")) ExecResult {
        var file_slot = self.handleForFile(op.file.handle) catch |err| {
            return .{ .completed = completionFromHandleError(operation_id, .file_read_at, op.buffer, err, op.file.handle) };
        };

        var buffer = op.buffer;
        if (op.offset_bytes > file_slot.file_size) {
            buffer.used_len = 0;
            return .{ .completed = .{
                .operation_id = operation_id,
                .tag = .file_read_at,
                .status = .success,
                .bytes_transferred = 0,
                .buffer = buffer,
                .handle = op.file.handle,
            } };
        }

        const offset: usize = @intCast(op.offset_bytes);
        const available = file_slot.file_size - @as(u32, @intCast(offset));
        const read_len: u32 = @intCast(@min(@as(usize, available), buffer.bytes.len));
        if (read_len > 0) {
            @memcpy(buffer.bytes[0..read_len], file_slot.file_bytes[offset .. offset + read_len]);
        }
        buffer.used_len = read_len;

        return .{ .completed = .{
            .operation_id = operation_id,
            .tag = .file_read_at,
            .status = .success,
            .bytes_transferred = read_len,
            .buffer = buffer,
            .handle = op.file.handle,
        } };
    }

    fn execFileWriteAt(self: *FakeBackend, operation_id: types.OperationId, op: @FieldType(types.Operation, "file_write_at")) ExecResult {
        var file_slot = self.handleForFile(op.file.handle) catch |err| {
            return .{ .completed = completionFromHandleError(operation_id, .file_write_at, op.buffer, err, op.file.handle) };
        };

        if (op.offset_bytes >= file_capacity) {
            return .{ .completed = .{
                .operation_id = operation_id,
                .tag = .file_write_at,
                .status = .invalid_input,
                .bytes_transferred = 0,
                .buffer = op.buffer,
                .err = .invalid_input,
                .handle = op.file.handle,
            } };
        }

        const request_len: u32 = op.buffer.used_len;
        const offset: usize = @intCast(op.offset_bytes);
        const capacity_left = file_capacity - offset;
        const write_len: u32 = @intCast(@min(@as(usize, request_len), capacity_left));
        if (write_len > 0) {
            @memcpy(file_slot.file_bytes[offset .. offset + write_len], op.buffer.bytes[0..write_len]);
            const end = offset + write_len;
            if (end > file_slot.file_size) file_slot.file_size = @intCast(end);
        }

        return .{ .completed = .{
            .operation_id = operation_id,
            .tag = .file_write_at,
            .status = .success,
            .bytes_transferred = write_len,
            .buffer = op.buffer,
            .handle = op.file.handle,
        } };
    }

    fn execAccept(self: *FakeBackend, operation_id: types.OperationId, op: @FieldType(types.Operation, "accept")) ExecResult {
        _ = self.handleForListener(op.listener.handle) catch |err| {
            return .{ .completed = completionFromHandleError(operation_id, .accept, .{ .bytes = &[_]u8{} }, err, op.listener.handle) };
        };

        self.openStreamHandle(op.stream.handle);
        return .{ .completed = .{
            .operation_id = operation_id,
            .tag = .accept,
            .status = .success,
            .bytes_transferred = 0,
            .buffer = .{ .bytes = &[_]u8{} },
            .handle = op.stream.handle,
        } };
    }

    fn execConnect(self: *FakeBackend, operation_id: types.OperationId, op: @FieldType(types.Operation, "connect")) ExecResult {
        if (endpointPort(op.endpoint) == 0) {
            return .{ .completed = makeSimpleCompletion(operation_id, .{ .connect = op }, .invalid_input, .invalid_input) };
        }

        self.openStreamHandle(op.stream.handle);
        return .{ .completed = .{
            .operation_id = operation_id,
            .tag = .connect,
            .status = .success,
            .bytes_transferred = 0,
            .buffer = .{ .bytes = &[_]u8{} },
            .handle = op.stream.handle,
            .endpoint = op.endpoint,
        } };
    }

    fn openStreamHandle(self: *FakeBackend, handle: types.Handle) void {
        if (!handle.isValid()) return;
        if (handle.index >= self.handles.len) return;
        var slot = &self.handles[handle.index];
        slot.generation = handle.generation;
        slot.state = .open;
        slot.kind = .stream;
        self.resetStream(slot);
    }

    fn handleForStream(self: *FakeBackend, handle: types.Handle) error{ InvalidInput, Closed }!*HandleSlot {
        return self.validateHandle(handle, .stream);
    }

    fn handleForFile(self: *FakeBackend, handle: types.Handle) error{ InvalidInput, Closed }!*HandleSlot {
        return self.validateHandle(handle, .file);
    }

    fn handleForListener(self: *FakeBackend, handle: types.Handle) error{ InvalidInput, Closed }!*HandleSlot {
        return self.validateHandle(handle, .listener);
    }

    fn validateHandle(self: *FakeBackend, handle: types.Handle, expected_kind: types.HandleKind) error{ InvalidInput, Closed }!*HandleSlot {
        if (!handle.isValid()) return error.InvalidInput;
        if (handle.index >= self.handles.len) return error.InvalidInput;
        var slot = &self.handles[handle.index];
        if (slot.generation != handle.generation) return error.InvalidInput;
        if (slot.kind != expected_kind) return error.InvalidInput;
        return switch (slot.state) {
            .open => slot,
            .closed => error.Closed,
            .free => error.InvalidInput,
        };
    }

    fn resetFile(_: *FakeBackend, slot: *HandleSlot) void {
        slot.file_size = 0;
        @memset(&slot.file_bytes, 0);
    }

    fn resetStream(_: *FakeBackend, slot: *HandleSlot) void {
        slot.stream_head = 0;
        slot.stream_len = 0;
        @memset(&slot.stream_bytes, 0);
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const FakeBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};

fn endpointPort(endpoint: types.Endpoint) u16 {
    return switch (endpoint) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
}

fn hasOperationTimedOut(op: types.Operation, start_instant: ?std.time.Instant) bool {
    const timeout_ns = operationTimeoutNs(op) orelse return false;
    if (timeout_ns == 0) return true;
    const start = start_instant orelse return true;
    const elapsed_ns = elapsedSince(start) orelse return true;
    return elapsed_ns >= timeout_ns;
}

fn completionFromHandleError(
    operation_id: types.OperationId,
    tag: types.OperationTag,
    buffer: types.Buffer,
    err: anyerror,
    handle: types.Handle,
) types.Completion {
    return switch (err) {
        error.Closed => .{
            .operation_id = operation_id,
            .tag = tag,
            .status = .closed,
            .bytes_transferred = 0,
            .buffer = buffer,
            .err = .closed,
            .handle = handle,
        },
        else => .{
            .operation_id = operation_id,
            .tag = tag,
            .status = .invalid_input,
            .bytes_transferred = 0,
            .buffer = buffer,
            .err = .invalid_input,
            .handle = handle,
        },
    };
}

fn copyIntoRing(dst_ring: []u8, head: u32, src: []const u8, count: u32) void {
    if (count == 0) return;
    const head_usize: usize = head;
    const ring_len: usize = dst_ring.len;
    const count_usize: usize = count;

    const first_len: usize = @min(count_usize, ring_len - head_usize);
    @memcpy(dst_ring[head_usize .. head_usize + first_len], src[0..first_len]);
    const remaining: usize = count_usize - first_len;
    if (remaining > 0) {
        @memcpy(dst_ring[0..remaining], src[first_len .. first_len + remaining]);
    }
}

fn copyFromRing(src_ring: []const u8, head: u32, dst: []u8, count: u32) void {
    if (count == 0) return;
    const head_usize: usize = head;
    const ring_len: usize = src_ring.len;
    const count_usize: usize = count;

    const first_len: usize = @min(count_usize, ring_len - head_usize);
    @memcpy(dst[0..first_len], src_ring[head_usize .. head_usize + first_len]);
    const remaining: usize = count_usize - first_len;
    if (remaining > 0) {
        @memcpy(dst[first_len .. first_len + remaining], src_ring[0..remaining]);
    }
}

test "fake backend preserves deterministic completion ordering" {
    var backend_impl = try FakeBackend.init(std.testing.allocator, config.Config.initForTest(2));
    defer backend_impl.deinit();

    var storage_a: [8]u8 = [_]u8{0} ** 8;
    var storage_b: [8]u8 = [_]u8{0} ** 8;
    const buf_a = types.Buffer{ .bytes = &storage_a };
    const buf_b = types.Buffer{ .bytes = &storage_b };

    const id_a = try backend_impl.submit(.{ .fill = .{
        .buffer = buf_a,
        .len = 4,
        .byte = 0xAA,
    } });
    const id_b = try backend_impl.submit(.{ .nop = buf_b });
    try std.testing.expectError(error.WouldBlock, backend_impl.submit(.{ .nop = buf_b }));

    _ = try backend_impl.pump(8);
    const first = backend_impl.poll().?;
    const second = backend_impl.poll().?;
    try std.testing.expect(backend_impl.poll() == null);

    try std.testing.expectEqual(id_a, first.operation_id);
    try std.testing.expectEqual(id_b, second.operation_id);
    try std.testing.expectEqual(types.CompletionStatus.success, first.status);
    try std.testing.expectEqual(types.CompletionStatus.success, second.status);
    try std.testing.expectEqual(@as(u8, 0xAA), first.buffer.bytes[0]);
}

test "fake backend supports typed stream write then read roundtrip" {
    var backend_impl = try FakeBackend.init(std.testing.allocator, config.Config.initForTest(4));
    defer backend_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9000,
    } };
    const stream = types.Stream{ .handle = .{ .index = 0, .generation = 1 } };
    const connect_id = try backend_impl.submit(.{ .connect = .{
        .stream = stream,
        .endpoint = endpoint,
        .timeout_ns = null,
    } });

    var write_bytes: [4]u8 = .{ 't', 'e', 's', 't' };
    var write_buffer = types.Buffer{ .bytes = &write_bytes };
    try write_buffer.setUsedLen(4);
    const write_id = try backend_impl.submit(.{ .stream_write = .{
        .stream = stream,
        .buffer = write_buffer,
        .timeout_ns = null,
    } });

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buffer = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = stream,
        .buffer = read_buffer,
        .timeout_ns = null,
    } });

    _ = try backend_impl.pump(8);
    const connect_completion = backend_impl.poll().?;
    const write_completion = backend_impl.poll().?;
    const read_completion = backend_impl.poll().?;
    try std.testing.expect(backend_impl.poll() == null);

    try std.testing.expectEqual(connect_id, connect_completion.operation_id);
    try std.testing.expectEqual(write_id, write_completion.operation_id);
    try std.testing.expectEqual(read_id, read_completion.operation_id);
    try std.testing.expectEqualSlices(u8, "test", read_completion.buffer.usedSlice());
}

test "fake backend close forces pending stream operations to closed" {
    var backend_impl = try FakeBackend.init(std.testing.allocator, config.Config.initForTest(4));
    defer backend_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9001,
    } };
    const stream = types.Stream{ .handle = .{ .index = 0, .generation = 1 } };
    _ = try backend_impl.submit(.{ .connect = .{
        .stream = stream,
        .endpoint = endpoint,
        .timeout_ns = null,
    } });
    _ = try backend_impl.pump(1);
    _ = backend_impl.poll().?;

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buffer = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = stream,
        .buffer = read_buffer,
        .timeout_ns = null,
    } });

    backend_impl.notifyHandleClosed(stream.handle);
    _ = try backend_impl.pump(4);
    const read_completion = backend_impl.poll().?;
    try std.testing.expectEqual(read_id, read_completion.operation_id);
    try std.testing.expectEqual(types.CompletionStatus.closed, read_completion.status);
}

test "fake backend immediate timeout produces timeout completion" {
    var backend_impl = try FakeBackend.init(std.testing.allocator, config.Config.initForTest(4));
    defer backend_impl.deinit();

    const endpoint = types.Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9002,
    } };
    const stream = types.Stream{ .handle = .{ .index = 0, .generation = 1 } };
    _ = try backend_impl.submit(.{ .connect = .{
        .stream = stream,
        .endpoint = endpoint,
        .timeout_ns = null,
    } });
    _ = try backend_impl.pump(1);
    _ = backend_impl.poll().?;

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buffer = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = stream,
        .buffer = read_buffer,
        .timeout_ns = 0,
    } });

    _ = try backend_impl.pump(1);
    const completion = backend_impl.poll().?;
    try std.testing.expectEqual(read_id, completion.operation_id);
    try std.testing.expectEqual(types.CompletionStatus.timeout, completion.status);
    try std.testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), completion.err);
}

test "fake backend error completions have zero progress and consistent status" {
    var backend_impl = try FakeBackend.init(std.testing.allocator, config.Config.initForTest(8));
    defer backend_impl.deinit();

    const listener_handle: types.Handle = .{ .index = 0, .generation = 1 };
    backend_impl.registerHandle(listener_handle, .listener, 0, true);

    const stream_handle: types.Handle = .{ .index = 1, .generation = 1 };
    backend_impl.registerHandle(stream_handle, .stream, 0, true);
    const stream = types.Stream{ .handle = stream_handle };

    var read_bytes: [8]u8 = [_]u8{0} ** 8;
    const read_buf = types.Buffer{ .bytes = &read_bytes };

    // Invalid input => rejected at submit time, matching the real backends.
    try std.testing.expectError(error.InvalidInput, backend_impl.submit(.{ .connect = .{
        .stream = stream,
        .endpoint = .{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = 0 } },
        .timeout_ns = null,
    } }));
    try std.testing.expect(backend_impl.poll() == null);

    // Immediate timeout => timeout completion.
    const timeout_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = stream,
        .buffer = read_buf,
        .timeout_ns = 0,
    } });
    _ = try backend_impl.pump(1);
    const timeout_completion = backend_impl.poll().?;
    try std.testing.expectEqual(timeout_id, timeout_completion.operation_id);
    try std.testing.expectEqual(@as(?types.CompletionErrorTag, .timeout), timeout_completion.err);
    try std.testing.expectEqual(@as(u32, 0), timeout_completion.bytes_transferred);
    try std.testing.expectEqual(error_map.statusFromTag(timeout_completion.err.?), timeout_completion.status);

    // Cancel => cancelled completion.
    const cancel_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = stream,
        .buffer = read_buf,
        .timeout_ns = null,
    } });
    try backend_impl.cancel(cancel_id);
    _ = try backend_impl.pump(1);
    const cancel_completion = backend_impl.poll().?;
    try std.testing.expectEqual(cancel_id, cancel_completion.operation_id);
    try std.testing.expectEqual(@as(?types.CompletionErrorTag, .cancelled), cancel_completion.err);
    try std.testing.expectEqual(@as(u32, 0), cancel_completion.bytes_transferred);
    try std.testing.expectEqual(error_map.statusFromTag(cancel_completion.err.?), cancel_completion.status);

    // Close => closed completion.
    const close_id = try backend_impl.submit(.{ .stream_read = .{
        .stream = stream,
        .buffer = read_buf,
        .timeout_ns = null,
    } });
    backend_impl.notifyHandleClosed(stream_handle);
    backend_impl.notifyHandleClosed(listener_handle);
    _ = try backend_impl.pump(1);
    const close_completion = backend_impl.poll().?;
    try std.testing.expectEqual(close_id, close_completion.operation_id);
    try std.testing.expectEqual(@as(?types.CompletionErrorTag, .closed), close_completion.err);
    try std.testing.expectEqual(@as(u32, 0), close_completion.bytes_transferred);
    try std.testing.expectEqual(error_map.statusFromTag(close_completion.err.?), close_completion.status);
}

test "fake backend file write then read roundtrip" {
    var backend_impl = try FakeBackend.init(std.testing.allocator, config.Config.initForTest(4));
    defer backend_impl.deinit();

    const file = types.File{ .handle = .{ .index = 1, .generation = 1 } };
    backend_impl.registerHandle(file.handle, .file, 0, true);

    var write_bytes: [3]u8 = .{ 'a', 'b', 'c' };
    var write_buffer = types.Buffer{ .bytes = &write_bytes };
    try write_buffer.setUsedLen(3);
    const write_id = try backend_impl.submit(.{ .file_write_at = .{
        .file = file,
        .buffer = write_buffer,
        .offset_bytes = 0,
        .timeout_ns = null,
    } });

    var read_bytes: [3]u8 = [_]u8{0} ** 3;
    const read_buffer = types.Buffer{ .bytes = &read_bytes };
    const read_id = try backend_impl.submit(.{ .file_read_at = .{
        .file = file,
        .buffer = read_buffer,
        .offset_bytes = 0,
        .timeout_ns = null,
    } });

    _ = try backend_impl.pump(8);
    const write_completion = backend_impl.poll().?;
    const read_completion = backend_impl.poll().?;
    try std.testing.expect(backend_impl.poll() == null);

    try std.testing.expectEqual(write_id, write_completion.operation_id);
    try std.testing.expectEqual(@as(u32, 3), write_completion.bytes_transferred);
    try std.testing.expectEqual(read_id, read_completion.operation_id);
    try std.testing.expectEqualSlices(u8, "abc", read_completion.buffer.usedSlice());
}
