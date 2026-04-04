const contracts = @import("../contracts.zig");
const shared = @import("shared.zig");

pub fn requireWorkStealingDeque(comptime D: type, comptime T: type) void {
    shared.requireDecl(D, "Element");
    if (D.Element != T) {
        @compileError("`Element` mismatch for `" ++ @typeName(D) ++ "`.");
    }

    shared.requireDecl(D, "concurrency");
    if (@TypeOf(D.concurrency) != contracts.Concurrency) {
        @compileError("`concurrency` on `" ++ @typeName(D) ++ "` must be `contracts.Concurrency`.");
    }
    if (D.concurrency != .work_stealing) {
        @compileError("`WorkStealingDeque` concept requires `.work_stealing` concurrency.");
    }

    shared.requireDecl(D, "is_lock_free");
    if (@TypeOf(D.is_lock_free) != bool) {
        @compileError("`is_lock_free` on `" ++ @typeName(D) ++ "` must be bool.");
    }

    shared.requireBoolDecl(D, "supports_close", false);
    shared.requireBoolDecl(D, "supports_blocking_wait", false);

    shared.requireDecl(D, "len_semantics");
    if (@TypeOf(D.len_semantics) != contracts.LenSemantics) {
        @compileError("`len_semantics` on `" ++ @typeName(D) ++ "` must be `contracts.LenSemantics`.");
    }

    shared.requireErrorSetType(D, "PushError");
    shared.requireErrorSetType(D, "PopError");
    shared.requireErrorSetType(D, "StealError");

    shared.requireMethod(D, "pushBottom");
    const push_info = @typeInfo(@TypeOf(D.pushBottom)).@"fn";
    if (push_info.params.len != 2 or push_info.params[0].type.? != *D or push_info.params[1].type.? != T or push_info.return_type.? != D.PushError!void) {
        @compileError("`pushBottom(self: *Self, value: T) PushError!void` required on `" ++ @typeName(D) ++ "`.");
    }

    shared.requireMethod(D, "popBottom");
    const pop_info = @typeInfo(@TypeOf(D.popBottom)).@"fn";
    if (pop_info.params.len != 1 or pop_info.params[0].type.? != *D or pop_info.return_type.? != D.PopError!T) {
        @compileError("`popBottom(self: *Self) PopError!T` required on `" ++ @typeName(D) ++ "`.");
    }

    shared.requireMethod(D, "stealTop");
    const steal_info = @typeInfo(@TypeOf(D.stealTop)).@"fn";
    if (steal_info.params.len != 1 or steal_info.params[0].type.? != *D or steal_info.return_type.? != D.StealError!T) {
        @compileError("`stealTop(self: *Self) StealError!T` required on `" ++ @typeName(D) ++ "`.");
    }
}
