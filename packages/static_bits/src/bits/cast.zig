//! Checked integer casts with deterministic failure classification.
//!
//! Key types: `Error`.
//! Usage pattern: call `castInt(Dst, value)` instead of `@intCast` at any site
//! where the source value might exceed the destination range; errors are
//! classified as `Overflow` (too large) or `Underflow` (too negative).
//! Thread safety: thread-safe. All functions are pure and stateless.

const std = @import("std");
const core = @import("static_core");

/// Errors returned by `castInt`.
pub const Error = error{
    /// The value exceeds the destination type's maximum representable value.
    Overflow,
    /// The value is below the destination type's minimum representable value.
    Underflow,
};

comptime {
    core.errors.assertVocabularySubset(Error);
}

fn assertIntTypes(comptime Dst: type, comptime Src: type) void {
    if (@typeInfo(Dst) != .int or @typeInfo(Src) != .int) {
        @compileError("castInt expects integer source and destination types");
    }
    if (@typeInfo(Dst).int.bits == 0 or @typeInfo(Src).int.bits == 0) {
        @compileError("castInt requires non-zero-width integer types");
    }
}

fn classifyCastFailure(comptime Dst: type, value: anytype) Error {
    const Src = @TypeOf(value);
    const src_info = @typeInfo(Src).int;
    const dst_info = @typeInfo(Dst).int;

    if (src_info.signedness == .signed and value < 0) {
        if (dst_info.signedness == .unsigned) {
            return error.Underflow;
        }

        if (value < std.math.minInt(Dst)) {
            return error.Underflow;
        }
    }

    return error.Overflow;
}

/// Casts an integer value into `Dst` and classifies failures as `Overflow` or `Underflow`.
pub fn castInt(comptime Dst: type, value: anytype) Error!Dst {
    const Src = @TypeOf(value);
    comptime assertIntTypes(Dst, Src);

    const src_info = @typeInfo(Src).int;
    const dst_info = @typeInfo(Dst).int;

    if (std.math.cast(Dst, value)) |casted| {
        if (src_info.signedness == .signed and dst_info.signedness == .unsigned) {
            std.debug.assert(value >= 0);
        }
        return casted;
    }

    return classifyCastFailure(Dst, value);
}

test "castInt maps underflow and overflow deterministically" {
    try std.testing.expectEqual(@as(u8, 7), try castInt(u8, @as(u16, 7)));
    try std.testing.expectEqual(@as(i8, -1), try castInt(i8, @as(i16, -1)));
    try std.testing.expectError(error.Underflow, castInt(u8, @as(i16, -1)));
    try std.testing.expectError(error.Overflow, castInt(u8, @as(u16, 300)));
    try std.testing.expectError(error.Overflow, castInt(i8, @as(u8, 200)));
    try std.testing.expectError(error.Overflow, castInt(i16, @as(u16, 0x8000)));
    try std.testing.expectEqual(@as(i16, 0x7FFF), try castInt(i16, @as(u16, 0x7FFF)));
    try std.testing.expectError(error.Underflow, castInt(i8, @as(i16, -129)));
    try std.testing.expectError(error.Overflow, castInt(i8, @as(i16, 128)));
}

test "castInt accepts destination bounds exactly" {
    try std.testing.expectEqual(
        @as(u8, std.math.maxInt(u8)),
        try castInt(u8, @as(u8, std.math.maxInt(u8))),
    );
    try std.testing.expectEqual(
        @as(i16, std.math.minInt(i16)),
        try castInt(i16, @as(i16, std.math.minInt(i16))),
    );
    try std.testing.expectEqual(
        @as(i16, std.math.maxInt(i16)),
        try castInt(i16, @as(i16, std.math.maxInt(i16))),
    );
}
