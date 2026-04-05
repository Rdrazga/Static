//! Demonstrates Chrome-trace JSON export from a bounded deterministic trace.

const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

pub fn main() !void {
    var storage: [2]testing.testing.trace.TraceEvent = undefined;
    var trace_buffer = try testing.testing.trace.TraceBuffer.init(&storage, .{
        .max_events = 2,
        .start_sequence_no = 41,
    });
    try trace_buffer.append(.{
        .timestamp_ns = 10_000,
        .category = .info,
        .label = "boot",
        .value = 1,
    });
    try trace_buffer.append(.{
        .timestamp_ns = 15_000,
        .category = .decision,
        .label = "choose",
        .value = 7,
    });

    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    try trace_buffer.snapshot().writeChromeTraceJson(&aw.writer);
    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);

    assert(std.mem.eql(
        u8,
        out.items,
        "[{\"name\":\"boot\",\"cat\":\"info\",\"ph\":\"i\",\"ts\":10,\"pid\":0,\"tid\":0,\"s\":\"t\",\"args\":{\"seq\":41,\"value\":1}},{\"name\":\"choose\",\"cat\":\"decision\",\"ph\":\"i\",\"ts\":15,\"pid\":0,\"tid\":0,\"s\":\"t\",\"args\":{\"seq\":42,\"value\":7}}]",
    ));
    std.debug.print("{s}\n", .{out.items});
}
