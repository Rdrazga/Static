//! Demonstrates one request/response exchange over the process-driver protocol.

const builtin = @import("builtin");
const std = @import("std");
const testing = @import("static_testing");
const example_options = @import("static_testing_example_options");

pub fn main() !void {
    if (builtin.os.tag == .wasi) return;

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const argv = [_][]const u8{ example_options.driver_echo_path, "echo" };
    var driver = try testing.testing.process_driver.ProcessDriver.start(threaded_io.io(), .{
        .argv = &argv,
        .timeout_ns_max = 500 * std.time.ns_per_ms,
    });
    defer driver.deinit();

    const request_id = try driver.sendRequest(.echo, "hello");
    var payload_buffer: [16]u8 = undefined;
    const response = try driver.recvResponse(&payload_buffer);

    std.debug.assert(response.header.request_id == request_id);
    std.debug.assert(response.header.kind == .ok);
    std.debug.assert(std.mem.eql(u8, response.payload, "hello"));
    try driver.shutdown();
}
