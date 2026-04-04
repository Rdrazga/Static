//! POSIX backend selector.

const builtin = @import("builtin");
const std = @import("std");
const backend = @import("../backend.zig");
const config = @import("../config.zig");
const linux_backend = @import("linux/io_uring_backend.zig");
const bsd_backend = @import("bsd/kqueue_backend.zig");
const types = @import("../types.zig");

const Inner = union(enum) {
    linux: linux_backend.IoUringBackend,
    bsd: bsd_backend.KqueueBackend,
};

pub const PosixBackend = struct {
    inner: Inner,

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

    /// Initializes the host POSIX backend implementation.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!PosixBackend {
        return switch (builtin.os.tag) {
            .linux => .{
                .inner = .{ .linux = try linux_backend.IoUringBackend.init(allocator, cfg) },
            },
            .macos, .freebsd, .openbsd, .netbsd, .dragonfly => .{
                .inner = .{ .bsd = try bsd_backend.KqueueBackend.init(allocator, cfg) },
            },
            else => error.Unsupported,
        };
    }

    /// Releases backend resources.
    pub fn deinit(self: *PosixBackend) void {
        switch (self.inner) {
            .linux => |*linux| linux.deinit(),
            .bsd => |*bsd| bsd.deinit(),
        }
        self.* = undefined;
    }

    /// Returns a type-erased backend interface for runtime dispatch.
    pub fn asBackend(self: *PosixBackend) backend.Backend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    /// Returns allocator used by the selected backend.
    pub fn getAllocator(self: *const PosixBackend) std.mem.Allocator {
        return switch (self.inner) {
            .linux => |*linux| linux.getAllocator(),
            .bsd => |*bsd| bsd.getAllocator(),
        };
    }

    /// Submits one operation to the selected backend.
    pub fn submit(self: *PosixBackend, op: types.Operation) backend.SubmitError!types.OperationId {
        return switch (self.inner) {
            .linux => |*linux| linux.submit(op),
            .bsd => |*bsd| bsd.submit(op),
        };
    }

    /// Pumps ready completions from the selected backend.
    pub fn pump(self: *PosixBackend, max_completions: u32) backend.PumpError!u32 {
        std.debug.assert(max_completions > 0);
        return switch (self.inner) {
            .linux => |*linux| linux.pump(max_completions),
            .bsd => |*bsd| bsd.pump(max_completions),
        };
    }

    /// Pops one completion if available.
    pub fn poll(self: *PosixBackend) ?types.Completion {
        return switch (self.inner) {
            .linux => |*linux| linux.poll(),
            .bsd => |*bsd| bsd.poll(),
        };
    }

    /// Attempts to cancel an in-flight operation.
    pub fn cancel(self: *PosixBackend, operation_id: types.OperationId) backend.CancelError!void {
        switch (self.inner) {
            .linux => |*linux| try linux.cancel(operation_id),
            .bsd => |*bsd| try bsd.cancel(operation_id),
        }
    }

    /// Requests backend shutdown.
    pub fn close(self: *PosixBackend) void {
        switch (self.inner) {
            .linux => |*linux| linux.close(),
            .bsd => |*bsd| bsd.close(),
        }
    }

    /// Returns supported feature flags.
    pub fn capabilities(self: *const PosixBackend) types.CapabilityFlags {
        return switch (self.inner) {
            .linux => |*linux| linux.capabilities(),
            .bsd => |*bsd| bsd.capabilities(),
        };
    }

    /// Registers runtime handle metadata with the backend.
    pub fn registerHandle(self: *PosixBackend, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        switch (self.inner) {
            .linux => |*linux| linux.registerHandle(handle, kind, native, owned),
            .bsd => |*bsd| bsd.registerHandle(handle, kind, native, owned),
        }
    }

    /// Notifies backend that a runtime handle closed.
    pub fn notifyHandleClosed(self: *PosixBackend, handle: types.Handle) void {
        switch (self.inner) {
            .linux => |*linux| linux.notifyHandleClosed(handle),
            .bsd => |*bsd| bsd.notifyHandleClosed(handle),
        }
    }

    /// Returns true while `handle` is referenced by in-flight work.
    pub fn handleInUse(self: *PosixBackend, handle: types.Handle) bool {
        return switch (self.inner) {
            .linux => |*linux| linux.handleInUse(handle),
            .bsd => |*bsd| bsd.handleInUse(handle),
        };
    }

    /// Waits for completions, optionally bounded by timeout.
    pub fn waitForCompletions(self: *PosixBackend, max_completions: u32, timeout_ns: ?u64) backend.PumpError!u32 {
        std.debug.assert(max_completions > 0);
        return switch (self.inner) {
            .linux => |*linux| linux.waitForCompletions(max_completions, timeout_ns),
            .bsd => |*bsd| bsd.waitForCompletions(max_completions, timeout_ns),
        };
    }

    /// Wakes a blocked wait call.
    pub fn wakeup(self: *PosixBackend) void {
        switch (self.inner) {
            .linux => |*linux| linux.wakeup(),
            .bsd => |*bsd| bsd.wakeup(),
        }
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const PosixBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *PosixBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};
