const contracts = @import("../contracts.zig");
const shared = @import("shared.zig");

pub fn requireTryQueue(comptime Q: type, comptime T: type) void {
    shared.requireDecl(Q, "Element");
    if (Q.Element != T) {
        @compileError("`Element` mismatch for `" ++ @typeName(Q) ++ "`.");
    }

    shared.requireDecl(Q, "concurrency");
    if (@TypeOf(Q.concurrency) != contracts.Concurrency) {
        @compileError("`concurrency` on `" ++ @typeName(Q) ++ "` must be `contracts.Concurrency`.");
    }

    shared.requireDecl(Q, "is_lock_free");
    if (@TypeOf(Q.is_lock_free) != bool) {
        @compileError("`is_lock_free` on `" ++ @typeName(Q) ++ "` must be bool.");
    }

    shared.requireBoolDecl(Q, "supports_close", false);
    shared.requireBoolDecl(Q, "supports_blocking_wait", false);

    shared.requireDecl(Q, "len_semantics");
    if (@TypeOf(Q.len_semantics) != contracts.LenSemantics) {
        @compileError("`len_semantics` on `" ++ @typeName(Q) ++ "` must be `contracts.LenSemantics`.");
    }

    shared.requireErrorSetType(Q, "TrySendError");
    shared.requireErrorSetType(Q, "TryRecvError");

    shared.requireMethod(Q, "capacity");
    const capacity_info = @typeInfo(@TypeOf(Q.capacity)).@"fn";
    if (capacity_info.params.len != 1 or capacity_info.params[0].type.? != *const Q or capacity_info.return_type.? != usize) {
        @compileError("`capacity(self: *const Self) usize` required on `" ++ @typeName(Q) ++ "`.");
    }

    shared.requireMethod(Q, "len");
    const len_info = @typeInfo(@TypeOf(Q.len)).@"fn";
    // Note: `len` remains `*const` at the concept boundary. Implementations are
    // allowed to use interior mutability for synchronization (for example, a
    // mutex lock in `len`) as long as the operation remains logically read-only.
    if (len_info.params.len != 1 or len_info.params[0].type.? != *const Q or len_info.return_type.? != usize) {
        @compileError("`len(self: *const Self) usize` required on `" ++ @typeName(Q) ++ "`.");
    }

    shared.requireMethod(Q, "isEmpty");
    const empty_info = @typeInfo(@TypeOf(Q.isEmpty)).@"fn";
    if (empty_info.params.len != 1 or empty_info.params[0].type.? != *const Q or empty_info.return_type.? != bool) {
        @compileError("`isEmpty(self: *const Self) bool` required on `" ++ @typeName(Q) ++ "`.");
    }

    shared.requireMethod(Q, "trySend");
    const send_info = @typeInfo(@TypeOf(Q.trySend)).@"fn";
    if (send_info.params.len != 2 or send_info.params[0].type.? != *Q or send_info.params[1].type.? != T or send_info.return_type.? != Q.TrySendError!void) {
        @compileError("`trySend(self: *Self, value: T) TrySendError!void` required on `" ++ @typeName(Q) ++ "`.");
    }

    shared.requireMethod(Q, "tryRecv");
    const recv_info = @typeInfo(@TypeOf(Q.tryRecv)).@"fn";
    if (recv_info.params.len != 1 or recv_info.params[0].type.? != *Q or recv_info.return_type.? != Q.TryRecvError!T) {
        @compileError("`tryRecv(self: *Self) TryRecvError!T` required on `" ++ @typeName(Q) ++ "`.");
    }
}
