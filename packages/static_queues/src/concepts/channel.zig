const contracts = @import("../contracts.zig");
const sync = @import("static_sync");
const shared = @import("shared.zig");

pub fn requireChannel(comptime C: type, comptime T: type) void {
    shared.requireDecl(C, "Element");
    if (C.Element != T) {
        @compileError("`Element` mismatch for `" ++ @typeName(C) ++ "`.");
    }

    shared.requireDecl(C, "concurrency");
    if (@TypeOf(C.concurrency) != contracts.Concurrency) {
        @compileError("`concurrency` on `" ++ @typeName(C) ++ "` must be `contracts.Concurrency`.");
    }
    if (C.concurrency != .mpmc and C.concurrency != .spsc) {
        @compileError("`Channel` concept requires `.mpmc` or `.spsc` concurrency.");
    }

    shared.requireDecl(C, "is_lock_free");
    if (@TypeOf(C.is_lock_free) != bool) {
        @compileError("`is_lock_free` on `" ++ @typeName(C) ++ "` must be bool.");
    }

    shared.requireBoolDecl(C, "supports_close", true);

    shared.requireDecl(C, "supports_blocking_wait");
    if (@TypeOf(C.supports_blocking_wait) != bool) {
        @compileError("`supports_blocking_wait` on `" ++ @typeName(C) ++ "` must be bool.");
    }

    shared.requireDecl(C, "len_semantics");
    if (@TypeOf(C.len_semantics) != contracts.LenSemantics) {
        @compileError("`len_semantics` on `" ++ @typeName(C) ++ "` must be `contracts.LenSemantics`.");
    }

    shared.requireErrorSetType(C, "TrySendError");
    shared.requireErrorSetType(C, "TryRecvError");

    shared.requireMethod(C, "close");
    const close_info = @typeInfo(@TypeOf(C.close)).@"fn";
    if (close_info.params.len != 1 or close_info.params[0].type.? != *C or close_info.return_type.? != void) {
        @compileError("`close(self: *Self) void` required on `" ++ @typeName(C) ++ "`.");
    }

    shared.requireMethod(C, "trySend");
    const try_send_info = @typeInfo(@TypeOf(C.trySend)).@"fn";
    if (try_send_info.params.len != 2 or try_send_info.params[0].type.? != *C or try_send_info.params[1].type.? != T or try_send_info.return_type.? != C.TrySendError!void) {
        @compileError("`trySend(self: *Self, value: T) TrySendError!void` required on `" ++ @typeName(C) ++ "`.");
    }

    shared.requireMethod(C, "tryRecv");
    const try_recv_info = @typeInfo(@TypeOf(C.tryRecv)).@"fn";
    if (try_recv_info.params.len != 1 or try_recv_info.params[0].type.? != *C or try_recv_info.return_type.? != C.TryRecvError!T) {
        @compileError("`tryRecv(self: *Self) TryRecvError!T` required on `" ++ @typeName(C) ++ "`.");
    }

    if (C.supports_blocking_wait) {
        shared.requireErrorSetType(C, "SendError");
        shared.requireErrorSetType(C, "RecvError");

        shared.requireMethod(C, "send");
        const send_info = @typeInfo(@TypeOf(C.send)).@"fn";
        if (send_info.params.len != 3 or send_info.params[0].type.? != *C or send_info.params[1].type.? != T or send_info.params[2].type.? != ?sync.cancel.CancelToken or send_info.return_type.? != C.SendError!void) {
            @compileError("`send(self: *Self, value: T, cancel: ?CancelToken) SendError!void` required on `" ++ @typeName(C) ++ "`.");
        }

        shared.requireMethod(C, "recv");
        const recv_info = @typeInfo(@TypeOf(C.recv)).@"fn";
        if (recv_info.params.len != 2 or recv_info.params[0].type.? != *C or recv_info.params[1].type.? != ?sync.cancel.CancelToken or recv_info.return_type.? != C.RecvError!T) {
            @compileError("`recv(self: *Self, cancel: ?CancelToken) RecvError!T` required on `" ++ @typeName(C) ++ "`.");
        }
    }
}
