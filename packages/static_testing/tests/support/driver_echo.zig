//! Tiny process-boundary helper used by `static_testing` integration tests.

const std = @import("std");
const testing = @import("static_testing");

const mode_echo = "echo";
const mode_malformed = "malformed";
const mode_malformed_stderr = "malformed_stderr";
const mode_hang_on_shutdown = "hang_on_shutdown";
const payload_max: usize = 512;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.skip();
    const mode = args.next() orelse return error.InvalidArgs;

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
        std.debug.panic("driver_echo stdout flush failed: {s}", .{@errorName(err)});
    };
    defer stderr_writer.interface.flush() catch |err| {
        std.debug.panic("driver_echo stderr flush failed: {s}", .{@errorName(err)});
    };

    if (std.mem.eql(u8, mode, mode_malformed)) {
        try emitMalformedResponse(&stdout_writer.interface);
        return;
    }
    if (std.mem.eql(u8, mode, mode_malformed_stderr)) {
        try stderr_writer.interface.writeAll("driver emitted stderr before malformed response\n");
        try stderr_writer.interface.flush();
        try emitMalformedResponse(&stdout_writer.interface);
        return;
    }

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

            if (std.mem.eql(u8, mode, mode_hang_on_shutdown)) {
                try std.Io.Clock.Duration.sleep(.{
                    .clock = .awake,
                    .raw = .fromMilliseconds(10_000),
                }, init.io);
            }
            return;
        }

        if (std.mem.eql(u8, mode, mode_echo)) {
            try emitResponse(&stdout_writer.interface, .{
                .kind = .ok,
                .request_id = header.request_id,
                .payload_len = @as(u32, @intCast(payload.len)),
            }, payload);
            try stdout_writer.interface.flush();
            continue;
        }

        return error.InvalidArgs;
    }
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
