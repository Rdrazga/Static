//! Shared endpoint conversion helpers for native socket-address adapters.

const std = @import("std");
const testing = std.testing;
const static_net = @import("static_net");

pub const Endpoint = static_net.Endpoint;

/// Returns the host-order IPv4 address assembled from endpoint octets.
pub fn ipv4HostAddrFromOctets(octets: [4]u8) u32 {
    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        @as(u32, octets[3]);
}

/// Returns the network-order IPv4 address assembled from endpoint octets.
pub fn ipv4AddrBigEndian(octets: [4]u8) u32 {
    const host_addr = ipv4HostAddrFromOctets(octets);
    return std.mem.nativeToBig(u32, host_addr);
}

/// Reconstructs an endpoint from a network-order IPv4 address and port.
pub fn endpointFromIpv4(port_be: u16, addr_be: u32) Endpoint {
    const host_addr = std.mem.bigToNative(u32, addr_be);
    const octets: [4]u8 = .{
        @intCast((host_addr >> 24) & 0xFF),
        @intCast((host_addr >> 16) & 0xFF),
        @intCast((host_addr >> 8) & 0xFF),
        @intCast(host_addr & 0xFF),
    };
    return .{ .ipv4 = .{
        .address = .{ .octets = octets },
        .port = std.mem.bigToNative(u16, port_be),
    } };
}

/// Returns the network-order IPv6 byte layout for endpoint segments.
pub fn ipv6BytesFromSegments(segments: [8]u16) [16]u8 {
    var bytes: [16]u8 = undefined;
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        const segment = segments[index];
        bytes[index * 2] = @intCast((segment >> 8) & 0xFF);
        bytes[index * 2 + 1] = @intCast(segment & 0xFF);
    }
    return bytes;
}

/// Reconstructs IPv6 segments from the network-order byte layout.
pub fn ipv6SegmentsFromBytes(bytes: [16]u8) [8]u16 {
    var segments: [8]u16 = [_]u16{0} ** 8;
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        const hi = bytes[index * 2];
        const lo = bytes[index * 2 + 1];
        segments[index] = (@as(u16, hi) << 8) | @as(u16, lo);
    }
    return segments;
}

/// Reconstructs an endpoint from a network-order IPv6 address and port.
pub fn endpointFromIpv6(port_be: u16, bytes: [16]u8) Endpoint {
    return .{ .ipv6 = .{
        .address = .{ .segments = ipv6SegmentsFromBytes(bytes) },
        .port = std.mem.bigToNative(u16, port_be),
    } };
}

test "ipv4 helper round trips byte layout" {
    const endpoint = Endpoint{ .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 4040,
    } };
    const addr_be = ipv4AddrBigEndian(endpoint.ipv4.address.octets);
    const roundtrip = endpointFromIpv4(std.mem.nativeToBig(u16, endpoint.ipv4.port), addr_be);
    try testing.expectEqualDeep(endpoint, roundtrip);
}

test "ipv6 helper round trips byte layout" {
    const endpoint = Endpoint{ .ipv6 = .{
        .address = .{ .segments = .{ 0x2001, 0x0db8, 0, 1, 0, 0, 0, 2 } },
        .port = 5050,
    } };
    const bytes = ipv6BytesFromSegments(endpoint.ipv6.address.segments);
    const roundtrip = endpointFromIpv6(std.mem.nativeToBig(u16, endpoint.ipv6.port), bytes);
    try testing.expectEqualDeep(endpoint, roundtrip);
}
