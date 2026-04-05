//! Integration hooks for zero-dependency counter emission.
//!
//! Design rationale: subsystems (static_memory, static_collections, etc.) need to emit
//! named counters for profiling without importing static_profile — which would create
//! downward dependencies. Instead, each subsystem calls a comptime callback, and the
//! application wires up the callback to static_profile at the top level.
//!
//! Pattern (from static_memory/src/memory/profile_hooks.zig):
//!   fn emit(ctx: *MyTrace, name: []const u8, value: i64) void { ... }
//!   hooks.emitCounter("sys", "mem_used", 1024, &trace, emit);
//!
//! The callback receives the concatenated name "sys.mem_used" and the value.
//! No import of static_profile is required in the subsystem.
//!

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Emit a single named counter via a comptime callback.
///
/// The emitted name is `base ++ "." ++ sub` (concatenated at comptime).
/// Preconditions (checked at comptime and runtime):
///   - base must be non-empty (comptime)
///   - sub must be non-empty (comptime)
///
/// Callback signature: `fn(ctx: @TypeOf(ctx), name: []const u8, value: i64) void`
pub fn emitCounter(
    comptime base: []const u8,
    comptime sub: []const u8,
    value: i64,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), []const u8, i64) void,
) void {
    // Comptime preconditions: empty base or sub would produce unidentifiable counter names.
    comptime assert(base.len > 0);
    comptime assert(sub.len > 0);
    // Runtime mirror: same property asserted from a second code path.
    assert(base.len > 0);
    assert(sub.len > 0);
    emit(ctx, base ++ "." ++ sub, value);
}

/// Emit a group of counters (comptime names, runtime values) via a callback.
///
/// Emits one call per entry in `names`, using the name `base ++ "." ++ names[i]`.
/// `values` must have the same length as `names` (checked at comptime and runtime).
/// Preconditions:
///   - base must be non-empty (comptime)
///   - names must be non-empty (comptime)
///   - values.len must equal names.len (runtime assertion)
///
/// Callback signature: `fn(ctx: @TypeOf(ctx), name: []const u8, value: i64) void`
pub fn emitCounters(
    comptime base: []const u8,
    comptime names: []const []const u8,
    values: []const i64,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), []const u8, i64) void,
) void {
    // Comptime preconditions: base and names must be non-empty.
    comptime assert(base.len > 0);
    comptime assert(names.len > 0);
    // Comptime bound: limit names to 64 entries. Larger groups should be split
    // into logical subsystems to keep per-call overhead bounded and names readable.
    comptime assert(names.len <= 64);
    // Comptime per-name non-empty check: every name must be a non-empty identifier.
    comptime {
        for (names) |name| assert(name.len > 0);
    }
    // Runtime mirror: same properties from a second code path; values length must match names.
    assert(base.len > 0);
    assert(values.len == names.len);
    inline for (names, 0..) |name, i| {
        emit(ctx, base ++ "." ++ name, values[i]);
    }
}

test "emitCounter calls callback with correct concatenated name and value" {
    const Collector = struct {
        name: []const u8 = "",
        value: i64 = 0,
        calls: u32 = 0,

        fn emit(self: *@This(), name: []const u8, value: i64) void {
            assert(self.calls == 0); // precondition: called at most once in this test
            self.name = name;
            self.value = value;
            self.calls += 1;
        }
    };

    var c = Collector{};
    emitCounter("sys", "mem_used", 1024, &c, Collector.emit);

    // Invariant: callback was called exactly once (paired assert + expectEqual).
    assert(c.calls == 1);
    try testing.expectEqual(@as(u32, 1), c.calls);

    // Invariant: name is the concatenation of base and sub (paired assert + expectEqualStrings).
    assert(std.mem.eql(u8, c.name, "sys.mem_used"));
    try testing.expectEqualStrings("sys.mem_used", c.name);

    // Invariant: value is passed through unchanged (paired assert + expectEqual).
    assert(c.value == 1024);
    try testing.expectEqual(@as(i64, 1024), c.value);
}

test "emitCounters calls callback once per entry with correct names" {
    const max_entries: usize = 4;
    const Collector = struct {
        names: [max_entries][]const u8 = undefined,
        values: [max_entries]i64 = undefined,
        len: u32 = 0,

        fn emit(self: *@This(), name: []const u8, value: i64) void {
            // Precondition: do not overflow collector buffer.
            assert(self.len < max_entries);
            self.names[self.len] = name;
            self.values[self.len] = value;
            self.len += 1;
        }
    };

    var c = Collector{};
    const vals = [_]i64{ 10, 20, 30 };
    emitCounters("perf", &.{ "a", "b", "c" }, &vals, &c, Collector.emit);

    // Invariant: call count equals names.len (paired assert + expectEqual).
    assert(c.len == 3);
    try testing.expectEqual(@as(u32, 3), c.len);

    // Invariant: names are base-prefixed (paired assert + expectEqualStrings).
    assert(std.mem.eql(u8, c.names[0], "perf.a"));
    try testing.expectEqualStrings("perf.a", c.names[0]);
    assert(std.mem.eql(u8, c.names[2], "perf.c"));
    try testing.expectEqualStrings("perf.c", c.names[2]);

    // Invariant: last value is passed through unchanged (paired assert + expectEqual).
    assert(c.values[2] == 30);
    try testing.expectEqual(@as(i64, 30), c.values[2]);
}
