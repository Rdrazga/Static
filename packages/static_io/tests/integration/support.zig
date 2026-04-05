const std = @import("std");
const testing = std.testing;
const static_io = @import("static_io");
const static_testing = @import("static_testing");

const trace = static_testing.testing.trace;
pub fn connectStream(
    runtime: *static_io.Runtime,
    endpoint: static_io.Endpoint,
    context: anytype,
    next_sequence_no: *u32,
) !static_io.types.Stream {
    const connect_id = try runtime.submitConnect(endpoint, null);
    _ = try runtime.pump(1);
    const connect_completion = runtime.poll() orelse return error.MissingCompletion;
    try testing.expectEqual(connect_id, connect_completion.operation_id);
    try testing.expectEqual(static_io.types.CompletionStatus.success, connect_completion.status);
    try testing.expect(connect_completion.handle != null);

    _ = try context.appendTraceEvent(
        next_sequence_no,
        "io.connect.success",
        .check,
        "runtime",
        null,
        connect_completion.operation_id,
    );
    return .{ .handle = connect_completion.handle.? };
}

pub fn appendEvent(
    context: anytype,
    next_sequence_no: *u32,
    label: []const u8,
    category: trace.TraceCategory,
    surface_label: []const u8,
    cause_sequence_no: ?u32,
    value: u64,
) !u32 {
    return context.appendTraceEvent(
        next_sequence_no,
        label,
        category,
        surface_label,
        cause_sequence_no,
        value,
    );
}
