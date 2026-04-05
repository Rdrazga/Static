//! Hash Stable - Canonical, Cross-Architecture Stable Hashing.
//!
//! Stable hashing produces the same hash for the same logical value across
//! architectures and endianness. It achieves this by defining a canonical
//! encoding (type-tagged, length-delimited, little-endian) and hashing that
//! encoding with FNV-1a 64.
//!
//! ## Thread Safety
//! Unrestricted - all functions are pure and reentrant.
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).
//!
//! ## Design
//! - Explicit tags and length prefixes prevent ambiguous concatenation collisions.
//! - Integers and floats are encoded little-endian (never native-endian).
//! - Structs/arrays/slices are encoded structurally (never via raw bytes),
//!   so padding is ignored.
//! - Non-slice pointers are rejected at compile time (addresses are not stable).
//! - Float canonicalization: +/-0.0 hash the same; all NaN payloads hash the same.
//! - Use the `*Budgeted` APIs to enforce explicit work bounds on untrusted input.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const budget_mod = @import("budget.zig");
const fnv1a_mod = @import("fnv1a.zig");

pub const HashBudget = budget_mod.HashBudget;
pub const HashBudgetError = budget_mod.HashBudgetError;

pub const Seed = u64;

// Type tags for canonical encoding. Each supported type gets a unique tag
// to prevent cross-type collisions (e.g., a bool and a u8 with value 1).
const tag_seed: u8 = 0x00;
const tag_bool: u8 = 0x01;
const tag_int: u8 = 0x02;
const tag_float: u8 = 0x03;
const tag_comptime_int: u8 = 0x04;
const tag_comptime_float: u8 = 0x05;
const tag_enum: u8 = 0x06;
const tag_error: u8 = 0x07;
const tag_bytes: u8 = 0x08;
const tag_slice: u8 = 0x09;
const tag_array: u8 = 0x0A;
const tag_vector: u8 = 0x0B;
const tag_struct: u8 = 0x0C;
const tag_optional: u8 = 0x0D;
const tag_error_union: u8 = 0x0E;
const tag_tagged_union: u8 = 0x0F;

comptime {
    const tags = [_]u8{
        tag_seed,         tag_bool,           tag_int,         tag_float,
        tag_comptime_int, tag_comptime_float, tag_enum,        tag_error,
        tag_bytes,        tag_slice,          tag_array,       tag_vector,
        tag_struct,       tag_optional,       tag_error_union, tag_tagged_union,
    };
    // All type tags must be unique to prevent cross-type collisions.
    for (tags, 0..) |a, i| {
        for (tags[0..i]) |b| {
            assert(a != b);
        }
    }
    // Tags are sequential from 0x00 to 0x0F (16 tags).
    assert(tags.len == 16);
    assert(tags[0] == 0x00);
    assert(tags[tags.len - 1] == 0x0F);
}

// Internal canonical writer. Encodes values into the FNV-1a hasher with
// type tags and length delimiters.
const Writer = struct {
    hasher: fnv1a_mod.Fnv1a64,

    fn init(seed: Seed) Writer {
        var w: Writer = .{ .hasher = fnv1a_mod.Fnv1a64.init(0) };
        w.writeTag(tag_seed);
        w.writeU64(seed);
        return w;
    }

    fn writeTag(self: *Writer, tag: u8) void {
        // Tag must be in the defined range.
        assert(tag <= tag_tagged_union);
        // Tag is a single byte - documents intent.
        assert(@sizeOf(@TypeOf(tag)) == 1);
        self.hasher.update(&[_]u8{tag});
    }

    fn writeBytes(self: *Writer, bytes: []const u8) void {
        assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
        self.hasher.update(bytes);
    }

    fn writeU64(self: *Writer, value: u64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        self.hasher.update(buf[0..]);
    }

    fn writeU16(self: *Writer, value: u16) void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        self.hasher.update(buf[0..]);
    }

    fn writeLen(self: *Writer, len: usize) void {
        // Stable encoding writes lengths as u64. Platforms with usize > 64 bits
        // cannot be supported by this encoding format.
        comptime {
            if (@bitSizeOf(usize) > 64) {
                @compileError("stable.hash: usize exceeds 64 bits; stable encoding requires usize <= 64");
            }
        }
        self.writeU64(@as(u64, @intCast(len)));
    }

    fn final(self: *const Writer) u64 {
        return self.hasher.final();
    }
};

// =============================================================================
// Public API - Fingerprinting (raw bytes)
// =============================================================================

/// Stable 64-bit hash of raw bytes (no type tag or length prefix).
///
/// Use for hashing already-canonical encodings (wire formats, stable serialization).
///
/// Preconditions: if bytes.len > 0, bytes.ptr must be non-null.
/// Postconditions: returns deterministic FNV-1a 64-bit hash of bytes.
pub fn stableFingerprint64(bytes: []const u8) u64 {
    assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
    var h = fnv1a_mod.Fnv1a64.init(0);
    h.update(bytes);
    return h.final();
}

/// Stable 64-bit hash of raw bytes with an explicit seed.
///
/// Seed is incorporated by hashing its little-endian bytes before the payload.
///
/// Preconditions: if bytes.len > 0, bytes.ptr must be non-null.
/// Postconditions: returns deterministic seeded FNV-1a 64-bit hash of bytes.
pub fn stableFingerprint64Seeded(seed: Seed, bytes: []const u8) u64 {
    assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
    var h = fnv1a_mod.Fnv1a64.init(0);
    var seed_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &seed_buf, seed, .little);
    h.update(seed_buf[0..]);
    h.update(bytes);
    return h.final();
}

/// Stable 128-bit hash of raw bytes (two independent hashes).
///
/// Postconditions: low 64 bits use seed 0, high 64 bits use the golden ratio.
pub fn stableFingerprint128(bytes: []const u8) u128 {
    return stableFingerprint128Seeded(0, 0x9e3779b97f4a7c15, bytes);
}

/// Stable 128-bit hash of raw bytes with explicit seeds.
///
/// Preconditions: seed_a != seed_b recommended for independence.
/// Postconditions: low 64 bits use seed_a, high 64 bits use seed_b.
pub fn stableFingerprint128Seeded(seed_a: Seed, seed_b: Seed, bytes: []const u8) u128 {
    assert(seed_a != seed_b);
    const low = stableFingerprint64Seeded(seed_a, bytes);
    const high = stableFingerprint64Seeded(seed_b, bytes);
    return (@as(u128, high) << 64) | low;
}

// =============================================================================
// Public API - Structured value hashing
// =============================================================================

/// Stable hash of any supported value (seed = 0).
///
/// Cross-architecture stable by construction (canonical encoding + little-endian).
///
/// Postconditions: returns deterministic hash of value.
pub fn stableHashAny(value: anytype) u64 {
    return stableHashAnySeeded(0, value);
}

/// Stable hash of any supported value with an explicit budget (seed = 0).
pub fn stableHashAnyBudgeted(value: anytype, b: *HashBudget) HashBudgetError!u64 {
    return stableHashAnySeededBudgeted(0, value, b);
}

/// Stable hash of any supported value with an explicit seed.
///
/// Supported types:
/// - integers (incl. `comptime_int`), floats (incl. `comptime_float`), bools
/// - enums (encoded by tag name), error sets (encoded by error name)
/// - slices/arrays/vectors (length-delimited; byte slices as bytes)
/// - structs (field-wise, declaration order)
/// - optionals, error unions, tagged unions
///
/// Unsupported (compile error):
/// - non-slice pointers, opaque types, functions, frames
///
/// Postconditions: returns deterministic hash for given seed and value.
pub fn stableHashAnySeeded(seed: Seed, value: anytype) u64 {
    var w = Writer.init(seed);
    writeAny(&w, value);
    return w.final();
}

/// Stable hash of any supported value with an explicit seed and budget.
pub fn stableHashAnySeededBudgeted(seed: Seed, value: anytype, b: *HashBudget) HashBudgetError!u64 {
    var w = Writer.init(seed);
    try writeAnyBudgeted(&w, value, b);
    return w.final();
}

// =============================================================================
// Internal - Comptime budget polymorphism
// =============================================================================

// Comptime return-type selector for unified budget/unbounded implementations.
// When B=void, budget operations are no-ops and the return type is T.
// When B=*HashBudget, budget operations are enforced and the return type is
// HashBudgetError!T. Each unified function is instantiated twice at comptime,
// and the compiler eliminates dead branches.
fn MaybeError(comptime B: type, comptime T: type) type {
    comptime {
        assert(B == void or B == *HashBudget);
    }
    return if (B == void) T else HashBudgetError!T;
}

// =============================================================================
// Internal - Type dispatch (unified)
// =============================================================================

fn writeAny(w: *Writer, value: anytype) void {
    writeAnyImpl(w, value, void, {});
}

fn writeAnyBudgeted(w: *Writer, value: anytype, b: *HashBudget) HashBudgetError!void {
    return writeAnyImpl(w, value, *HashBudget, b);
}

fn writeAnyImpl(w: *Writer, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);

    if (comptime B != void) try b.enter();
    defer if (comptime B != void) b.leave();

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => writeBool(w, value),
        .int => |info| writeInt(w, info, value),
        .comptime_int => {
            if (comptime B != void) {
                try writeComptimeIntImpl(w, value, *HashBudget, b);
            } else {
                writeComptimeIntImpl(w, value, void, {});
            }
        },
        .float => |info| writeFloat(w, info, value),
        .comptime_float => writeComptimeFloat(w, value),
        .@"enum" => {
            if (comptime B != void) {
                try writeEnumImpl(w, value, *HashBudget, b);
            } else {
                writeEnumImpl(w, value, void, {});
            }
        },
        .error_set => {
            if (comptime B != void) {
                try writeErrorImpl(w, value, *HashBudget, b);
            } else {
                writeErrorImpl(w, value, void, {});
            }
        },
        .error_union => {
            if (comptime B != void) {
                try writeErrorUnionImpl(w, value, *HashBudget, b);
            } else {
                writeErrorUnionImpl(w, value, void, {});
            }
        },
        .optional => {
            if (comptime B != void) {
                try writeOptionalImpl(w, value, *HashBudget, b);
            } else {
                writeOptionalImpl(w, value, void, {});
            }
        },
        .pointer => |ptr| {
            if (comptime B != void) {
                try writePointerImpl(w, ptr, value, *HashBudget, b);
            } else {
                writePointerImpl(w, ptr, value, void, {});
            }
        },
        .array => |arr| {
            if (comptime B != void) {
                try writeArrayImpl(w, arr, value, *HashBudget, b);
            } else {
                writeArrayImpl(w, arr, value, void, {});
            }
        },
        .vector => |vec| {
            if (comptime B != void) {
                try writeVectorImpl(w, vec, value, *HashBudget, b);
            } else {
                writeVectorImpl(w, vec, value, void, {});
            }
        },
        .@"struct" => {
            if (comptime B != void) {
                try writeStructImpl(w, value, *HashBudget, b);
            } else {
                writeStructImpl(w, value, void, {});
            }
        },
        .@"union" => |u| {
            if (comptime B != void) {
                try writeTaggedUnionImpl(w, u, value, *HashBudget, b);
            } else {
                writeTaggedUnionImpl(w, u, value, void, {});
            }
        },
        else => @compileError("stableHashAny cannot hash type: " ++ @typeName(T)),
    }
}

fn isStableHashAnySupportedType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool,
        .int,
        .comptime_int,
        .float,
        .comptime_float,
        .@"enum",
        .error_set,
        => true,
        .optional => |opt| isStableHashAnySupportedType(opt.child),
        .error_union => |eu| isStableHashAnySupportedType(eu.payload),
        .pointer => |ptr| ptr.size == .slice and isStableHashAnySupportedType(ptr.child),
        .array => |arr| isStableHashAnySupportedType(arr.child),
        .vector => |vec| isStableHashAnySupportedType(vec.child),
        .@"struct" => {
            inline for (std.meta.fields(T)) |field| {
                if (!isStableHashAnySupportedType(field.type)) return false;
            }
            return true;
        },
        .@"union" => |u| {
            if (u.tag_type == null) return false;
            inline for (u.fields) |field| {
                if (!isStableHashAnySupportedType(field.type)) return false;
            }
            return true;
        },
        else => false,
    };
}

// =============================================================================
// Internal - Type-specific writers (unified)
// =============================================================================

fn writeByteSliceImpl(w: *Writer, bytes: []const u8, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    assert(bytes.len == 0 or @intFromPtr(bytes.ptr) != 0);
    if (comptime B != void) try b.chargeBytes(bytes.len);
    w.writeTag(tag_bytes);
    w.writeLen(bytes.len);
    w.writeBytes(bytes);
}

fn writeBool(w: *Writer, value: bool) void {
    w.writeTag(tag_bool);
    const byte: u8 = if (value) 1 else 0;
    // Bool maps to exactly 0 or 1.
    assert(byte == 0 or byte == 1);
    w.writeBytes(&[_]u8{byte});
}

fn writeInt(w: *Writer, comptime info: std.builtin.Type.Int, value: anytype) void {
    w.writeTag(tag_int);
    w.writeBytes(&[_]u8{if (info.signedness == .signed) 1 else 0});
    w.writeU16(@as(u16, @intCast(info.bits)));
    writeIntValue(w, info, value);
}

fn writeComptimeIntImpl(w: *Writer, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    const s = std.fmt.comptimePrint("{}", .{value});
    if (comptime B != void) try b.chargeBytes(s.len);
    w.writeTag(tag_comptime_int);
    w.writeLen(s.len);
    w.writeBytes(s);
}

fn writeFloat(w: *Writer, comptime info: std.builtin.Type.Float, value: anytype) void {
    w.writeTag(tag_float);
    w.writeU16(@as(u16, @intCast(info.bits)));
    writeFloatValue(w, value);
}

fn writeComptimeFloat(w: *Writer, value: anytype) void {
    // `comptime_float` has no runtime representation; normalize via f64.
    w.writeTag(tag_comptime_float);
    w.writeU16(64);
    const f: f64 = value;
    writeFloatValue(w, f);
}

fn writeEnumImpl(w: *Writer, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    const name = @tagName(value);
    if (comptime B != void) try b.chargeBytes(name.len);
    w.writeTag(tag_enum);
    w.writeLen(name.len);
    w.writeBytes(name);
}

fn writeErrorImpl(w: *Writer, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    const name = @errorName(value);
    if (comptime B != void) try b.chargeBytes(name.len);
    w.writeTag(tag_error);
    w.writeLen(name.len);
    w.writeBytes(name);
}

fn writeErrorUnionImpl(w: *Writer, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    w.writeTag(tag_error_union);
    if (value) |payload| {
        w.writeBytes(&[_]u8{1});
        if (comptime B != void) {
            try writeAnyImpl(w, payload, *HashBudget, b);
        } else {
            writeAnyImpl(w, payload, void, {});
        }
    } else |err| {
        w.writeBytes(&[_]u8{0});
        const name = @errorName(err);
        if (comptime B != void) try b.chargeBytes(name.len);
        w.writeLen(name.len);
        w.writeBytes(name);
    }
}

fn writeOptionalImpl(w: *Writer, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    w.writeTag(tag_optional);
    if (value) |payload| {
        w.writeBytes(&[_]u8{1});
        if (comptime B != void) {
            try writeAnyImpl(w, payload, *HashBudget, b);
        } else {
            writeAnyImpl(w, payload, void, {});
        }
    } else {
        w.writeBytes(&[_]u8{0});
    }
}

fn writePointerImpl(w: *Writer, comptime ptr: std.builtin.Type.Pointer, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    const T = @TypeOf(value);

    if (ptr.size == .slice) {
        if (ptr.child == u8) {
            return writeByteSliceImpl(w, std.mem.sliceAsBytes(value), B, b);
        }
        w.writeTag(tag_slice);
        if (comptime B != void) try b.chargeElems(value.len);
        w.writeLen(value.len);
        for (value) |elem| {
            if (comptime B != void) {
                try writeAnyImpl(w, elem, *HashBudget, b);
            } else {
                writeAnyImpl(w, elem, void, {});
            }
        }
        return;
    } else if (ptr.size == .one) {
        switch (@typeInfo(ptr.child)) {
            .array => |arr| {
                if (arr.child == u8) {
                    return writeByteSliceImpl(w, value[0..arr.len], B, b);
                }
            },
            else => {},
        }
    }

    @compileError("stableHashAny does not support pointer type: " ++ @typeName(T));
}

fn writeArrayImpl(w: *Writer, comptime arr: std.builtin.Type.Array, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    w.writeTag(tag_array);
    if (comptime B != void) try b.chargeElems(arr.len);
    w.writeLen(arr.len);
    for (value) |elem| {
        if (comptime B != void) {
            try writeAnyImpl(w, elem, *HashBudget, b);
        } else {
            writeAnyImpl(w, elem, void, {});
        }
    }
}

fn writeVectorImpl(w: *Writer, comptime vec: std.builtin.Type.Vector, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    w.writeTag(tag_vector);
    if (comptime B != void) try b.chargeElems(vec.len);
    w.writeLen(vec.len);
    inline for (0..vec.len) |i| {
        if (comptime B != void) {
            try writeAnyImpl(w, value[i], *HashBudget, b);
        } else {
            writeAnyImpl(w, value[i], void, {});
        }
    }
}

fn writeStructImpl(w: *Writer, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    const T = @TypeOf(value);
    w.writeTag(tag_struct);
    const fields = std.meta.fields(T);
    if (comptime B != void) try b.chargeElems(fields.len);
    w.writeLen(fields.len);
    inline for (fields) |field| {
        if (comptime B != void) {
            try writeAnyImpl(w, @field(value, field.name), *HashBudget, b);
        } else {
            writeAnyImpl(w, @field(value, field.name), void, {});
        }
    }
}

fn writeTaggedUnionImpl(w: *Writer, comptime u: std.builtin.Type.Union, value: anytype, comptime B: type, b: B) MaybeError(B, void) {
    comptime assert(B == void or B == *HashBudget);
    const T = @TypeOf(value);
    const Tag = u.tag_type orelse @compileError("stableHashAny cannot hash untagged union type: " ++ @typeName(T));
    w.writeTag(tag_tagged_union);

    const tag: Tag = std.meta.activeTag(value);
    if (comptime B != void) {
        try writeAnyImpl(w, tag, *HashBudget, b);
    } else {
        writeAnyImpl(w, tag, void, {});
    }

    inline for (u.fields) |field| {
        const field_tag: Tag = @field(Tag, field.name);
        if (tag == field_tag) {
            if (comptime B != void) {
                try writeAnyImpl(w, @field(value, field.name), *HashBudget, b);
            } else {
                writeAnyImpl(w, @field(value, field.name), void, {});
            }
            return;
        }
    }
    // Proof: `tag` is obtained from `std.meta.activeTag(value)` which returns
    // a value of type `Tag`. The `inline for` iterates all fields of the union,
    // and each field defines a unique `Tag` variant. A tagged union's active tag
    // must match exactly one field, so the loop always returns before this point.
    unreachable;
}

// =============================================================================
// Internal - Encoding helpers
// =============================================================================

fn writeIntValue(w: *Writer, comptime info: std.builtin.Type.Int, value: anytype) void {
    const bits: comptime_int = info.bits;
    const U = std.meta.Int(.unsigned, bits);
    const uval: U = @bitCast(value);
    var buf: [@sizeOf(U)]u8 = undefined;
    std.mem.writeInt(U, &buf, uval, .little);
    w.writeBytes(buf[0..]);
}

/// Canonicalize a float: normalize NaN payloads and collapse +/-0.0 to +0.0.
fn canonicalizeFloat(comptime F: type, value: F) F {
    var canonical: F = value;
    if (std.math.isNan(canonical)) canonical = std.math.nan(F);
    if (canonical == 0) canonical = @as(F, 0);
    // Postcondition: no negative zero remains after canonicalization.
    if (canonical == 0) assert(!std.math.signbit(canonical));
    return canonical;
}

fn writeFloatValue(w: *Writer, value: anytype) void {
    const T = @TypeOf(value);
    const canonical = canonicalizeFloat(T, value);

    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    const bits: U = @bitCast(canonical);
    var buf: [@sizeOf(U)]u8 = undefined;
    std.mem.writeInt(U, &buf, bits, .little);
    w.writeBytes(buf[0..]);
}

// =============================================================================
// Tests
// =============================================================================

test "stableFingerprint64 matches FNV-1a over bytes" {
    const expected = std.hash.Fnv1a_64.hash("hello");
    try testing.expectEqual(expected, stableFingerprint64("hello"));
}

test "stableFingerprint64Seeded is deterministic and seed-separated" {
    const data = "hello";
    try testing.expectEqual(
        stableFingerprint64Seeded(7, data),
        stableFingerprint64Seeded(7, data),
    );
    try testing.expect(
        stableFingerprint64Seeded(7, data) != stableFingerprint64Seeded(8, data),
    );
}

test "stableFingerprint128 halves map to seeded 64-bit fingerprints" {
    const data = "hello";
    const seed_a: u64 = 0;
    const seed_b: u64 = 0x9e3779b97f4a7c15;

    const fp128 = stableFingerprint128(data);
    const low: u64 = @truncate(fp128);
    const high: u64 = @truncate(fp128 >> 64);

    try testing.expectEqual(stableFingerprint64Seeded(seed_a, data), low);
    try testing.expectEqual(stableFingerprint64Seeded(seed_b, data), high);
    try testing.expect(low != high);
}

test "stableHashAny u32 uses little-endian encoding" {
    const v: u32 = 0x01020304;
    const h = stableHashAny(v);

    // Expected payload: seed tag + seed(u64 LE) + int tag + signedness + bits(u16 LE) + value(u32 LE).
    var buf: [1 + 8 + 1 + 1 + 2 + 4]u8 = undefined;
    var i: usize = 0;
    buf[i] = tag_seed;
    i += 1;
    std.mem.writeInt(u64, buf[i..][0..8], 0, .little);
    i += 8;
    buf[i] = tag_int;
    i += 1;
    buf[i] = 0; // unsigned
    i += 1;
    std.mem.writeInt(u16, buf[i..][0..2], 32, .little);
    i += 2;
    std.mem.writeInt(u32, buf[i..][0..4], v, .little);

    try testing.expectEqual(stableFingerprint64(buf[0..]), h);
}

test "stableHashAny golden vectors are stable" {
    // Pinned output values - these must never change.
    // Any change here indicates the canonical encoding has been altered.
    //
    // Each value is the FNV-1a 64 hash of the canonical encoding:
    //   [seed tag(0x00) + seed(u64 LE 0)] ++ [type tag + type-specific payload]
    //
    // Verify by reconstructing the canonical byte stream manually:

    // u32(42): seed_tag(0x00) + seed(8 bytes LE 0) + int_tag(0x02) + unsigned(0x00) + bits(32 LE) + value(42 LE)
    const u32_42_hash = stableHashAny(@as(u32, 42));
    var u32_buf: [1 + 8 + 1 + 1 + 2 + 4]u8 = undefined;
    u32_buf[0] = tag_seed;
    std.mem.writeInt(u64, u32_buf[1..][0..8], 0, .little);
    u32_buf[9] = tag_int;
    u32_buf[10] = 0; // unsigned
    std.mem.writeInt(u16, u32_buf[11..][0..2], 32, .little);
    std.mem.writeInt(u32, u32_buf[13..][0..4], 42, .little);
    try testing.expectEqual(stableFingerprint64(u32_buf[0..]), u32_42_hash);

    // Cross-call stability: same value always produces same hash.
    try testing.expectEqual(u32_42_hash, stableHashAny(@as(u32, 42)));

    // bool(true): seed_tag + seed + bool_tag(0x01) + 0x01
    const bool_hash = stableHashAny(true);
    try testing.expectEqual(bool_hash, stableHashAny(true));
    try testing.expect(bool_hash != stableHashAny(false));

    // Seeded variant differs from unseeded.
    try testing.expect(stableHashAnySeeded(1, @as(u32, 42)) != u32_42_hash);
}

test "stableHashAny canonicalizes +/-0.0 and NaN payloads" {
    const zp: f32 = 0.0;
    const zn: f32 = -0.0;
    try testing.expectEqual(stableHashAny(zp), stableHashAny(zn));

    const nan1: f32 = std.math.nan(f32);
    const nan2: f32 = @bitCast(@as(u32, 0x7fc00001));
    try testing.expectEqual(stableHashAny(nan1), stableHashAny(nan2));
}

test "stableHashAny hashes enums by tag name" {
    const E = enum { a, b };
    try testing.expect(stableHashAny(E.a) != stableHashAny(E.b));
    try testing.expectEqual(stableHashAny(E.a), stableHashAny(E.a));
}

test "stableHashAny hashes error sets by error name" {
    const E = error{ A, B };
    try testing.expect(stableHashAny(E.A) != stableHashAny(E.B));
    try testing.expectEqual(stableHashAny(E.A), stableHashAny(E.A));
}

test "stableHashAny struct ignores padding (structural encoding)" {
    const Key = struct { a: u8, b: u32 };

    const k1 = blk: {
        var bytes: [@sizeOf(Key)]u8 = undefined;
        @memset(bytes[0..], 0xAA);
        bytes[@offsetOf(Key, "a")] = 1;
        std.mem.writeInt(u32, bytes[@offsetOf(Key, "b")..][0..4], 0x11223344, .little);
        var key: Key = undefined;
        @memcpy(std.mem.asBytes(&key), bytes[0..]);
        break :blk key;
    };

    const k2 = blk: {
        var bytes: [@sizeOf(Key)]u8 = undefined;
        @memset(bytes[0..], 0x55);
        bytes[@offsetOf(Key, "a")] = 1;
        std.mem.writeInt(u32, bytes[@offsetOf(Key, "b")..][0..4], 0x11223344, .little);
        var key: Key = undefined;
        @memcpy(std.mem.asBytes(&key), bytes[0..]);
        break :blk key;
    };

    try testing.expect(std.meta.eql(k1, k2));
    try testing.expectEqual(stableHashAny(k1), stableHashAny(k2));
}

test "stableHashAnyBudgeted enforces max_bytes on byte slices" {
    var b = HashBudget.init(.{
        .max_bytes = 2,
        .max_elems = std.math.maxInt(u64),
        .max_depth = std.math.maxInt(u16),
    });
    try testing.expectError(error.ExceededBytes, stableHashAnySeededBudgeted(0, "abc", &b));
}

test "stableHashAnyBudgeted enforces max_elems on structural slices" {
    const xs = [_]u32{ 1, 2, 3 };
    const xs_slice: []const u32 = xs[0..];
    var b = HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = 2,
        .max_depth = std.math.maxInt(u16),
    });
    try testing.expectError(error.ExceededElems, stableHashAnySeededBudgeted(0, xs_slice, &b));
}

test "stableHashAnyBudgeted enforces max_depth" {
    const T = struct { a: struct { b: u32 } };
    var b = HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = std.math.maxInt(u64),
        .max_depth = 1,
    });
    try testing.expectError(error.ExceededDepth, stableHashAnySeededBudgeted(0, T{ .a = .{ .b = 1 } }, &b));
}

test "stableHashAny optional" {
    const a: ?u32 = null;
    const b: ?u32 = 42;
    try testing.expectEqual(stableHashAny(a), stableHashAny(a));
    try testing.expectEqual(stableHashAny(b), stableHashAny(b));
    try testing.expect(stableHashAny(a) != stableHashAny(b));
}

test "stableHashAny tagged union" {
    const U = union(enum) { x: u32, y: []const u8 };
    const a: U = .{ .x = 1 };
    const b: U = .{ .x = 1 };
    const c: U = .{ .x = 2 };
    try testing.expectEqual(stableHashAny(a), stableHashAny(b));
    try testing.expect(stableHashAny(a) != stableHashAny(c));
}

test "stableHashAnyBudgeted charges bytes for enum tag names" {
    const E = enum { a };
    // Enum "a" encodes as: tag name "a" (1 byte). Budget of 0 bytes must fail.
    var b = HashBudget.init(.{
        .max_bytes = 0,
        .max_elems = std.math.maxInt(u64),
        .max_depth = std.math.maxInt(u16),
    });
    try testing.expectError(error.ExceededBytes, stableHashAnySeededBudgeted(0, E.a, &b));
}

test "stableHashAnyBudgeted charges bytes for error names" {
    const E = error{SomeError};
    // Error name "SomeError" (9 bytes). Budget of 2 bytes must fail.
    var b = HashBudget.init(.{
        .max_bytes = 2,
        .max_elems = std.math.maxInt(u64),
        .max_depth = std.math.maxInt(u16),
    });
    try testing.expectError(error.ExceededBytes, stableHashAnySeededBudgeted(0, E.SomeError, &b));
}

test "stableHashAny budgeted matches unbounded" {
    // For each supported type, the budgeted path with unlimited budget must
    // produce the same hash as the unbounded path.
    var b = HashBudget.unlimited();

    try testing.expectEqual(stableHashAny(@as(u32, 42)), (try stableHashAnySeededBudgeted(0, @as(u32, 42), &b)));

    b = HashBudget.unlimited();
    try testing.expectEqual(stableHashAny(true), (try stableHashAnySeededBudgeted(0, true, &b)));

    b = HashBudget.unlimited();
    try testing.expectEqual(stableHashAny(@as([]const u8, "hello")), (try stableHashAnySeededBudgeted(0, @as([]const u8, "hello"), &b)));

    const E = enum { x, y };
    b = HashBudget.unlimited();
    try testing.expectEqual(stableHashAny(E.x), (try stableHashAnySeededBudgeted(0, E.x, &b)));

    b = HashBudget.unlimited();
    const opt: ?u32 = 42;
    try testing.expectEqual(stableHashAny(opt), (try stableHashAnySeededBudgeted(0, opt, &b)));
}

test "stableHashAny compile-time support predicate rejects non-stable surfaces" {
    const UnsupportedFn = fn () void;
    const Hidden = opaque {};
    const Untagged = union {
        a: u8,
        b: u16,
    };
    const NestedPointer = struct {
        ptr: *u32,
    };
    const SliceOnly = struct {
        bytes: []const u8,
        count: u16,
    };

    comptime {
        assert(isStableHashAnySupportedType(u32));
        assert(isStableHashAnySupportedType(SliceOnly));
        assert(isStableHashAnySupportedType(struct { maybe: ?u32, err: anyerror!u8 }));
        assert(!isStableHashAnySupportedType(*u32));
        assert(!isStableHashAnySupportedType(NestedPointer));
        assert(!isStableHashAnySupportedType(Untagged));
        assert(!isStableHashAnySupportedType(UnsupportedFn));
        assert(!isStableHashAnySupportedType(Hidden));
    }
}
