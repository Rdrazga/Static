//! POSIX-native endpoint adapters.

const std = @import("std");
const testing = std.testing;
const common = @import("common.zig");

pub const Endpoint = common.Endpoint;

const posix = std.posix;

/// Bounded POSIX socket-address storage for one endpoint.
pub const SockaddrAny = union(enum) {
    ipv4: posix.sockaddr.in,
    ipv6: posix.sockaddr.in6,

    /// Converts an endpoint into the matching POSIX socket-address layout.
    pub fn fromEndpoint(endpoint: Endpoint) SockaddrAny {
        return switch (endpoint) {
            .ipv4 => |ipv4| .{ .ipv4 = .{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, ipv4.port),
                .addr = common.ipv4AddrBigEndian(ipv4.address.octets),
                .zero = [_]u8{0} ** 8,
            } },
            .ipv6 => |ipv6| .{ .ipv6 = .{
                .family = posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, ipv6.port),
                .flowinfo = 0,
                .addr = common.ipv6BytesFromSegments(ipv6.address.segments),
                .scope_id = 0,
            } },
        };
    }

    /// Returns the base socket-address pointer for syscall submission.
    pub fn ptr(self: *const SockaddrAny) *const posix.sockaddr {
        return switch (self.*) {
            .ipv4 => @ptrCast(&self.ipv4),
            .ipv6 => @ptrCast(&self.ipv6),
        };
    }

    /// Returns the active socket-address byte length for syscall submission.
    pub fn len(self: *const SockaddrAny) posix.socklen_t {
        return switch (self.*) {
            .ipv4 => @sizeOf(posix.sockaddr.in),
            .ipv6 => @sizeOf(posix.sockaddr.in6),
        };
    }
};

/// Parses a POSIX socket-address storage record into an endpoint.
pub fn endpointFromStorage(storage: *const posix.sockaddr.storage) ?Endpoint {
    switch (storage.family) {
        posix.AF.INET => {
            const addr: *const posix.sockaddr.in = @ptrCast(@alignCast(storage));
            return common.endpointFromIpv4(addr.port, addr.addr);
        },
        posix.AF.INET6 => {
            const addr6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(storage));
            return common.endpointFromIpv6(addr6.port, addr6.addr);
        },
        else => return null,
    }
}

/// Returns the current local endpoint for a socket, or `null` on syscall failure.
pub fn socketLocalEndpoint(fd: posix.fd_t) ?Endpoint {
    var storage: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @intCast(@sizeOf(posix.sockaddr.storage));
    const rc = posix.system.getsockname(fd, @ptrCast(&storage), &len);
    if (posix.errno(rc) != .SUCCESS) return null;
    return endpointFromStorage(&storage);
}

/// Returns the current peer endpoint for a socket, or `null` on syscall failure.
pub fn socketPeerEndpoint(fd: posix.fd_t) ?Endpoint {
    var storage: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @intCast(@sizeOf(posix.sockaddr.storage));
    const rc = posix.system.getpeername(fd, @ptrCast(&storage), &len);
    if (posix.errno(rc) != .SUCCESS) return null;
    return endpointFromStorage(&storage);
}

test "posix sockaddr ipv4 round trips through storage" {
    const endpoint = Endpoint{ .ipv4 = .{
        .address = .init(192, 168, 1, 12),
        .port = 8080,
    } };
    const sockaddr = SockaddrAny.fromEndpoint(endpoint);
    const storage: *const posix.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    try testing.expectEqualDeep(endpoint, endpointFromStorage(storage).?);
}

test "posix sockaddr ipv6 round trips through storage" {
    const endpoint = Endpoint{ .ipv6 = .{
        .address = .{ .segments = .{ 0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x1234 } },
        .port = 443,
    } };
    const sockaddr = SockaddrAny.fromEndpoint(endpoint);
    const storage: *const posix.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    try testing.expectEqualDeep(endpoint, endpointFromStorage(storage).?);
}

test "posix storage rejects unsupported family" {
    var storage = std.mem.zeroes(posix.sockaddr.storage);
    storage.family = 0;

    try testing.expect(endpointFromStorage(&storage) == null);
}
