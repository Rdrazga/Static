//! Explicit backend interface contract for `static_io`.

const std = @import("std");
const core = @import("static_core");
const types = @import("types.zig");

/// Errors returned when constructing a backend instance.
pub const InitError = error{
    OutOfMemory,
    InvalidConfig,
    Overflow,
    Unsupported,
};

/// Errors returned when queueing an operation for execution.
pub const SubmitError = error{
    WouldBlock,
    Closed,
    InvalidInput,
    Unsupported,
};

/// Errors returned when asking a backend to progress work.
pub const PumpError = error{
    InvalidInput,
    Unsupported,
};

/// Errors returned when requesting cancellation.
pub const CancelError = error{
    NotFound,
    Closed,
    Unsupported,
};

comptime {
    core.errors.assertVocabularySubset(InitError);
    core.errors.assertVocabularySubset(SubmitError);
    core.errors.assertVocabularySubset(PumpError);
    core.errors.assertVocabularySubset(CancelError);
}

/// Dispatch table for runtime/backend polymorphism.
pub const BackendVTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
    submit: *const fn (ctx: *anyopaque, op: types.Operation) SubmitError!types.OperationId,
    pump: *const fn (ctx: *anyopaque, max_completions: u32) PumpError!u32,
    poll: *const fn (ctx: *anyopaque) ?types.Completion,
    cancel: *const fn (ctx: *anyopaque, operation_id: types.OperationId) CancelError!void,
    close: *const fn (ctx: *anyopaque) void,
    capabilities: *const fn (ctx: *const anyopaque) types.CapabilityFlags,
    registerHandle: *const fn (ctx: *anyopaque, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void,
    notifyHandleClosed: *const fn (ctx: *anyopaque, handle: types.Handle) void,
    handleInUse: *const fn (ctx: *anyopaque, handle: types.Handle) bool,
};

/// Type-erased backend object plus vtable.
pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const BackendVTable,

    /// Releases backend resources and invalidates the backend instance.
    pub fn deinit(self: *Backend) void {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        self.vtable.deinit(self.ctx);
    }

    /// Submits a single operation to the backend.
    pub fn submit(self: *Backend, op: types.Operation) SubmitError!types.OperationId {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        return self.vtable.submit(self.ctx, op);
    }

    /// Pumps ready completions into the backend completion queue.
    pub fn pump(self: *Backend, max_completions: u32) PumpError!u32 {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        return self.vtable.pump(self.ctx, max_completions);
    }

    /// Pops one completion if available.
    pub fn poll(self: *Backend) ?types.Completion {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        return self.vtable.poll(self.ctx);
    }

    /// Attempts to cancel an in-flight operation.
    pub fn cancel(self: *Backend, operation_id: types.OperationId) CancelError!void {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        return self.vtable.cancel(self.ctx, operation_id);
    }

    /// Initiates backend shutdown.
    pub fn close(self: *Backend) void {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        self.vtable.close(self.ctx);
    }

    /// Returns the backend capability bitset.
    pub fn capabilities(self: *const Backend) types.CapabilityFlags {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        return self.vtable.capabilities(self.ctx);
    }

    /// Registers a runtime handle with backend-native metadata.
    pub fn registerHandle(self: *Backend, handle: types.Handle, kind: types.HandleKind, native: types.NativeHandle, owned: bool) void {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        self.vtable.registerHandle(self.ctx, handle, kind, native, owned);
    }

    /// Notifies the backend that the runtime closed a handle.
    pub fn notifyHandleClosed(self: *Backend, handle: types.Handle) void {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        self.vtable.notifyHandleClosed(self.ctx, handle);
    }

    /// Returns true while any in-flight operation still references `handle`.
    pub fn handleInUse(self: *Backend, handle: types.Handle) bool {
        std.debug.assert(@intFromPtr(self.vtable) != 0);
        return self.vtable.handleInUse(self.ctx, handle);
    }
};
