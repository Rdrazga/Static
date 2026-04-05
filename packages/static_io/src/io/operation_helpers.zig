//! Shared operation validation and completion helpers for `static_io` backends.
//!
//! Capacity: not applicable.
//! Thread safety: pure functions only.
//! Blocking behavior: non-blocking, aside from monotonic clock reads in `elapsedSince`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const backend = @import("backend.zig");
const types = @import("types.zig");

pub const TargetHandles = struct {
    a: ?types.Handle = null,
    b: ?types.Handle = null,
};

pub fn validateOperation(op: types.Operation) backend.SubmitError!types.Operation {
    return switch (op) {
        .nop => |buffer| {
            if (!isBufferValid(buffer)) return error.InvalidInput;
            return .{ .nop = buffer };
        },
        .fill => |fill| {
            if (!isBufferValid(fill.buffer)) return error.InvalidInput;
            if (fill.len > fill.buffer.bytes.len) return error.InvalidInput;
            return .{ .fill = fill };
        },
        .file_read_at => |file_op| {
            if (!isBufferValid(file_op.buffer)) return error.InvalidInput;
            return .{ .file_read_at = file_op };
        },
        .file_write_at => |file_op| {
            if (!isWriteBufferValid(file_op.buffer)) return error.InvalidInput;
            return .{ .file_write_at = file_op };
        },
        .stream_read => |stream_op| {
            if (!isReadBufferValid(stream_op.buffer)) return error.InvalidInput;
            return .{ .stream_read = stream_op };
        },
        .stream_write => |stream_op| {
            if (!isWriteBufferValid(stream_op.buffer)) return error.InvalidInput;
            return .{ .stream_write = stream_op };
        },
        .accept => |accept_op| return .{ .accept = accept_op },
        .connect => |connect_op| {
            if (endpointPort(connect_op.endpoint) == 0) return error.InvalidInput;
            return .{ .connect = connect_op };
        },
    };
}

pub fn makeSimpleCompletion(
    operation_id: types.OperationId,
    operation: types.Operation,
    status: types.CompletionStatus,
    err_tag: types.CompletionErrorTag,
) types.Completion {
    return .{
        .operation_id = operation_id,
        .tag = operationTag(operation),
        .status = status,
        .bytes_transferred = 0,
        .buffer = operationBuffer(operation),
        .err = err_tag,
        .handle = completionHandle(operation),
        .endpoint = completionEndpoint(operation),
    };
}

pub fn operationTimeoutNs(operation: types.Operation) ?u64 {
    return switch (operation) {
        .nop, .fill => null,
        .stream_read => |op| op.timeout_ns,
        .stream_write => |op| op.timeout_ns,
        .accept => |op| op.timeout_ns,
        .connect => |op| op.timeout_ns,
        .file_read_at => |op| op.timeout_ns,
        .file_write_at => |op| op.timeout_ns,
    };
}

pub fn operationHasFiniteTimeout(operation: types.Operation) bool {
    const timeout_ns = operationTimeoutNs(operation) orelse return false;
    return timeout_ns != 0;
}

pub fn operationHasImmediateTimeout(operation: types.Operation) bool {
    const timeout_ns = operationTimeoutNs(operation) orelse return false;
    return timeout_ns == 0;
}

pub fn operationTargetHandles(operation: types.Operation) TargetHandles {
    return switch (operation) {
        .nop, .fill => .{},
        .stream_read => |op| .{ .a = op.stream.handle },
        .stream_write => |op| .{ .a = op.stream.handle },
        .accept => |op| .{ .a = op.listener.handle, .b = op.stream.handle },
        .connect => |op| .{ .a = op.stream.handle },
        .file_read_at => |op| .{ .a = op.file.handle },
        .file_write_at => |op| .{ .a = op.file.handle },
    };
}

pub fn operationUsesHandle(operation: types.Operation, handle: types.Handle) bool {
    assert(handle.isValid());
    const targets = operationTargetHandles(operation);
    return targets.a == handle or targets.b == handle;
}

pub fn elapsedSince(start: std.time.Instant) ?u64 {
    const now = std.time.Instant.now() catch return null;
    return now.since(start);
}

fn isBufferValid(buffer: types.Buffer) bool {
    return buffer.used_len <= buffer.bytes.len;
}

fn isReadBufferValid(buffer: types.Buffer) bool {
    if (buffer.bytes.len == 0) return false;
    return isBufferValid(buffer) and buffer.used_len == 0;
}

fn isWriteBufferValid(buffer: types.Buffer) bool {
    if (buffer.bytes.len == 0) return false;
    return isBufferValid(buffer) and buffer.used_len != 0;
}

fn operationTag(operation: types.Operation) types.OperationTag {
    return switch (operation) {
        .nop => .nop,
        .fill => .fill,
        .stream_read => .stream_read,
        .stream_write => .stream_write,
        .accept => .accept,
        .connect => .connect,
        .file_read_at => .file_read_at,
        .file_write_at => .file_write_at,
    };
}

fn operationBuffer(operation: types.Operation) types.Buffer {
    return switch (operation) {
        .nop => |buffer| buffer,
        .fill => |fill| fill.buffer,
        .stream_read => |op| op.buffer,
        .stream_write => |op| op.buffer,
        .accept, .connect => .{ .bytes = &[_]u8{} },
        .file_read_at => |op| op.buffer,
        .file_write_at => |op| op.buffer,
    };
}

fn completionHandle(operation: types.Operation) ?types.Handle {
    return switch (operation) {
        .stream_read => |op| op.stream.handle,
        .stream_write => |op| op.stream.handle,
        .accept => |op| op.stream.handle,
        .connect => |op| op.stream.handle,
        .file_read_at => |op| op.file.handle,
        .file_write_at => |op| op.file.handle,
        else => null,
    };
}

fn completionEndpoint(operation: types.Operation) ?types.Endpoint {
    return switch (operation) {
        .connect => |op| op.endpoint,
        else => null,
    };
}

fn endpointPort(endpoint: types.Endpoint) u16 {
    return switch (endpoint) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
}

test "validate operation rejects invalid connect endpoint and empty writes" {
    var bytes: [4]u8 = .{ 1, 2, 3, 4 };
    var write_buffer = types.Buffer{ .bytes = &bytes };
    try testing.expectError(
        error.InvalidInput,
        validateOperation(.{ .connect = .{
            .stream = .{ .handle = .{ .index = 1, .generation = 1 } },
            .endpoint = .{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = 0 } },
            .timeout_ns = null,
        } }),
    );
    try testing.expectError(
        error.InvalidInput,
        validateOperation(.{ .stream_write = .{
            .stream = .{ .handle = .{ .index = 1, .generation = 1 } },
            .buffer = write_buffer,
            .timeout_ns = null,
        } }),
    );

    try write_buffer.setUsedLen(4);
    _ = try validateOperation(.{ .stream_write = .{
        .stream = .{ .handle = .{ .index = 1, .generation = 1 } },
        .buffer = write_buffer,
        .timeout_ns = null,
    } });
}

test "simple completion preserves target handle and endpoint metadata" {
    const operation: types.Operation = .{ .connect = .{
        .stream = .{ .handle = .{ .index = 2, .generation = 7 } },
        .endpoint = .{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = 9000 } },
        .timeout_ns = null,
    } };

    const completion = makeSimpleCompletion(11, operation, .timeout, .timeout);
    try testing.expectEqual(@as(types.OperationId, 11), completion.operation_id);
    try testing.expectEqual(types.OperationTag.connect, completion.tag);
    try testing.expectEqual(@as(?types.Handle, .{ .index = 2, .generation = 7 }), completion.handle);
    try testing.expectEqual(@as(?types.Endpoint, .{ .ipv4 = .{ .address = .init(127, 0, 0, 1), .port = 9000 } }), completion.endpoint);
}

test "operation target handles include both accept endpoints" {
    const operation: types.Operation = .{ .accept = .{
        .listener = .{ .handle = .{ .index = 3, .generation = 4 } },
        .stream = .{ .handle = .{ .index = 9, .generation = 5 } },
        .timeout_ns = null,
    } };

    const targets = operationTargetHandles(operation);
    try testing.expectEqual(@as(?types.Handle, .{ .index = 3, .generation = 4 }), targets.a);
    try testing.expectEqual(@as(?types.Handle, .{ .index = 9, .generation = 5 }), targets.b);
    try testing.expect(operationUsesHandle(operation, targets.a.?));
    try testing.expect(operationUsesHandle(operation, targets.b.?));
}
