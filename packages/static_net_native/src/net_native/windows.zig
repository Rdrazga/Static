//! Windows-native endpoint adapters.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const common = @import("common.zig");

pub const Endpoint = common.Endpoint;

const windows = std.os.windows;
const af_inet_family: u16 = 2;
const af_inet6_family: u16 = 23;

/// Bounded Windows socket-address storage for one endpoint.
pub const SockaddrAny = union(enum) {
    ipv4: windows.ws2_32.sockaddr.in,
    ipv6: windows.ws2_32.sockaddr.in6,

    /// Converts an endpoint into the matching Windows socket-address layout.
    pub fn fromEndpoint(endpoint: Endpoint) SockaddrAny {
        return switch (endpoint) {
            .ipv4 => |ipv4| .{ .ipv4 = .{
                .family = windows.ws2_32.AF.INET,
                .port = std.mem.nativeToBig(u16, ipv4.port),
                .addr = common.ipv4AddrBigEndian(ipv4.address.octets),
                .zero = [_]u8{0} ** 8,
            } },
            .ipv6 => |ipv6| .{ .ipv6 = .{
                .family = windows.ws2_32.AF.INET6,
                .port = std.mem.nativeToBig(u16, ipv6.port),
                .flowinfo = 0,
                .addr = common.ipv6BytesFromSegments(ipv6.address.segments),
                .scope_id = 0,
            } },
        };
    }

    /// Returns a zero-address socket for the requested address family.
    pub fn anyForFamily(family: i32) SockaddrAny {
        assert(family == windows.ws2_32.AF.INET or family == windows.ws2_32.AF.INET6);
        if (family == windows.ws2_32.AF.INET) {
            return .{ .ipv4 = .{
                .family = windows.ws2_32.AF.INET,
                .port = 0,
                .addr = 0,
                .zero = [_]u8{0} ** 8,
            } };
        }
        return .{ .ipv6 = .{
            .family = windows.ws2_32.AF.INET6,
            .port = 0,
            .flowinfo = 0,
            .addr = [_]u8{0} ** 16,
            .scope_id = 0,
        } };
    }

    /// Returns the base socket-address pointer for syscall submission.
    pub fn ptr(self: *const SockaddrAny) *const windows.ws2_32.sockaddr {
        return switch (self.*) {
            .ipv4 => @ptrCast(&self.ipv4),
            .ipv6 => @ptrCast(&self.ipv6),
        };
    }

    /// Returns the active socket-address byte length for syscall submission.
    pub fn len(self: *const SockaddrAny) i32 {
        return switch (self.*) {
            .ipv4 => @sizeOf(windows.ws2_32.sockaddr.in),
            .ipv6 => @sizeOf(windows.ws2_32.sockaddr.in6),
        };
    }
};

/// Parses a Windows socket-address storage record into an endpoint.
pub fn endpointFromStorage(storage: *const windows.ws2_32.sockaddr.storage) ?Endpoint {
    switch (storage.family) {
        af_inet_family => {
            const addr: *const windows.ws2_32.sockaddr.in = @ptrCast(@alignCast(storage));
            return common.endpointFromIpv4(addr.port, addr.addr);
        },
        af_inet6_family => {
            const addr6: *const windows.ws2_32.sockaddr.in6 = @ptrCast(@alignCast(storage));
            return common.endpointFromIpv6(addr6.port, addr6.addr);
        },
        else => return null,
    }
}

/// Returns the current local endpoint for a socket, or `null` on syscall failure.
pub fn socketLocalEndpoint(sock: windows.ws2_32.SOCKET) ?Endpoint {
    var storage: windows.ws2_32.sockaddr.storage = undefined;
    var len: i32 = @intCast(@sizeOf(windows.ws2_32.sockaddr.storage));
    const rc = windows.ws2_32.getsockname(sock, @ptrCast(&storage), &len);
    if (rc == windows.ws2_32.SOCKET_ERROR) return null;
    return endpointFromStorage(&storage);
}

/// Returns the current peer endpoint for a socket, or `null` on syscall failure.
pub fn socketPeerEndpoint(sock: windows.ws2_32.SOCKET) ?Endpoint {
    var storage: windows.ws2_32.sockaddr.storage = undefined;
    var len: i32 = @intCast(@sizeOf(windows.ws2_32.sockaddr.storage));
    const rc = windows.ws2_32.getpeername(sock, @ptrCast(&storage), &len);
    if (rc == windows.ws2_32.SOCKET_ERROR) return null;
    return endpointFromStorage(&storage);
}

/// Returns the socket family discovered from `getsockname`, or `null` on failure.
pub fn socketFamily(sock: windows.ws2_32.SOCKET) ?i32 {
    var storage: windows.ws2_32.sockaddr.storage = undefined;
    var len: i32 = @intCast(@sizeOf(windows.ws2_32.sockaddr.storage));
    const rc = windows.ws2_32.getsockname(sock, @ptrCast(&storage), &len);
    if (rc == windows.ws2_32.SOCKET_ERROR) return null;
    return @intCast(storage.family);
}

test "windows sockaddr ipv4 round trips through storage" {
    const endpoint = Endpoint{ .ipv4 = .{
        .address = .init(10, 20, 30, 40),
        .port = 9000,
    } };
    const sockaddr = SockaddrAny.fromEndpoint(endpoint);
    const storage: *const windows.ws2_32.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    try testing.expectEqualDeep(endpoint, endpointFromStorage(storage).?);
}

test "windows sockaddr ipv6 round trips through storage" {
    const endpoint = Endpoint{ .ipv6 = .{
        .address = .{ .segments = .{ 0xfe80, 0, 0, 0, 0, 0, 0, 1 } },
        .port = 6553,
    } };
    const sockaddr = SockaddrAny.fromEndpoint(endpoint);
    const storage: *const windows.ws2_32.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    try testing.expectEqualDeep(endpoint, endpointFromStorage(storage).?);
}

test "windows anyForFamily returns zeroed ipv4 storage" {
    const sockaddr = SockaddrAny.anyForFamily(windows.ws2_32.AF.INET);

    try testing.expect(sockaddr == .ipv4);
    try testing.expectEqual(windows.ws2_32.AF.INET, sockaddr.ipv4.family);
    try testing.expectEqual(@as(u16, 0), sockaddr.ipv4.port);
    try testing.expectEqual(@as(u32, 0), sockaddr.ipv4.addr);
    try testing.expectEqualDeep([_]u8{0} ** 8, sockaddr.ipv4.zero);
}

test "windows anyForFamily returns zeroed ipv6 storage" {
    const sockaddr = SockaddrAny.anyForFamily(windows.ws2_32.AF.INET6);

    try testing.expect(sockaddr == .ipv6);
    try testing.expectEqual(windows.ws2_32.AF.INET6, sockaddr.ipv6.family);
    try testing.expectEqual(@as(u16, 0), sockaddr.ipv6.port);
    try testing.expectEqual(@as(u32, 0), sockaddr.ipv6.flowinfo);
    try testing.expectEqualDeep([_]u8{0} ** 16, sockaddr.ipv6.addr);
    try testing.expectEqual(@as(u32, 0), sockaddr.ipv6.scope_id);
}

test "windows storage rejects unsupported family" {
    var storage = std.mem.zeroes(windows.ws2_32.sockaddr.storage);
    storage.family = 0;

    try testing.expect(endpointFromStorage(&storage) == null);
}
