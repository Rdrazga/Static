//! Hash Any - Generic Type-Aware Hashing.
//!
//! Provides `hashAny()` and friends: a type-dispatching hasher that handles
//! integers, floats, bools, enums, structs, unions, arrays, vectors, slices,
//! optionals, error sets, and error unions.
//!
//! This is an in-process hash. The output uses native byte order for integers
//! and enums, so it is NOT cross-architecture stable. For stable hashing, use
//! the `stable` module.
//!
//! ## Thread Safety
//! Unrestricted. All functions are pure and reentrant.
//!
//! ## Allocation Profile
//! All operations: no allocation (stack/register only).
//!
//! ## Design
//! - Byte-stable types (`std.meta.hasUniqueRepresentation(T)`) are hashed as
//!   raw bytes via Wyhash for speed.
//! - Non-byte-stable types (structs with padding, arrays of padded elements)
//!   are hashed structurally (field/element-wise) to avoid padding leaks.
//! - Float canonicalization: +/-0.0 hash the same; all NaN payloads hash the same.
//! - Pointer hash policy: `.address` hashes pointer addresses (fast, non-deterministic
//!   across runs); `.reject` causes a compile error for non-slice pointers.
//! - Budgeted variants enforce explicit work limits on untrusted input.

const std = @import("std");
const builtin = @import("builtin");
const budget_mod = @import("budget.zig");
const combine = @import("combine.zig");

pub const HashBudget = budget_mod.HashBudget;
pub const HashBudgetError = budget_mod.HashBudgetError;

const Wyhash = std.hash.Wyhash;

/// Hash seed type.
pub const Seed = u64;

// =============================================================================
// Public API
// =============================================================================

/// Hash any value using type-appropriate method (seed = 0).
///
/// See `hashAnySeeded()` for supported types and full semantics.
///
/// Postconditions: returns deterministic hash of value.
pub fn hashAny(value: anytype) u64 {
    return hashAnySeeded(0, value);
}

/// Hash any value with an explicit budget (seed = 0).
///
/// Enforces bounds on slice-driven loops without changing hashing semantics.
pub fn hashAnyBudgeted(value: anytype, b: *HashBudget) HashBudgetError!u64 {
    return hashAnySeededBudgeted(0, value, b);
}

/// Hash any value, rejecting non-slice pointers at compile time (seed = 0).
///
/// Use when pointer-address hashing would be a footgun.
pub fn hashAnyStrict(value: anytype) u64 {
    return hashAnySeededStrict(0, value);
}

/// Hash any value with budget, rejecting non-slice pointers (seed = 0).
pub fn hashAnyBudgetedStrict(value: anytype, b: *HashBudget) HashBudgetError!u64 {
    return hashAnySeededBudgetedStrict(0, value, b);
}

/// Hash any value with an explicit seed.
///
/// Supported types:
/// - integers (incl. `comptime_int`), floats (incl. `comptime_float`), bools, enums
/// - slices/arrays (byte-stable hashed as bytes; otherwise structural)
/// - pointers (address-based for non-slices; see `hashAnyStrict` to reject)
/// - structs (byte-stable hashed as bytes; otherwise structural)
/// - optionals, error sets, error unions, vectors, tagged unions
///
/// Unsupported types cause a compile error.
///
/// Postconditions: returns deterministic hash for given seed and value.
pub fn hashAnySeeded(seed: u64, value: anytype) u64 {
    return hashAnyImpl(seed, value, .address, void, {});
}

/// Hash any value with seed and budget.
pub fn hashAnySeededBudgeted(seed: u64, value: anytype, b: *HashBudget) HashBudgetError!u64 {
    return hashAnyImpl(seed, value, .address, *HashBudget, b);
}

/// Hash any value with seed, rejecting non-slice pointers.
pub fn hashAnySeededStrict(seed: u64, value: anytype) u64 {
    return hashAnyImpl(seed, value, .reject, void, {});
}

/// Hash any value with seed and budget, rejecting non-slice pointers.
pub fn hashAnySeededBudgetedStrict(seed: u64, value: anytype, b: *HashBudget) HashBudgetError!u64 {
    return hashAnyImpl(seed, value, .reject, *HashBudget, b);
}

/// Hash a tuple of values (seed = 0).
///
/// Hashes each field in order using hashAny() and combines with combineOrdered64().
///
/// Postconditions: returns order-dependent combined hash of all fields.
pub fn hashTuple(values: anytype) u64 {
    return hashTupleSeeded(0, values);
}

/// Hash a tuple of values with a seed.
///
/// Postconditions: returns order-dependent combined hash of all fields.
pub fn hashTupleSeeded(seed: u64, values: anytype) u64 {
    return hashTupleImpl(seed, values, .address, void, {});
}

// =============================================================================
// Internal - Pointer policy
// =============================================================================

const PointerHashPolicy = enum {
    address,
    reject,
};

fn combineOrdered(a: u64, b_val: u64) u64 {
    return combine.combineOrdered64(.{ .left = a, .right = b_val });
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
        std.debug.assert(B == void or B == *HashBudget);
    }
    return if (B == void) T else HashBudgetError!T;
}

// =============================================================================
// Internal - Tuple hashing (unified)
// =============================================================================

fn hashTupleImpl(seed: u64, values: anytype, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    var result: u64 = seed;
    inline for (std.meta.fields(@TypeOf(values))) |field| {
        const value = @field(values, field.name);
        if (comptime B != void) {
            const h = try hashAnyImpl(seed, value, policy, *HashBudget, b);
            result = combineOrdered(result, h);
        } else {
            const h = hashAnyImpl(seed, value, policy, void, {});
            result = combineOrdered(result, h);
        }
    }
    return result;
}

// =============================================================================
// Internal - Type dispatch (unified)
// =============================================================================

fn hashAnyImpl(seed: u64, value: anytype, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);

    if (comptime B != void) try b.enter();
    defer if (comptime B != void) b.leave();

    const T = @TypeOf(value);

    // Fast path for byte slices - the most common case.
    if (T == []const u8 or T == []u8) {
        std.debug.assert(value.len == 0 or @intFromPtr(value.ptr) != 0);
        if (comptime B != void) try b.chargeBytes(value.len);
        return Wyhash.hash(seed, value);
    }

    return switch (@typeInfo(T)) {
        .int => blk: {
            if (comptime B != void) try b.chargeBytes(@sizeOf(T));
            break :blk Wyhash.hash(seed, std.mem.asBytes(&value));
        },
        .comptime_int => hashComptimeIntImpl(seed, value, B, b),
        .float => hashFloatImpl(seed, value, B, b),
        .comptime_float => hashComptimeFloatImpl(seed, value, B, b),
        .bool => blk: {
            if (comptime B != void) try b.chargeBytes(1);
            const byte: u8 = if (value) 1 else 0;
            // Bool maps to exactly 0 or 1.
            std.debug.assert(byte == 0 or byte == 1);
            break :blk Wyhash.hash(seed, std.mem.asBytes(&byte));
        },
        .optional => hashOptionalImpl(seed, value, policy, B, b),
        .error_set => blk: {
            const code = @intFromError(value);
            // Error codes are never zero in Zig.
            std.debug.assert(code != 0);
            if (comptime B != void) try b.chargeBytes(@sizeOf(@TypeOf(code)));
            break :blk Wyhash.hash(seed, std.mem.asBytes(&code));
        },
        .error_union => hashErrorUnionImpl(seed, value, policy, B, b),
        .pointer => |ptr| hashPointerImpl(seed, value, ptr, policy, B, b),
        .array => hashArrayImpl(seed, value, policy, B, b),
        .vector => |vec| hashVectorImpl(seed, value, vec, policy, B, b),
        .@"struct" => hashStructImpl(seed, value, policy, B, b),
        .@"union" => |u| hashUnionImpl(seed, value, u, policy, B, b),
        .@"enum" => blk: {
            const int_val = @intFromEnum(value);
            // Enum integer representation must have nonzero size.
            std.debug.assert(@sizeOf(@TypeOf(int_val)) > 0);
            if (comptime B != void) try b.chargeBytes(@sizeOf(@TypeOf(int_val)));
            break :blk Wyhash.hash(seed, std.mem.asBytes(&int_val));
        },
        else => @compileError("Cannot hash type: " ++ @typeName(T)),
    };
}

// =============================================================================
// Internal - Type-specific hashers (unified)
// =============================================================================

fn typeContainsNonSlicePointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice) typeContainsNonSlicePointer(ptr.child) else true,
        .optional => |opt| typeContainsNonSlicePointer(opt.child),
        .error_union => |eu| typeContainsNonSlicePointer(eu.payload),
        .array => |arr| typeContainsNonSlicePointer(arr.child),
        .vector => |vec| typeContainsNonSlicePointer(vec.child),
        .@"struct" => {
            inline for (std.meta.fields(T)) |field| {
                if (typeContainsNonSlicePointer(field.type)) return true;
            }
            return false;
        },
        .@"union" => |u| {
            inline for (u.fields) |field| {
                if (typeContainsNonSlicePointer(field.type)) return true;
            }
            return false;
        },
        else => false,
    };
}

fn isHashAnySupportedType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int,
        .comptime_int,
        .float,
        .comptime_float,
        .bool,
        .error_set,
        .pointer,
        => true,
        .optional => |opt| isHashAnySupportedType(opt.child),
        .error_union => |eu| isHashAnySupportedType(eu.payload),
        .array => |arr| isHashAnySupportedType(arr.child),
        .vector => |vec| isHashAnySupportedType(vec.child),
        .@"enum" => true,
        .@"struct" => {
            inline for (std.meta.fields(T)) |field| {
                if (!isHashAnySupportedType(field.type)) return false;
            }
            return true;
        },
        .@"union" => |u| {
            if (u.tag_type == null) return false;
            inline for (u.fields) |field| {
                if (!isHashAnySupportedType(field.type)) return false;
            }
            return true;
        },
        else => false,
    };
}

fn isHashAnyStrictSupportedType(comptime T: type) bool {
    return isHashAnySupportedType(T) and !typeContainsNonSlicePointer(T);
}

fn hashComptimeIntImpl(seed: u64, comptime value: anytype, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    const s = std.fmt.comptimePrint("{}", .{value});
    // Comptime int string representation must be non-empty.
    comptime std.debug.assert(s.len > 0);
    if (comptime B != void) try b.chargeBytes(s.len);
    return Wyhash.hash(seed, s);
}

/// Canonicalize a float: normalize NaN payloads and collapse +/-0.0 to +0.0.
fn canonicalizeFloat(comptime F: type, value: F) F {
    var canonical: F = value;
    if (std.math.isNan(canonical)) canonical = std.math.nan(F);
    if (canonical == 0) canonical = @as(F, 0);
    // Postcondition: no negative zero remains after canonicalization.
    if (canonical == 0) std.debug.assert(!std.math.signbit(canonical));
    return canonical;
}

fn hashFloatImpl(seed: u64, value: anytype, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    const F = @TypeOf(value);
    if (comptime B != void) try b.chargeBytes(@sizeOf(F));
    const canonical = canonicalizeFloat(F, value);
    return Wyhash.hash(seed, std.mem.asBytes(&canonical));
}

fn hashComptimeFloatImpl(seed: u64, comptime value: anytype, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    if (comptime B != void) try b.chargeBytes(@sizeOf(f64));
    const canonical = canonicalizeFloat(f64, @as(f64, value));
    return Wyhash.hash(seed, std.mem.asBytes(&canonical));
}

fn hashOptionalImpl(seed: u64, value: anytype, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    if (comptime B != void) try b.chargeElems(1);
    if (value) |payload| {
        if (comptime B != void) {
            return hashTupleImpl(seed, .{ @as(u8, 1), payload }, policy, *HashBudget, b);
        } else {
            return hashTupleImpl(seed, .{ @as(u8, 1), payload }, policy, void, {});
        }
    }
    if (comptime B != void) {
        return hashTupleImpl(seed, .{@as(u8, 0)}, policy, *HashBudget, b);
    } else {
        return hashTupleImpl(seed, .{@as(u8, 0)}, policy, void, {});
    }
}

fn hashErrorUnionImpl(seed: u64, value: anytype, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    if (comptime B != void) try b.chargeElems(1);
    if (value) |payload| {
        if (comptime B != void) {
            return hashTupleImpl(seed, .{ @as(u8, 1), payload }, policy, *HashBudget, b);
        } else {
            return hashTupleImpl(seed, .{ @as(u8, 1), payload }, policy, void, {});
        }
    } else |err| {
        const code = @intFromError(err);
        if (comptime B != void) {
            return hashTupleImpl(seed, .{ @as(u8, 0), code }, policy, *HashBudget, b);
        } else {
            return hashTupleImpl(seed, .{ @as(u8, 0), code }, policy, void, {});
        }
    }
}

fn hashPointerImpl(seed: u64, value: anytype, comptime ptr: std.builtin.Type.Pointer, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);

    if (ptr.size == .slice) {
        std.debug.assert(value.len == 0 or @intFromPtr(value.ptr) != 0);
        const Child = ptr.child;
        if (Child == u8 or (std.meta.hasUniqueRepresentation(Child) and
            (policy == .address or !typeContainsNonSlicePointer(Child))))
        {
            const bytes = std.mem.sliceAsBytes(value);
            if (comptime B != void) try b.chargeBytes(bytes.len);
            return Wyhash.hash(seed, bytes);
        }
        // Structural element-wise hashing for non-byte-stable slices.
        if (comptime B != void) try b.chargeElems(value.len);
        var result: u64 = seed;
        for (value) |elem| {
            if (comptime B != void) {
                result = combineOrdered(result, try hashAnyImpl(seed, elem, policy, *HashBudget, b));
            } else {
                result = combineOrdered(result, hashAnyImpl(seed, elem, policy, void, {}));
            }
        }
        return result;
    }

    if (policy == .reject) {
        @compileError("hashAnyStrict cannot hash pointer type: " ++ @typeName(@TypeOf(value)));
    }

    if (comptime B != void) try b.chargeBytes(@sizeOf(usize));
    const addr = @intFromPtr(value);
    if (!ptr.is_allowzero) std.debug.assert(addr != 0);
    return Wyhash.hash(seed, std.mem.asBytes(&addr));
}

fn hashArrayImpl(seed: u64, value: anytype, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    const T = @TypeOf(value);
    if (std.meta.hasUniqueRepresentation(T) and
        (policy == .address or !typeContainsNonSlicePointer(T)))
    {
        if (comptime B != void) try b.chargeBytes(@sizeOf(T));
        return Wyhash.hash(seed, std.mem.asBytes(&value));
    }
    // Structural element-wise hashing for non-byte-stable arrays.
    const arr = @typeInfo(T).array;
    if (comptime B != void) try b.chargeElems(arr.len);
    var result: u64 = seed;
    for (value) |elem| {
        if (comptime B != void) {
            result = combineOrdered(result, try hashAnyImpl(seed, elem, policy, *HashBudget, b));
        } else {
            result = combineOrdered(result, hashAnyImpl(seed, elem, policy, void, {}));
        }
    }
    return result;
}

fn hashVectorImpl(seed: u64, value: anytype, comptime vec: std.builtin.Type.Vector, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    const T = @TypeOf(value);
    if (std.meta.hasUniqueRepresentation(T) and
        (policy == .address or !typeContainsNonSlicePointer(T)))
    {
        if (comptime B != void) try b.chargeBytes(@sizeOf(T));
        return Wyhash.hash(seed, std.mem.asBytes(&value));
    }
    if (comptime B != void) try b.chargeElems(vec.len);
    var result: u64 = seed;
    inline for (0..vec.len) |i| {
        if (comptime B != void) {
            result = combineOrdered(result, try hashAnyImpl(seed, value[i], policy, *HashBudget, b));
        } else {
            result = combineOrdered(result, hashAnyImpl(seed, value[i], policy, void, {}));
        }
    }
    return result;
}

fn hashStructImpl(seed: u64, value: anytype, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    const T = @TypeOf(value);
    if (std.meta.hasUniqueRepresentation(T) and
        (policy == .address or !typeContainsNonSlicePointer(T)))
    {
        if (comptime B != void) try b.chargeBytes(@sizeOf(T));
        return Wyhash.hash(seed, std.mem.asBytes(&value));
    }
    // Structural field-wise hashing for non-byte-stable structs.
    const fields = std.meta.fields(T);
    if (comptime B != void) try b.chargeElems(fields.len);
    var result: u64 = seed;
    inline for (fields) |field| {
        if (comptime B != void) {
            result = combineOrdered(result, try hashAnyImpl(seed, @field(value, field.name), policy, *HashBudget, b));
        } else {
            result = combineOrdered(result, hashAnyImpl(seed, @field(value, field.name), policy, void, {}));
        }
    }
    return result;
}

fn hashUnionImpl(seed: u64, value: anytype, comptime u: std.builtin.Type.Union, comptime policy: PointerHashPolicy, comptime B: type, b: B) MaybeError(B, u64) {
    comptime std.debug.assert(B == void or B == *HashBudget);
    const T = @TypeOf(value);
    const Tag = u.tag_type orelse @compileError("Cannot hash untagged union type: " ++ @typeName(T));
    const tag: Tag = std.meta.activeTag(value);

    if (comptime B != void) try b.chargeElems(1);
    var result: u64 = seed;
    if (comptime B != void) {
        result = combineOrdered(result, try hashAnyImpl(seed, tag, policy, *HashBudget, b));
    } else {
        result = combineOrdered(result, hashAnyImpl(seed, tag, policy, void, {}));
    }

    inline for (u.fields) |field| {
        const field_tag: Tag = @field(Tag, field.name);
        if (tag == field_tag) {
            if (comptime B != void) {
                result = combineOrdered(result, try hashAnyImpl(seed, @field(value, field.name), policy, *HashBudget, b));
            } else {
                result = combineOrdered(result, hashAnyImpl(seed, @field(value, field.name), policy, void, {}));
            }
            return result;
        }
    }
    // Proof: `tag` is obtained from `std.meta.activeTag(value)` which returns
    // a value of type `Tag`. The `inline for` iterates all fields of the union,
    // and each field defines a unique `Tag` variant. A tagged union's active tag
    // must match exactly one field, so the loop always returns before this point.
    unreachable;
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: exercise representative values for each supported type category, validate padding-safety and
// canonicalization rules, and verify that budgeted hashing enforces limits without changing results.

test "hashAny integers" {
    const h1 = hashAny(@as(u32, 42));
    const h2 = hashAny(@as(u32, 42));
    const h3 = hashAny(@as(u32, 43));
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "hashTuple" {
    const h1 = hashTuple(.{ @as(u32, 1), @as(u32, 2), @as(u32, 3) });
    const h2 = hashTuple(.{ @as(u32, 1), @as(u32, 2), @as(u32, 3) });
    const h3 = hashTuple(.{ @as(u32, 3), @as(u32, 2), @as(u32, 1) });
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "hashTuple supports comptime_int fields" {
    const h1 = hashTuple(.{ 1, 2, 3 });
    const h2 = hashTuple(.{ 1, 2, 3 });
    const h3 = hashTuple(.{ 3, 2, 1 });
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "hashAny integer uses native byte order" {
    const value: u32 = 0x01020304;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, builtin.cpu.arch.endian());
    const expected = Wyhash.hash(0, bytes[0..]);
    try std.testing.expectEqual(expected, hashAny(value));
}

test "hashAny avoids hashing padding (array of padded structs)" {
    const Key = struct { a: u8, b: u32 };

    const k1 = blk: {
        var bytes: [@sizeOf(Key)]u8 = undefined;
        @memset(bytes[0..], 0xAA);
        bytes[@offsetOf(Key, "a")] = 1;
        std.mem.writeInt(u32, bytes[@offsetOf(Key, "b")..][0..4], 0x11223344, builtin.cpu.arch.endian());
        var key: Key = undefined;
        @memcpy(std.mem.asBytes(&key), bytes[0..]);
        break :blk key;
    };

    const k2 = blk: {
        var bytes: [@sizeOf(Key)]u8 = undefined;
        @memset(bytes[0..], 0x55);
        bytes[@offsetOf(Key, "a")] = 1;
        std.mem.writeInt(u32, bytes[@offsetOf(Key, "b")..][0..4], 0x11223344, builtin.cpu.arch.endian());
        var key: Key = undefined;
        @memcpy(std.mem.asBytes(&key), bytes[0..]);
        break :blk key;
    };

    try std.testing.expect(std.meta.eql(k1, k2));

    const a1 = [_]Key{ k1, k1, k1 };
    const a2 = [_]Key{ k2, k2, k2 };
    try std.testing.expectEqual(hashAny(a1), hashAny(a2));

    const a3 = [_]Key{ k1, k1, .{ .a = 2, .b = 0x11223344 } };
    try std.testing.expect(hashAny(a1) != hashAny(a3));
}

test "hashAny optional" {
    const a: ?u32 = null;
    const b_val: ?u32 = 1;
    try std.testing.expectEqual(hashAny(a), hashAny(a));
    try std.testing.expectEqual(hashAny(b_val), hashAny(b_val));
    try std.testing.expect(hashAny(a) != hashAny(b_val));
}

test "hashAny error set" {
    const E = error{ A, B };
    try std.testing.expectEqual(hashAny(E.A), hashAny(E.A));
    try std.testing.expect(hashAny(E.A) != hashAny(E.B));
}

test "hashAny error union" {
    const E = error{ A, B };
    const V = E!u32;
    const ok: V = 123;
    const err: V = E.A;
    try std.testing.expectEqual(hashAny(ok), hashAny(ok));
    try std.testing.expectEqual(hashAny(err), hashAny(err));
    try std.testing.expect(hashAny(ok) != hashAny(err));
}

test "hashAny vector" {
    const V = @Vector(4, u32);
    const a: V = .{ 1, 2, 3, 4 };
    const b_val: V = .{ 1, 2, 3, 4 };
    const c: V = .{ 1, 2, 3, 5 };
    try std.testing.expectEqual(hashAny(a), hashAny(b_val));
    try std.testing.expect(hashAny(a) != hashAny(c));
}

test "hashAny float canonicalizes +/-0.0" {
    const a: f32 = 0.0;
    const b_val: f32 = -0.0;
    try std.testing.expectEqual(hashAny(a), hashAny(b_val));
    try std.testing.expectEqual(hashAny(0.0), hashAny(-0.0));
}

test "hashAny float canonicalizes NaN payloads" {
    const nan1: f32 = std.math.nan(f32);
    const nan2: f32 = @bitCast(@as(u32, 0x7fc00001));
    try std.testing.expect(std.math.isNan(nan1));
    try std.testing.expect(std.math.isNan(nan2));
    try std.testing.expectEqual(hashAny(nan1), hashAny(nan2));
}

test "hashAny struct with slice field is content-based" {
    const Key = struct { bytes: []const u8 };

    const a_storage = [_]u8{ 1, 2, 3, 4 };
    const b_storage = [_]u8{ 1, 2, 3, 4 };

    const a: Key = .{ .bytes = a_storage[0..] };
    const b_val: Key = .{ .bytes = b_storage[0..] };

    try std.testing.expect(std.meta.eql(a, b_val));
    try std.testing.expectEqual(hashAny(a), hashAny(b_val));
}

test "hashAny tagged union" {
    const U = union(enum) { a: u32, b: []const u8 };
    const x: U = .{ .a = 1 };
    const y: U = .{ .a = 1 };
    const z: U = .{ .a = 2 };
    const w: U = .{ .b = "a" };
    try std.testing.expectEqual(hashAny(x), hashAny(y));
    try std.testing.expect(hashAny(x) != hashAny(z));
    try std.testing.expect(hashAny(x) != hashAny(w));
}

test "hashAnyStrict hashes values without pointer addresses" {
    const h1 = hashAnyStrict(@as(u32, 123));
    const h2 = hashAnyStrict(@as(u32, 123));
    try std.testing.expectEqual(h1, h2);

    // Slices are hashed by contents (same as hashAny).
    const a: []const u8 = "abc";
    try std.testing.expectEqual(hashAny(a), hashAnyStrict(a));
}

test "hashAny pointer address policy hashes pointer addresses" {
    var x: u32 = 123;
    const ptr: *u32 = &x;
    const addr = @intFromPtr(ptr);
    try std.testing.expectEqual(Wyhash.hash(0, std.mem.asBytes(&addr)), hashAny(ptr));
}

test "hashAnyBudgeted enforces max_bytes on byte slices" {
    var b = HashBudget.init(.{
        .max_bytes = 2,
        .max_elems = std.math.maxInt(u64),
        .max_depth = std.math.maxInt(u16),
    });
    try std.testing.expectError(error.ExceededBytes, hashAnySeededBudgeted(0, "abc", &b));
}

test "hashAnyBudgeted enforces max_elems on structural slices" {
    const Elem = struct { a: u8, b: u32 };
    comptime std.debug.assert(!std.meta.hasUniqueRepresentation(Elem));
    const xs = [_]Elem{
        .{ .a = 1, .b = 2 },
        .{ .a = 3, .b = 4 },
        .{ .a = 5, .b = 6 },
    };
    const xs_slice: []const Elem = xs[0..];
    var b = HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = 2,
        .max_depth = std.math.maxInt(u16),
    });
    try std.testing.expectError(error.ExceededElems, hashAnySeededBudgeted(0, xs_slice, &b));
}

test "hashAnyBudgeted enforces max_depth" {
    const value: ?u32 = 1;
    var b = HashBudget.init(.{
        .max_bytes = std.math.maxInt(u64),
        .max_elems = std.math.maxInt(u64),
        .max_depth = 1,
    });
    try std.testing.expectError(error.ExceededDepth, hashAnySeededBudgeted(0, value, &b));
}

test "hashAny budgeted matches unbounded" {
    // For each supported type, the budgeted path with unlimited budget must
    // produce the same hash as the unbounded path.
    var b = HashBudget.unlimited();

    try std.testing.expectEqual(hashAny(@as(u32, 42)), (try hashAnySeededBudgeted(0, @as(u32, 42), &b)));

    b = HashBudget.unlimited();
    try std.testing.expectEqual(hashAny(true), (try hashAnySeededBudgeted(0, true, &b)));

    b = HashBudget.unlimited();
    try std.testing.expectEqual(hashAny(@as([]const u8, "hello")), (try hashAnySeededBudgeted(0, @as([]const u8, "hello"), &b)));

    const E = enum { x, y };
    b = HashBudget.unlimited();
    try std.testing.expectEqual(hashAny(E.x), (try hashAnySeededBudgeted(0, E.x, &b)));

    b = HashBudget.unlimited();
    const opt: ?u32 = 42;
    try std.testing.expectEqual(hashAny(opt), (try hashAnySeededBudgeted(0, opt, &b)));

    b = HashBudget.unlimited();
    const arr = [_]u32{ 1, 2, 3 };
    try std.testing.expectEqual(hashAny(arr), (try hashAnySeededBudgeted(0, arr, &b)));
}

test "hashAny compile-time support predicates cover unsupported and strict surfaces" {
    const UnsupportedFn = fn () void;
    const Untagged = union {
        a: u8,
        b: u16,
    };
    const NestedPointer = struct {
        ptr: *u32,
    };
    const SliceOnly = struct {
        bytes: []const u8,
        flag: bool,
    };

    comptime {
        std.debug.assert(isHashAnySupportedType(u32));
        std.debug.assert(isHashAnySupportedType(*u32));
        std.debug.assert(isHashAnySupportedType(SliceOnly));
        std.debug.assert(isHashAnySupportedType(struct { maybe: ?u32, err: anyerror!u8 }));
        std.debug.assert(!isHashAnySupportedType(UnsupportedFn));
        std.debug.assert(!isHashAnySupportedType(Untagged));

        std.debug.assert(typeContainsNonSlicePointer(*u32));
        std.debug.assert(typeContainsNonSlicePointer(NestedPointer));
        std.debug.assert(!typeContainsNonSlicePointer(SliceOnly));

        std.debug.assert(!isHashAnyStrictSupportedType(*u32));
        std.debug.assert(!isHashAnyStrictSupportedType(NestedPointer));
        std.debug.assert(isHashAnyStrictSupportedType(SliceOnly));
        std.debug.assert(isHashAnyStrictSupportedType(struct { payload: [2]u16 }));
    }
}
