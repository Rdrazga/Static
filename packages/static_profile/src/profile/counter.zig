//! Named integer counters with Chrome trace "C" phase export.
//!
//! Counters are distinct from zones (Begin/End pairs) and from histograms.
//! They represent instantaneous integer values at a timestamp, matching the
//! Chrome trace format "C" (Counter) phase event:
//!   {"name":"N","ph":"C","ts":T,"pid":P,"tid":TID,"args":{"value":V}}
//!
//! Counters share the same bounded event buffer with zones so the exported
//! timeline is fully coherent. They are NOT a metrics/histogram system;
//! that omission keeps this module focused on instantaneous trace values
//! rather than aggregate statistics.
//!

const std = @import("std");
const trace = @import("trace.zig");
const writeJsonString = trace.writeJsonString;

pub const Error = trace.Error;

pub const CounterEvent = struct {
    name: []const u8,
    ts: u64,
    tid: u32,
    pid: u32 = 0,
    value: i64,
};

/// Maximum byte length of a counter event name. Names are short identifiers;
/// this bound prevents unbounded JSON output and mirrors writeJsonString's contract.
pub const max_counter_name_len: usize = 256;

/// Write a single Chrome "C" phase counter event as a JSON object.
/// Does not write surrounding commas or array brackets — the caller composes
/// the array. Escapes name using JSON string rules.
pub fn writeCounterEventJson(writer: *std.Io.Writer, ev: CounterEvent) !void {
    // Precondition: a counter with an empty name would produce unidentifiable
    // events in the trace. Callers must supply a non-empty name.
    std.debug.assert(ev.name.len > 0);
    // Precondition: name length must not exceed the defined maximum; counter names
    // are short identifiers, not arbitrary strings.
    std.debug.assert(ev.name.len <= max_counter_name_len);
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, ev.name);
    try writer.writeAll(",\"ph\":\"C\",\"ts\":");
    try writer.print("{}", .{ev.ts});
    try writer.writeAll(",\"pid\":");
    try writer.print("{}", .{ev.pid});
    try writer.writeAll(",\"tid\":");
    try writer.print("{}", .{ev.tid});
    try writer.writeAll(",\"args\":{\"value\":");
    try writer.print("{}", .{ev.value});
    try writer.writeAll("}}");
}

test "writeCounterEventJson produces valid Chrome C phase JSON" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    const ev = CounterEvent{ .name = "fps", .ts = 1000, .tid = 2, .pid = 0, .value = 60 };
    try writeCounterEventJson(&aw.writer, ev);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    const expected = "{\"name\":\"fps\",\"ph\":\"C\",\"ts\":1000,\"pid\":0,\"tid\":2,\"args\":{\"value\":60}}";
    try std.testing.expectEqualStrings(expected, out.items);
}

test "writeCounterEventJson handles negative counter values" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    const ev = CounterEvent{ .name = "delta", .ts = 500, .tid = 1, .pid = 0, .value = -42 };
    try writeCounterEventJson(&aw.writer, ev);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "-42") != null);
}

test "writeCounterEventJson escapes special characters in name" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    const ev = CounterEvent{ .name = "a\"b", .ts = 1, .tid = 0, .pid = 0, .value = 1 };
    try writeCounterEventJson(&aw.writer, ev);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\\\"") != null);
}
