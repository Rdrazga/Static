const contracts = @import("../contracts.zig");
const shared = @import("shared.zig");

pub fn requireRegisteredFanoutRing(comptime F: type, comptime T: type) void {
    shared.requireDecl(F, "Element");
    if (F.Element != T) {
        @compileError("`Element` mismatch for `" ++ @typeName(F) ++ "`.");
    }

    shared.requireDecl(F, "concurrency");
    if (@TypeOf(F.concurrency) != contracts.Concurrency) {
        @compileError("`concurrency` on `" ++ @typeName(F) ++ "` must be `contracts.Concurrency`.");
    }
    if (F.concurrency != .spmc_registered_fanout and F.concurrency != .mpmc_registered_fanout) {
        @compileError("`RegisteredFanoutRing` concept requires fanout concurrency metadata.");
    }

    shared.requireDecl(F, "is_lock_free");
    if (@TypeOf(F.is_lock_free) != bool) {
        @compileError("`is_lock_free` on `" ++ @typeName(F) ++ "` must be bool.");
    }
    shared.requireBoolDecl(F, "supports_close", false);
    shared.requireBoolDecl(F, "supports_blocking_wait", false);

    shared.requireTypeDecl(F, "ConsumerId");
    shared.requireErrorSetType(F, "TrySendError");
    shared.requireErrorSetType(F, "TryRecvError");

    shared.requireMethod(F, "addConsumer");
    const add_info = @typeInfo(@TypeOf(F.addConsumer)).@"fn";
    if (add_info.params.len != 1 or add_info.params[0].type.? != *F or add_info.return_type.? != error{NoSpaceLeft}!F.ConsumerId) {
        @compileError("`addConsumer(self: *Self) error{NoSpaceLeft}!ConsumerId` required on `" ++ @typeName(F) ++ "`.");
    }

    shared.requireMethod(F, "removeConsumer");
    const remove_info = @typeInfo(@TypeOf(F.removeConsumer)).@"fn";
    if (remove_info.params.len != 2 or remove_info.params[0].type.? != *F or remove_info.params[1].type.? != F.ConsumerId or remove_info.return_type.? != void) {
        @compileError("`removeConsumer(self: *Self, consumer_id: ConsumerId) void` required on `" ++ @typeName(F) ++ "`.");
    }

    shared.requireMethod(F, "trySend");
    const send_info = @typeInfo(@TypeOf(F.trySend)).@"fn";
    if (send_info.params.len != 2 or send_info.params[0].type.? != *F or send_info.params[1].type.? != T or send_info.return_type.? != F.TrySendError!void) {
        @compileError("`trySend(self: *Self, value: T) TrySendError!void` required on `" ++ @typeName(F) ++ "`.");
    }

    shared.requireMethod(F, "tryRecv");
    const recv_info = @typeInfo(@TypeOf(F.tryRecv)).@"fn";
    if (recv_info.params.len != 2 or recv_info.params[0].type.? != *F or recv_info.params[1].type.? != F.ConsumerId or recv_info.return_type.? != F.TryRecvError!T) {
        @compileError("`tryRecv(self: *Self, consumer_id: ConsumerId) TryRecvError!T` required on `" ++ @typeName(F) ++ "`.");
    }

    shared.requireMethod(F, "pending");
    const pending_info = @typeInfo(@TypeOf(F.pending)).@"fn";
    if (pending_info.params.len != 2 or pending_info.params[0].type.? != *F or pending_info.params[1].type.? != F.ConsumerId or pending_info.return_type.? != usize) {
        @compileError("`pending(self: *Self, consumer_id: ConsumerId) usize` required on `" ++ @typeName(F) ++ "`.");
    }
}
