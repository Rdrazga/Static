//! Tiny `static_io`-backed process-boundary helper used by package integration tests.

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const static_io = @import("static_io");
const testing = @import("static_testing");

const mode_runtime_retry_echo = "runtime_retry_echo";
const mode_runtime_malformed_stderr = "runtime_malformed_stderr";
const payload_max: usize = 512;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.skip();
    const mode = args.next() orelse return error.InvalidArgs;
    assert(mode.len != 0);

    const stdin_file = init.preopens.get("stdin").?.file;
    const stdout_file = init.preopens.get("stdout").?.file;
    const stderr_file = init.preopens.get("stderr").?.file;
    var stdin_buffer: [256]u8 = undefined;
    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdin_reader = stdin_file.reader(init.io, &stdin_buffer);
    var stdout_writer = stdout_file.writer(init.io, &stdout_buffer);
    var stderr_writer = stderr_file.writer(init.io, &stderr_buffer);
    defer stdout_writer.interface.flush() catch |err| {
        panic("driver_runtime_echo stdout flush failed: {s}", .{@errorName(err)});
    };
    defer stderr_writer.interface.flush() catch |err| {
        panic("driver_runtime_echo stderr flush failed: {s}", .{@errorName(err)});
    };

    while (true) {
        const header = try readRequestHeader(&stdin_reader.interface);
        if (header.payload_len > payload_max) return error.NoSpaceLeft;

        var payload_storage: [payload_max]u8 = undefined;
        const payload = payload_storage[0..header.payload_len];
        try stdin_reader.interface.readSliceAll(payload);

        if (header.kind == .shutdown) {
            try emitResponse(&stdout_writer.interface, .{
                .kind = .ok,
                .request_id = header.request_id,
                .payload_len = 0,
            }, &.{});
            try stdout_writer.interface.flush();
            return;
        }

        if (std.mem.eql(u8, mode, mode_runtime_retry_echo)) {
            try handleRuntimeRetryEcho(init.gpa, &stdout_writer.interface, header.request_id, payload);
            try stdout_writer.interface.flush();
            continue;
        }

        if (std.mem.eql(u8, mode, mode_runtime_malformed_stderr)) {
            try runRuntimePreflight(init.gpa);
            try stderr_writer.interface.writeAll("runtime child emitted malformed response\n");
            try stderr_writer.interface.flush();
            try emitMalformedResponse(&stdout_writer.interface);
            try stdout_writer.interface.flush();
            return;
        }

        return error.InvalidArgs;
    }
}

fn handleRuntimeRetryEcho(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    request_id: u32,
    payload: []const u8,
) !void {
    assert(request_id != 0);
    assert(payload.len <= payload_max);

    var pool = try static_io.BufferPool.init(allocator, .{
        .buffer_size = payload_max,
        .capacity = 3,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(allocator, static_io.RuntimeConfig.initForTest(4));
    defer runtime.deinit();

    const stream = try connectRuntimeStream(&runtime);
    defer runtime.closeHandle(stream.handle) catch |err| {
        assert(err == error.Closed);
    };

    const timeout_buffer = try pool.acquire();
    const timeout_id = try runtime.submitStreamRead(stream, timeout_buffer, 0);
    _ = try runtime.pump(1);
    const timeout_completion = runtime.poll() orelse return error.MissingCompletion;
    if (timeout_completion.operation_id != timeout_id) return error.NonDeterministicOrdering;
    if (timeout_completion.status != .timeout) return error.UnexpectedCompletionStatus;
    try pool.release(timeout_completion.buffer);

    var write_buffer = try pool.acquire();
    @memcpy(write_buffer.bytes[0..payload.len], payload);
    try write_buffer.setUsedLen(@intCast(payload.len));
    const write_id = try runtime.submitStreamWrite(stream, write_buffer, null);
    _ = try runtime.pump(1);
    const write_completion = runtime.poll() orelse return error.MissingCompletion;
    if (write_completion.operation_id != write_id) return error.NonDeterministicOrdering;
    if (write_completion.status != .success) return error.UnexpectedCompletionStatus;
    try pool.release(write_completion.buffer);

    const read_buffer = try pool.acquire();
    const read_id = try runtime.submitStreamRead(stream, read_buffer, null);
    _ = try runtime.pump(1);
    const read_completion = runtime.poll() orelse return error.MissingCompletion;
    defer pool.release(read_completion.buffer) catch unreachable;
    if (read_completion.operation_id != read_id) return error.NonDeterministicOrdering;
    if (read_completion.status != .success) return error.UnexpectedCompletionStatus;
    try emitResponse(writer, .{
        .kind = .ok,
        .request_id = request_id,
        .payload_len = @intCast(read_completion.buffer.usedSlice().len),
    }, read_completion.buffer.usedSlice());
}

fn connectRuntimeStream(runtime: *static_io.Runtime) !static_io.types.Stream {
    const endpoint = static_io.Endpoint{
        .ipv4 = .{
            .address = .init(127, 0, 0, 1),
            .port = 9011,
        },
    };
    const connect_id = try runtime.submitConnect(endpoint, null);
    _ = try runtime.pump(1);
    const completion = runtime.poll() orelse return error.MissingCompletion;
    if (completion.operation_id != connect_id) return error.NonDeterministicOrdering;
    if (completion.status != .success) return error.UnexpectedCompletionStatus;
    assert(completion.handle != null);
    return .{ .handle = completion.handle.? };
}

fn runRuntimePreflight(allocator: std.mem.Allocator) !void {
    var pool = try static_io.BufferPool.init(allocator, .{
        .buffer_size = 32,
        .capacity = 1,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(allocator, static_io.RuntimeConfig.initForTest(2));
    defer runtime.deinit();

    const stream = try connectRuntimeStream(&runtime);
    defer runtime.closeHandle(stream.handle) catch |err| {
        assert(err == error.Closed);
    };

    const buffer = try pool.acquire();
    const timeout_id = try runtime.submitStreamRead(stream, buffer, 0);
    _ = try runtime.pump(1);
    const completion = runtime.poll() orelse return error.MissingCompletion;
    if (completion.operation_id != timeout_id) return error.NonDeterministicOrdering;
    if (completion.status != .timeout) return error.UnexpectedCompletionStatus;
    try pool.release(completion.buffer);
    assert(pool.available() == pool.capacity());
}

fn readRequestHeader(reader: *std.Io.Reader) !testing.testing.driver_protocol.DriverRequestHeader {
    var header_bytes: [testing.testing.driver_protocol.request_header_size_bytes]u8 = undefined;
    try reader.readSliceAll(&header_bytes);
    return testing.testing.driver_protocol.decodeRequestHeader(&header_bytes);
}

fn emitResponse(
    writer: *std.Io.Writer,
    header: testing.testing.driver_protocol.DriverResponseHeader,
    payload: []const u8,
) !void {
    assert(header.payload_len == payload.len);
    assert(payload.len <= payload_max);

    var header_bytes: [testing.testing.driver_protocol.response_header_size_bytes]u8 = undefined;
    _ = try testing.testing.driver_protocol.encodeResponseHeader(&header_bytes, header);
    try writer.writeAll(&header_bytes);
    try writer.writeAll(payload);
}

fn emitMalformedResponse(writer: *std.Io.Writer) !void {
    var header_bytes: [testing.testing.driver_protocol.response_header_size_bytes]u8 = undefined;
    _ = try testing.testing.driver_protocol.encodeResponseHeader(&header_bytes, .{
        .kind = .ok,
        .request_id = 99,
        .payload_len = 0,
    });
    std.mem.writeInt(u16, header_bytes[4..6], 9, .little);
    try writer.writeAll(&header_bytes);
}
