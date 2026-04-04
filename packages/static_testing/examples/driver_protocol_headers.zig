//! Demonstrates raw driver-protocol request and response header round-trips.

const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    var request_bytes: [testing.testing.driver_protocol.request_header_size_bytes]u8 = undefined;
    const request_written = try testing.testing.driver_protocol.encodeRequestHeader(&request_bytes, .{
        .kind = .echo,
        .request_id = 17,
        .payload_len = 5,
    });
    const request_header = try testing.testing.driver_protocol.decodeRequestHeader(
        request_bytes[0..request_written],
    );

    var response_bytes: [testing.testing.driver_protocol.response_header_size_bytes]u8 = undefined;
    const response_written = try testing.testing.driver_protocol.encodeResponseHeader(&response_bytes, .{
        .kind = .ok,
        .request_id = request_header.request_id,
        .payload_len = request_header.payload_len,
    });
    const response_header = try testing.testing.driver_protocol.decodeResponseHeader(
        response_bytes[0..response_written],
    );

    std.debug.assert(request_written == testing.testing.driver_protocol.request_header_size_bytes);
    std.debug.assert(response_written == testing.testing.driver_protocol.response_header_size_bytes);
    std.debug.assert(request_header.kind == .echo);
    std.debug.assert(response_header.kind == .ok);
    std.debug.assert(response_header.request_id == request_header.request_id);
    std.debug.print(
        "protocol request_id={} payload_len={}\n",
        .{ response_header.request_id, response_header.payload_len },
    );
}
