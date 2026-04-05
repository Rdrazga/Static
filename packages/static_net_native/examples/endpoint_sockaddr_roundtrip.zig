const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const static_net_native = @import("static_net_native");

const Endpoint = static_net_native.Endpoint;

pub fn main() !void {
    const endpoint = Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 7001,
    } };

    const sockaddr_len_bytes: u32 = switch (builtin.os.tag) {
        .windows => roundtripWindows(endpoint),
        .linux => roundtripLinux(endpoint),
        else => roundtripPosix(endpoint),
    };

    std.debug.print("native sockaddr bytes: {}\n", .{sockaddr_len_bytes});
}

fn roundtripWindows(endpoint: Endpoint) u32 {
    const sockaddr = static_net_native.windows.SockaddrAny.fromEndpoint(endpoint);
    const storage: *const std.os.windows.ws2_32.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    const roundtrip = static_net_native.windows.endpointFromStorage(storage);

    assert(roundtrip != null);
    assert(std.meta.eql(endpoint, roundtrip.?));
    return @intCast(sockaddr.len());
}

fn roundtripLinux(endpoint: Endpoint) u32 {
    const sockaddr = static_net_native.linux.SockaddrAny.fromEndpoint(endpoint);
    const storage: *const std.os.linux.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    const roundtrip = static_net_native.linux.endpointFromStorage(storage);

    assert(roundtrip != null);
    assert(std.meta.eql(endpoint, roundtrip.?));
    return @intCast(sockaddr.len());
}

fn roundtripPosix(endpoint: Endpoint) u32 {
    const sockaddr = static_net_native.posix.SockaddrAny.fromEndpoint(endpoint);
    const storage: *const std.posix.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    const roundtrip = static_net_native.posix.endpointFromStorage(storage);

    assert(roundtrip != null);
    assert(std.meta.eql(endpoint, roundtrip.?));
    return @intCast(sockaddr.len());
}
