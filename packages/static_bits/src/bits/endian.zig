//! Endian-aware integer loads and stores over byte slices.
//!
//! Key types: `Endian`, `ReadError`, `WriteError`.
//! Usage pattern: call `readInt(bytes, offset, T, endian)` or `writeInt(bytes, offset, value, endian)`
//! for runtime-offset access; use `readIntAt`/`writeIntAt` for compile-time-validated fixed layouts.
//! Thread safety: thread-safe for read-only access and for disjoint mutable buffers.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");

/// Byte order used by the load/store helpers.
pub const Endian = std.builtin.Endian;

/// Errors returned by `readInt` and `loadInt`.
pub const ReadError = error{
    /// The requested read extends past the end of the input slice.
    EndOfStream,
    /// The requested operation overflowed an internal `usize` calculation.
    Overflow,
};

/// Errors returned by `writeInt`.
pub const WriteError = error{
    /// The requested write extends past the end of the output slice.
    NoSpaceLeft,
    /// The requested operation overflowed an internal `usize` calculation.
    Overflow,
};

comptime {
    core.errors.assertVocabularySubset(ReadError);
    core.errors.assertVocabularySubset(WriteError);
}

fn assertIntType(comptime T: type, comptime fn_name: []const u8) void {
    if (@typeInfo(T) != .int) {
        @compileError(fn_name ++ " expects an integer type");
    }

    if (@typeInfo(T).int.bits == 0) {
        @compileError(fn_name ++ " requires a non-zero-width integer");
    }
}

fn assertArrayOffsetFits(
    comptime fn_name: []const u8,
    comptime element_count: usize,
    comptime offset: usize,
    comptime value_size: usize,
) void {
    const end = std.math.add(usize, offset, value_size) catch {
        @compileError(fn_name ++ " offset arithmetic overflowed");
    };
    if (end > element_count) {
        const message = std.fmt.comptimePrint(
            "{s} requires offset {d} + size {d} <= array len {d}",
            .{ fn_name, offset, value_size, element_count },
        );
        @compileError(message);
    }
}

fn assertByteArrayPointer(
    comptime Ptr: type,
    comptime fn_name: []const u8,
    comptime require_mutable: bool,
) void {
    const ptr_info = @typeInfo(Ptr);
    if (ptr_info != .pointer) {
        @compileError(fn_name ++ " expects a pointer to a fixed-size [N]u8 array");
    }

    if (ptr_info.pointer.size != .one) {
        @compileError(fn_name ++ " expects a single-item pointer (e.g. *const [N]u8)");
    }

    if (require_mutable and ptr_info.pointer.is_const) {
        @compileError(fn_name ++ " requires a mutable pointer (e.g. *[N]u8)");
    }

    const child_info = @typeInfo(ptr_info.pointer.child);
    if (child_info != .array or child_info.array.child != u8) {
        @compileError(fn_name ++ " expects a pointer to a fixed-size [N]u8 array");
    }
}

fn byteArrayLenFromPointer(comptime Ptr: type) usize {
    const ptr_info = @typeInfo(Ptr).pointer;
    return @typeInfo(ptr_info.child).array.len;
}

/// Reads `T` from `bytes[offset .. offset + @sizeOf(T)]` using `endian`.
///
/// Returns `error.EndOfStream` when the byte range exceeds the slice and
/// `error.Overflow` when `offset + @sizeOf(T)` overflows `usize`.
pub fn readInt(
    bytes: []const u8,
    offset: usize,
    comptime T: type,
    comptime endian: Endian,
) ReadError!T {
    comptime assertIntType(T, "readInt");

    const size = @sizeOf(T);
    const end = std.math.add(usize, offset, size) catch return error.Overflow;
    if (end > bytes.len) return error.EndOfStream;

    assert(end >= offset);
    const window = bytes[offset..end];
    assert(window.len == size);

    const ptr: *const [@sizeOf(T)]u8 = @ptrCast(window.ptr);
    return std.mem.readInt(T, ptr, endian);
}

/// Writes `value` to `bytes[offset .. offset + @sizeOf(@TypeOf(value))]` using `endian`.
///
/// Returns `error.NoSpaceLeft` when the byte range exceeds the slice and
/// `error.Overflow` when `offset + @sizeOf(value)` overflows `usize`.
pub fn writeInt(
    bytes: []u8,
    offset: usize,
    value: anytype,
    comptime endian: Endian,
) WriteError!void {
    const T = @TypeOf(value);
    comptime assertIntType(T, "writeInt");

    const size = @sizeOf(T);
    const end = std.math.add(usize, offset, size) catch return error.Overflow;
    if (end > bytes.len) return error.NoSpaceLeft;

    assert(end >= offset);
    const window = bytes[offset..end];
    assert(window.len == size);

    const ptr: *[@sizeOf(T)]u8 = @ptrCast(window.ptr);
    std.mem.writeInt(T, ptr, value, endian);
}

/// Loads an integer from the beginning of `bytes` using the given byte order.
pub fn loadInt(comptime T: type, bytes: []const u8, comptime endian: Endian) ReadError!T {
    return readInt(bytes, 0, T, endian);
}

/// Stores an integer at the beginning of `bytes` using the given byte order.
pub fn storeInt(bytes: []u8, value: anytype, comptime endian: Endian) WriteError!void {
    return writeInt(bytes, 0, value, endian);
}

/// Reads `T` from a fixed-size byte array at compile-time-validated `offset`.
///
/// This variant is intended for fixed binary layouts where both the array size
/// and field offset are known at compile time.
pub fn readIntAt(
    comptime T: type,
    bytes: anytype,
    comptime offset: usize,
    comptime endian: Endian,
) T {
    comptime assertIntType(T, "readIntAt");
    const BytesPtr = @TypeOf(bytes);
    comptime assertByteArrayPointer(BytesPtr, "readIntAt", false);
    const array_len = comptime byteArrayLenFromPointer(BytesPtr);
    comptime assertArrayOffsetFits("readIntAt", array_len, offset, @sizeOf(T));

    const window = bytes[offset .. offset + @sizeOf(T)];
    const ptr: *const [@sizeOf(T)]u8 = @ptrCast(window.ptr);
    return std.mem.readInt(T, ptr, endian);
}

/// Writes `value` into a fixed-size byte array at compile-time-validated `offset`.
///
/// This variant is intended for fixed binary layouts where both the array size
/// and field offset are known at compile time.
pub fn writeIntAt(
    bytes: anytype,
    comptime offset: usize,
    value: anytype,
    comptime endian: Endian,
) void {
    const T = @TypeOf(value);
    comptime assertIntType(T, "writeIntAt");
    const BytesPtr = @TypeOf(bytes);
    comptime assertByteArrayPointer(BytesPtr, "writeIntAt", true);
    const array_len = comptime byteArrayLenFromPointer(BytesPtr);
    comptime assertArrayOffsetFits("writeIntAt", array_len, offset, @sizeOf(T));

    const window = bytes[offset .. offset + @sizeOf(T)];
    const ptr: *[@sizeOf(T)]u8 = @ptrCast(window.ptr);
    std.mem.writeInt(T, ptr, value, endian);
}

test "read/write endian helpers are bounded and deterministic" {
    var buf = [_]u8{ 0x44, 0x33, 0x22, 0x11 };
    try testing.expectEqual(@as(u32, 0x11223344), try readInt(&buf, 0, u32, .little));
    try testing.expectEqual(@as(u32, 0x44332211), try readInt(&buf, 0, u32, .big));

    try writeInt(&buf, 0, @as(u16, 0xABCD), .big);
    try testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD, 0x22, 0x11 }, &buf);
    try testing.expectError(error.EndOfStream, readInt(&buf, 3, u16, .little));
    try testing.expectError(error.NoSpaceLeft, writeInt(buf[0..1], 0, @as(u16, 1), .little));
}

test "loadInt is equivalent to readInt at offset 0" {
    const buf = [_]u8{ 0x01, 0x00, 0x00, 0x00 };
    const via_load = try loadInt(u32, &buf, .little);
    const via_read = try readInt(&buf, 0, u32, .little);
    try testing.expectEqual(via_read, via_load);
    try testing.expectEqual(@as(u32, 1), via_load);
}

test "readInt at interior offset" {
    const buf = [_]u8{ 0xFF, 0x01, 0x02 };
    const v = try readInt(&buf, 1, u16, .little);
    try testing.expectEqual(@as(u16, 0x0201), v);
}

test "read/write endian helpers report arithmetic overflow" {
    const empty_in = [_]u8{};
    var empty_out = [_]u8{};

    try testing.expectError(
        error.Overflow,
        readInt(&empty_in, std.math.maxInt(usize), u16, .little),
    );
    try testing.expectError(
        error.Overflow,
        writeInt(&empty_out, std.math.maxInt(usize), @as(u16, 0xAA55), .little),
    );
}

test "loadInt forwards readInt errors" {
    const short = [_]u8{0x01};
    try testing.expectError(error.EndOfStream, loadInt(u16, &short, .little));
}

test "storeInt is equivalent to writeInt at offset 0" {
    var buf = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try storeInt(&buf, @as(u32, 0x11223344), .little);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11 }, &buf);
    try storeInt(&buf, @as(u16, 0xABCD), .big);
    try testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD, 0x22, 0x11 }, &buf);
    try testing.expectError(error.NoSpaceLeft, storeInt(buf[0..1], @as(u32, 1), .little));
}

test "read/write endian helpers handle signed integers" {
    var buf = [_]u8{ 0xFE, 0xFF };
    try testing.expectEqual(@as(i16, -2), try readInt(&buf, 0, i16, .little));
    try testing.expectEqual(@as(i16, -2), try loadInt(i16, &buf, .little));

    try writeInt(&buf, 0, @as(i16, -128), .big);
    try testing.expectEqual(@as(i16, -128), try readInt(&buf, 0, i16, .big));

    try storeInt(&buf, @as(i16, 0x0102), .little);
    try testing.expectEqual(@as(i16, 0x0102), try loadInt(i16, &buf, .little));

    var fixed = [_]u8{ 0xFF, 0x80 };
    try testing.expectEqual(@as(i16, -128), readIntAt(i16, &fixed, 0, .big));
    writeIntAt(&fixed, 0, @as(i16, 0x0102), .little);
    try testing.expectEqual(@as(i16, 0x0102), readIntAt(i16, &fixed, 0, .little));
}

test "fixed-array endian helpers enforce compile-time offsets" {
    var bytes = [_]u8{ 0x34, 0x12, 0x78, 0x56 };
    try testing.expectEqual(@as(u16, 0x1234), readIntAt(u16, &bytes, 0, .little));
    try testing.expectEqual(@as(u16, 0x7856), readIntAt(u16, &bytes, 2, .big));

    writeIntAt(&bytes, 0, @as(u16, 0xA1B2), .big);
    try testing.expectEqualSlices(u8, &.{ 0xA1, 0xB2, 0x78, 0x56 }, &bytes);
    writeIntAt(&bytes, 0, @as(u32, 0x11223344), .little);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11 }, &bytes);
}
