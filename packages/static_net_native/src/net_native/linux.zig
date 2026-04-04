//! Linux-native endpoint adapters.

const std = @import("std");
const common = @import("common.zig");

pub const Endpoint = common.Endpoint;

const linux = std.os.linux;

/// Bounded Linux socket-address storage for one endpoint.
pub const SockaddrAny = union(enum) {
    ipv4: linux.sockaddr.in,
    ipv6: linux.sockaddr.in6,

    /// Converts an endpoint into the matching Linux socket-address layout.
    pub fn fromEndpoint(endpoint: Endpoint) SockaddrAny {
        return switch (endpoint) {
            .ipv4 => |ipv4| .{ .ipv4 = .{
                .family = linux.AF.INET,
                .port = std.mem.nativeToBig(u16, ipv4.port),
                .addr = common.ipv4AddrBigEndian(ipv4.address.octets),
                .zero = [_]u8{0} ** 8,
            } },
            .ipv6 => |ipv6| .{ .ipv6 = .{
                .family = linux.AF.INET6,
                .port = std.mem.nativeToBig(u16, ipv6.port),
                .flowinfo = 0,
                .addr = common.ipv6BytesFromSegments(ipv6.address.segments),
                .scope_id = 0,
            } },
        };
    }

    /// Returns the base socket-address pointer for syscall submission.
    pub fn ptr(self: *const SockaddrAny) *const linux.sockaddr {
        return switch (self.*) {
            .ipv4 => @ptrCast(&self.ipv4),
            .ipv6 => @ptrCast(&self.ipv6),
        };
    }

    /// Returns the active socket-address byte length for syscall submission.
    pub fn len(self: *const SockaddrAny) linux.socklen_t {
        return switch (self.*) {
            .ipv4 => @sizeOf(linux.sockaddr.in),
            .ipv6 => @sizeOf(linux.sockaddr.in6),
        };
    }
};

/// Parses a Linux socket-address storage record into an endpoint.
pub fn endpointFromStorage(storage: *const linux.sockaddr.storage) ?Endpoint {
    switch (storage.family) {
        linux.AF.INET => {
            const addr: *const linux.sockaddr.in = @ptrCast(@alignCast(storage));
            return common.endpointFromIpv4(addr.port, addr.addr);
        },
        linux.AF.INET6 => {
            const addr6: *const linux.sockaddr.in6 = @ptrCast(@alignCast(storage));
            return common.endpointFromIpv6(addr6.port, addr6.addr);
        },
        else => return null,
    }
}

/// Returns the current local endpoint for a socket, or `null` on syscall failure.
pub fn socketLocalEndpoint(fd: std.posix.fd_t) ?Endpoint {
    var storage: linux.sockaddr.storage = undefined;
    var len: linux.socklen_t = @intCast(@sizeOf(linux.sockaddr.storage));
    const rc = std.posix.system.getsockname(fd, @ptrCast(&storage), &len);
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return endpointFromStorage(&storage);
}

test "linux sockaddr ipv4 round trips through storage" {
    const endpoint = Endpoint{ .ipv4 = .{
        .address = .init(172, 16, 1, 9),
        .port = 3210,
    } };
    const sockaddr = SockaddrAny.fromEndpoint(endpoint);
    const storage: *const linux.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    try std.testing.expectEqualDeep(endpoint, endpointFromStorage(storage).?);
}

test "linux sockaddr ipv6 round trips through storage" {
    const endpoint = Endpoint{ .ipv6 = .{
        .address = .{ .segments = .{ 0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111 } },
        .port = 80,
    } };
    const sockaddr = SockaddrAny.fromEndpoint(endpoint);
    const storage: *const linux.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    try std.testing.expectEqualDeep(endpoint, endpointFromStorage(storage).?);
}

test "linux storage rejects unsupported family" {
    var storage = std.mem.zeroes(linux.sockaddr.storage);
    storage.family = 0;

    try std.testing.expect(endpointFromStorage(&storage) == null);
}
