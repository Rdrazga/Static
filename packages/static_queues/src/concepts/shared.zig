const std = @import("std");

pub fn requireDecl(comptime Q: type, comptime decl_name: []const u8) void {
    if (!@hasDecl(Q, decl_name)) {
        @compileError("Type `" ++ @typeName(Q) ++ "` is missing required decl `" ++ decl_name ++ "`.");
    }
}

pub fn requireMethod(comptime Q: type, comptime method_name: []const u8) void {
    if (!std.meta.hasFn(Q, method_name)) {
        @compileError("Type `" ++ @typeName(Q) ++ "` is missing required method `" ++ method_name ++ "`.");
    }
}

pub fn requireTypeDecl(comptime Q: type, comptime decl_name: []const u8) void {
    requireDecl(Q, decl_name);
    if (@TypeOf(@field(Q, decl_name)) != type) {
        @compileError("Decl `" ++ decl_name ++ "` on `" ++ @typeName(Q) ++ "` must be a type.");
    }
}

pub fn requireBoolDecl(comptime Q: type, comptime decl_name: []const u8, comptime expected: bool) void {
    requireDecl(Q, decl_name);
    if (@TypeOf(@field(Q, decl_name)) != bool) {
        @compileError("Decl `" ++ decl_name ++ "` on `" ++ @typeName(Q) ++ "` must be bool.");
    }
    if (@field(Q, decl_name) != expected) {
        @compileError("Decl `" ++ decl_name ++ "` on `" ++ @typeName(Q) ++ "` has unexpected value.");
    }
}

pub fn requireErrorSetType(comptime Q: type, comptime decl_name: []const u8) void {
    requireTypeDecl(Q, decl_name);
    if (@typeInfo(@field(Q, decl_name)) != .error_set) {
        @compileError("Decl `" ++ decl_name ++ "` on `" ++ @typeName(Q) ++ "` must be an error set type.");
    }
}
