//! Chrome trace event recording (zone and counter events).
//!
//! Key types: `EnabledTrace` (records events to a bounded buffer), `DisabledTrace`
//! (no-op shim with identical API), and `Trace` (alias to one based on the
//! `static_profile.caps.tracing_enabled` build option mirror).
//!
//! Export format: Chrome JSON trace format (`writeChromeTraceJson`), loadable in
//! `chrome://tracing` or Perfetto. Zone events use `B`/`E` phases; counter events
//! use the `C` phase.
//!
//! Zone pairing: in debug builds `EnabledTrace` tracks open zone depth. A non-zero
//! depth at `deinit` asserts, catching unpaired `beginZone`/`endZone` calls.
//!
//! Thread safety: none. Use one trace per thread or serialize access externally.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");
const core = @import("static_core");

const caps = @import("caps.zig");
const zone = @import("zone.zig");
const counter_mod = @import("counter.zig");

pub const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    InvalidConfig,
};

comptime {
    core.errors.assertVocabularySubset(Error);
}

pub const Phase = enum {
    begin,
    end,
};

pub const Event = struct {
    name: []const u8,
    ts: u64,
    tid: u32,
    pid: u32 = 0,
    ph: Phase,
};

/// Tagged union covering all event kinds in the unified trace buffer.
/// Zone events (Begin/End) and counter events share a single bounded buffer
/// so the exported timeline is fully coherent.
pub const TraceEvent = union(enum) {
    zone: Event,
    counter: counter_mod.CounterEvent,
};

pub const EnabledTrace = struct {
    allocator: std.mem.Allocator,
    max_events: usize,
    events: std.ArrayListUnmanaged(TraceEvent) = .{},
    /// Tracks open zone depth in debug builds to detect unpaired begin/end calls.
    /// Always zero in non-debug builds (never read or written outside of debug guards).
    zone_depth: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, max_events: usize) Error!EnabledTrace {
        if (max_events == 0) return Error.InvalidConfig;
        var self: EnabledTrace = .{
            .allocator = allocator,
            .max_events = max_events,
        };

        errdefer self.events.deinit(allocator);

        try self.events.ensureTotalCapacity(allocator, max_events);
        // Postcondition: capacity meets the requested minimum.
        assert(self.events.capacity >= max_events);
        // Postcondition: buffer starts empty.
        assert(self.events.items.len == 0);
        return self;
    }

    pub fn deinit(self: *EnabledTrace) void {
        assert(self.max_events > 0);
        // Postcondition: all opened zones must have been closed before deinit.
        // An unbalanced trace indicates a missing endZone call, which produces a
        // structurally incomplete trace that cannot be meaningfully visualized.
        if (builtin.mode == .Debug) {
            assert(self.zone_depth == 0);
        }
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    /// Opens a new zone event with the given `name`, timestamp `ts`, and thread ID `tid`.
    /// Returns a `ZoneToken` that must be passed to `endZone` to close the zone.
    ///
    /// The `name` slice is borrowed, not copied. The caller must ensure it remains
    /// valid until `writeChromeTraceJson` or `deinit` is called.
    ///
    /// Returns `NoSpaceLeft` if the bounded event buffer is already full.
    pub fn beginZone(self: *EnabledTrace, name: []const u8, ts: u64, tid: u32) Error!zone.ZoneToken {
        assert(self.events.capacity >= self.max_events);
        // Precondition: zone name must be non-empty; empty names are unidentifiable in traces.
        assert(name.len > 0);
        try self.appendTraceEvent(.{ .zone = .{
            .name = name,
            .ts = ts,
            .tid = tid,
            .ph = .begin,
        } });
        // Increment depth only after the event is durably appended.
        // This ensures that if appendTraceEvent returns NoSpaceLeft, depth is unchanged
        // and deinit's balance assertion remains valid.
        if (builtin.mode == .Debug) {
            self.zone_depth += 1;
            // Overflow guard: depth wrapping would silently hide a deeply unbalanced trace.
            assert(self.zone_depth > 0);
        }
        return .{ .name = name, .tid = tid };
    }

    pub fn endZone(self: *EnabledTrace, tok: zone.ZoneToken, ts: u64) Error!void {
        assert(self.events.capacity >= self.max_events);
        // Precondition: token must carry a non-empty name (matches beginZone contract).
        assert(tok.name.len > 0);
        if (builtin.mode == .Debug) {
            // Precondition: must have a matching begin zone; zero depth means unbalanced.
            assert(self.zone_depth > 0);
        }
        try self.appendTraceEvent(.{ .zone = .{
            .name = tok.name,
            .ts = ts,
            .tid = tok.tid,
            .pid = tok.pid,
            .ph = .end,
        } });
        // Decrement depth only after the end event is durably appended.
        if (builtin.mode == .Debug) {
            self.zone_depth -= 1;
        }
    }

    /// Record a named integer counter event. name must be non-empty.
    /// Returns NoSpaceLeft when the bounded buffer is full.
    pub fn recordCounter(
        self: *EnabledTrace,
        name: []const u8,
        ts: u64,
        tid: u32,
        value: i64,
    ) Error!void {
        assert(self.events.capacity >= self.max_events);
        // Precondition: counter name must be non-empty; pairs with writeCounterEventJson assertion.
        assert(name.len > 0);
        try self.appendTraceEvent(.{ .counter = .{
            .name = name,
            .ts = ts,
            .tid = tid,
            .value = value,
        } });
    }

    pub fn writeChromeTraceJson(self: *const EnabledTrace, writer: *std.Io.Writer) !void {
        // Precondition: event count is within the configured bound.
        assert(self.events.items.len <= self.max_events);
        try writeChromeTraceJsonImpl(writer, self.events.items);
    }

    fn appendTraceEvent(self: *EnabledTrace, ev: TraceEvent) Error!void {
        assert(self.events.capacity >= self.max_events);
        if (self.events.items.len >= self.max_events) return Error.NoSpaceLeft;
        // Capacity is reserved in init(), so this append cannot allocate.
        self.events.appendAssumeCapacity(ev);
        // Postcondition: item was actually appended.
        assert(self.events.items.len > 0);
    }
};

pub const DisabledTrace = struct {
    pub fn init(_: std.mem.Allocator, max_events: usize) Error!DisabledTrace {
        // Mirror EnabledTrace contract: max_events == 0 is invalid configuration.
        if (max_events == 0) return Error.InvalidConfig;
        return .{};
    }

    pub fn deinit(_: *DisabledTrace) void {}

    pub fn beginZone(_: *DisabledTrace, name: []const u8, _: u64, tid: u32) Error!zone.ZoneToken {
        // Mirror EnabledTrace assertion: name must be non-empty (pair assertion).
        assert(name.len > 0);
        return .{ .name = name, .tid = tid };
    }

    pub fn endZone(_: *DisabledTrace, tok: zone.ZoneToken, _: u64) Error!void {
        // Mirror EnabledTrace assertion: token name must be non-empty (pair assertion).
        assert(tok.name.len > 0);
    }

    pub fn recordCounter(_: *DisabledTrace, name: []const u8, _: u64, _: u32, _: i64) Error!void {
        // Mirror EnabledTrace assertion: counter name must be non-empty (pair assertion).
        assert(name.len > 0);
    }

    pub fn writeChromeTraceJson(_: *const DisabledTrace, writer: *std.Io.Writer) !void {
        try writer.writeAll("[]");
    }
};

pub const Trace = if (caps.tracing_enabled) EnabledTrace else DisabledTrace;

/// Write a JSON array of zone Events (no counter events). Used for standalone export
/// of a fixed event slice; does not require a full EnabledTrace.
pub fn writeChromeTraceJson(writer: *std.Io.Writer, events: []const Event) !void {
    try writer.writeAll("[");
    for (events, 0..) |ev, i| {
        if (i != 0) try writer.writeAll(",");
        try writeZoneEventJson(writer, ev);
    }
    try writer.writeAll("]");
}

fn writeChromeTraceJsonImpl(writer: *std.Io.Writer, events: []const TraceEvent) !void {
    // Precondition: a reasonable upper bound on the event slice prevents runaway output.
    const max_events_limit: usize = 1 << 20; // 1 Mi events — a generous but finite cap.
    assert(events.len <= max_events_limit);
    try writer.writeAll("[");
    for (events, 0..) |tev, i| {
        if (i != 0) try writer.writeAll(",");
        switch (tev) {
            .zone => |ev| try writeZoneEventJson(writer, ev),
            .counter => |ev| try counter_mod.writeCounterEventJson(writer, ev),
        }
    }
    try writer.writeAll("]");
}

fn writeZoneEventJson(writer: *std.Io.Writer, ev: Event) !void {
    // Precondition: zone name must be non-empty; unidentifiable events corrupt traces.
    assert(ev.name.len > 0);
    // Precondition: phase must be one of the two defined values (Begin/End).
    comptime assert(std.meta.fields(Phase).len == 2);
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, ev.name);
    try writer.writeAll(",\"ph\":");
    try writeJsonString(writer, phaseString(ev.ph));
    try writer.writeAll(",\"ts\":");
    try writer.print("{}", .{ev.ts});
    try writer.writeAll(",\"pid\":");
    try writer.print("{}", .{ev.pid});
    try writer.writeAll(",\"tid\":");
    try writer.print("{}", .{ev.tid});
    try writer.writeAll("}");
}

fn phaseString(ph: Phase) []const u8 {
    // Comptime assertion: Phase enum must have exactly two fields (begin and end).
    // This guards against accidental extension of Phase that would bypass the switch.
    comptime assert(std.meta.fields(Phase).len == 2);
    return switch (ph) {
        .begin => "B",
        .end => "E",
    };
}

/// Maximum byte length accepted for a JSON string value. Strings beyond this size
/// risk unbounded output allocation and likely indicate a programming error.
pub const max_json_string_len: usize = 4096;

pub fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    // Precondition: strings exceeding the limit indicate a caller error; production
    // zone names and counter names are always short identifiers.
    assert(s.len <= max_json_string_len);
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{@as(u16, ch)});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "writeChromeTraceJson is deterministic" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);

    const events = [_]Event{
        .{ .name = "a", .ts = 10, .tid = 1, .ph = .begin },
        .{ .name = "a", .ts = 20, .tid = 1, .ph = .end },
    };
    try writeChromeTraceJson(&aw.writer, &events);

    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);
    const got = out.items;
    try testing.expectEqualStrings(
        "[{\"name\":\"a\",\"ph\":\"B\",\"ts\":10,\"pid\":0,\"tid\":1},{\"name\":\"a\",\"ph\":\"E\",\"ts\":20,\"pid\":0,\"tid\":1}]",
        got,
    );
}

test "EnabledTrace init with max_events 0 returns InvalidConfig" {
    try testing.expectError(Error.InvalidConfig, EnabledTrace.init(testing.allocator, 0));
}

test "EnabledTrace bounded buffer returns NoSpaceLeft when full" {
    var t = try EnabledTrace.init(testing.allocator, 2);
    defer t.deinit();

    const tok1 = try t.beginZone("a", 1, 1);
    try t.endZone(tok1, 2);
    // Buffer now full (2 events).
    try testing.expectError(Error.NoSpaceLeft, t.beginZone("b", 3, 1));
}

test "EnabledTrace beginZone and endZone are recorded as a pair" {
    var t = try EnabledTrace.init(testing.allocator, 4);
    defer t.deinit();

    const tok = try t.beginZone("work", 100, 7);
    try t.endZone(tok, 200);

    try testing.expectEqual(@as(usize, 2), t.events.items.len);
    try testing.expectEqual(Phase.begin, t.events.items[0].zone.ph);
    try testing.expectEqual(Phase.end, t.events.items[1].zone.ph);
    try testing.expectEqualStrings("work", t.events.items[0].zone.name);
    try testing.expectEqual(@as(u32, 7), t.events.items[0].zone.tid);
}

test "DisabledTrace beginZone and endZone are no-ops" {
    var t = try DisabledTrace.init(testing.allocator, 8);
    defer t.deinit();

    const tok = try t.beginZone("noop", 1, 1);
    try t.endZone(tok, 2);
    // DisabledTrace has no events field; just verify the calls do not error.
    try testing.expectEqualStrings("noop", tok.name);
}

test "DisabledTrace writeChromeTraceJson writes empty array" {
    var t = try DisabledTrace.init(testing.allocator, 4);
    defer t.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    try t.writeChromeTraceJson(&aw.writer);

    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("[]", out.items);
}

test "writeChromeTraceJson with zero events writes empty array" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    try writeChromeTraceJson(&aw.writer, &.{});

    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("[]", out.items);
}

test "writeChromeTraceJson escapes special characters in zone name" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);

    const events = [_]Event{
        .{ .name = "a\"b\\c", .ts = 1, .tid = 0, .ph = .begin },
    };
    try writeChromeTraceJson(&aw.writer, &events);

    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);
    // The name a"b\c must be JSON-escaped to a\"b\\c inside the JSON string.
    const expected = "[{\"name\":\"a\\\"b\\\\c\",\"ph\":\"B\",\"ts\":1,\"pid\":0,\"tid\":0}]";
    try testing.expectEqualStrings(expected, out.items);
}

test "EnabledTrace recordCounter is stored and exported with ph C" {
    var t = try EnabledTrace.init(testing.allocator, 4);
    defer t.deinit();

    try t.recordCounter("fps", 1000, 2, 60);

    try testing.expectEqual(@as(usize, 1), t.events.items.len);

    // Export must contain the "C" phase marker.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    try t.writeChromeTraceJson(&aw.writer);
    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, out.items, "\"ph\":\"C\"") != null);
}

test "DisabledTrace recordCounter is a no-op and export is still []" {
    var t = try DisabledTrace.init(testing.allocator, 4);
    defer t.deinit();

    // recordCounter on DisabledTrace must not error.
    try t.recordCounter("fps", 1000, 1, 60);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    try t.writeChromeTraceJson(&aw.writer);
    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);

    try testing.expectEqualStrings("[]", out.items);
}

test "EnabledTrace mixed zone and counter events export correct JSON array" {
    var t = try EnabledTrace.init(testing.allocator, 4);
    defer t.deinit();

    const tok = try t.beginZone("frame", 0, 1);
    try t.recordCounter("triangles", 50, 1, 42_000);
    try t.endZone(tok, 100);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    try t.writeChromeTraceJson(&aw.writer);
    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);

    const json = out.items;

    try testing.expect(json.len >= 2);
    try testing.expectEqual('[', json[0]);
    try testing.expectEqual(']', json[json.len - 1]);

    // All three event kinds must appear in the output.
    try testing.expect(std.mem.indexOf(u8, json, "\"ph\":\"B\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ph\":\"C\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ph\":\"E\"") != null);
}

test "EnabledTrace zone pairing: balanced begin/end does not assert at deinit" {
    // Goal: verify that a correctly paired begin/end sequence leaves zone_depth at zero,
    // so that deinit's balance assertion does not fire.
    // Method: call beginZone then endZone and let defer run deinit.
    var t = try EnabledTrace.init(testing.allocator, 16);
    defer t.deinit();

    const tok = try t.beginZone("work", 100, 1);
    try t.endZone(tok, 200);
    // Postcondition: depth is back to zero after the matching end.
    try testing.expectEqual(@as(u32, 0), t.zone_depth);
}

test "EnabledTrace zone pairing: multiple nested zones balance correctly" {
    // Goal: verify that nested begin/end pairs each decrement depth exactly once.
    // Method: open two zones, close both, assert depth returns to zero.
    var t = try EnabledTrace.init(testing.allocator, 16);
    defer t.deinit();

    const tok_outer = try t.beginZone("outer", 0, 1);
    const tok_inner = try t.beginZone("inner", 10, 1);
    try t.endZone(tok_inner, 20);
    try t.endZone(tok_outer, 30);
    try testing.expectEqual(@as(u32, 0), t.zone_depth);
}

test "EnabledTrace stress: random event sequences produce valid JSON and do not crash" {
    // Property test with a fixed seed for reproducibility.
    // Invariants under test:
    //   1. Export never crashes regardless of event sequence or buffer fill level.
    //   2. JSON output always starts with '[' and ends with ']' (structurally valid).
    const a = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xc0ffee00_baadf00d);
    const random = prng.random();

    const trial_count: usize = 32;
    var trial: usize = 0;
    while (trial < trial_count) : (trial += 1) {
        // max_events in [1..32]; never 0 (0 returns InvalidConfig, tested separately).
        const max_events: usize = 1 + random.uintLessThan(usize, 32);
        var t = try EnabledTrace.init(a, max_events);
        defer t.deinit();

        // Issue balanced begin/end zone pairs until the buffer is full.
        // We only start a pair when there is space for both events, so zone_depth
        // is always zero at iteration end and deinit's balance assertion holds.
        // Pairs per trial: floor(max_events / 2), covering the exact boundary case.
        const pairs = max_events / 2;
        var call_count: usize = 0;
        while (call_count < pairs) : (call_count += 1) {
            const tok = t.beginZone("zone", @as(u64, call_count) * 2, 1) catch |err| switch (err) {
                error.NoSpaceLeft => break,
                else => return err,
            };
            try t.endZone(tok, @as(u64, call_count) * 2 + 1);
        }

        var aw: std.Io.Writer.Allocating = .init(a);
        try t.writeChromeTraceJson(&aw.writer);
        var out = aw.toArrayList();
        defer out.deinit(a);

        const json = out.items;

        // Invariant 1: output is at minimum "[]" — two bytes.
        try testing.expect(json.len >= 2);

        // Invariant 2: structural JSON array delimiters present.
        try testing.expectEqual('[', json[0]);
        try testing.expectEqual(']', json[json.len - 1]);
    }
}
