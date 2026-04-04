//! Windows backend selector.

const std = @import("std");
const backend = @import("../backend.zig");
const config = @import("../config.zig");
const iocp_backend = @import("windows/iocp_backend.zig");
const types = @import("../types.zig");

/// Thin wrapper around the Windows IOCP backend implementation.
pub const WindowsBackend = struct {
    inner: iocp_backend.IocpBackend,

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

    /// Initializes the Windows backend.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) backend.InitError!WindowsBackend {
        return .{
            .inner = try iocp_backend.IocpBackend.init(allocator, cfg),
        };
    }

    /// Releases Windows backend resources.
    pub fn deinit(self: *WindowsBackend) void {
        self.inner.deinit();
        self.* = undefined;
    }

    /// Returns a type-erased backend interface for runtime dispatch.
    pub fn asBackend(self: *WindowsBackend) backend.Backend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    /// Returns allocator used by the backend.
    pub fn getAllocator(self: *const WindowsBackend) std.mem.Allocator {
        return self.inner.getAllocator();
    }

    /// Submits one operation to IOCP.
    pub fn submit(self: *WindowsBackend, op: types.Operation) backend.SubmitError!types.OperationId {
        return self.inner.submit(op);
    }

    /// Pumps ready completions from the IOCP port.
    pub fn pump(self: *WindowsBackend, max_completions: u32) backend.PumpError!u32 {
        std.debug.assert(max_completions > 0);
        return self.inner.pump(max_completions);
    }

    /// Pops one completion if available.
    pub fn poll(self: *WindowsBackend) ?types.Completion {
        return self.inner.poll();
    }

    /// Attempts to cancel an in-flight operation.
    pub fn cancel(self: *WindowsBackend, operation_id: types.OperationId) backend.CancelError!void {
        try self.inner.cancel(operation_id);
    }

    /// Requests backend shutdown.
    pub fn close(self: *WindowsBackend) void {
        self.inner.close();
    }

    /// Returns supported feature flags.
    pub fn capabilities(self: *const WindowsBackend) types.CapabilityFlags {
        return self.inner.capabilities();
    }

    /// Registers runtime handle metadata with the backend.
    pub fn registerHandle(self: *WindowsBackend, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        self.inner.registerHandle(handle, kind, native, owned);
    }

    /// Notifies backend that a runtime handle closed.
    pub fn notifyHandleClosed(self: *WindowsBackend, handle: types.Handle) void {
        self.inner.notifyHandleClosed(handle);
    }

    /// Returns true while `handle` is referenced by in-flight work.
    pub fn handleInUse(self: *WindowsBackend, handle: types.Handle) bool {
        return self.inner.handleInUse(handle);
    }

    /// Waits for completions, optionally bounded by timeout.
    pub fn waitForCompletions(self: *WindowsBackend, max_completions: u32, timeout_ns: ?u64) backend.PumpError!u32 {
        std.debug.assert(max_completions > 0);
        return self.inner.waitForCompletions(max_completions, timeout_ns);
    }

    /// Wakes a blocked wait call.
    pub fn wakeup(self: *WindowsBackend) void {
        self.inner.wakeup();
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn submitVTable(ctx: *anyopaque, op: types.Operation) backend.SubmitError!types.OperationId {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        return self.submit(op);
    }

    fn pumpVTable(ctx: *anyopaque, max_completions: u32) backend.PumpError!u32 {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        return self.pump(max_completions);
    }

    fn pollVTable(ctx: *anyopaque) ?types.Completion {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn cancelVTable(ctx: *anyopaque, operation_id: types.OperationId) backend.CancelError!void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        try self.cancel(operation_id);
    }

    fn closeVTable(ctx: *anyopaque) void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn capabilitiesVTable(ctx: *const anyopaque) types.CapabilityFlags {
        const self: *const WindowsBackend = @ptrCast(@alignCast(ctx));
        return self.capabilities();
    }

    fn registerHandleVTable(ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        self.registerHandle(handle, kind, native, owned);
    }

    fn notifyHandleClosedVTable(ctx: *anyopaque, handle: types.Handle) void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        self.notifyHandleClosed(handle);
    }

    fn handleInUseVTable(ctx: *anyopaque, handle: types.Handle) bool {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        return self.handleInUse(handle);
    }
};
