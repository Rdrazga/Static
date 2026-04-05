//! Endpoint value types (`address + port`) for IP transports.
//!
//! This module is syscall-free. It only parses, validates, and formats endpoint
//! literals for higher-level packages.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const address = @import("address.zig");
const errors = @import("errors.zig");

pub const Port = u16;

pub const Ipv4Endpoint = struct {
    address: address.Ipv4Address,
    port: Port,

    pub const static_name: []const u8 = "static.net.Ipv4Endpoint";
    pub const static_version: u32 = 1;

    pub fn init(ipv4: address.Ipv4Address, port: Port) Ipv4Endpoint {
        return .{
            .address = ipv4,
            .port = port,
        };
    }

    pub fn parseLiteral(text: []const u8) errors.EndpointParseError!Ipv4Endpoint {
        const colon_index = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidInput;
        if (colon_index == 0) return error.InvalidInput;
        if (text[0] == '[') return error.InvalidInput;

        const address_text = text[0..colon_index];
        const port_text = text[colon_index + 1 ..];
        const ipv4 = try address.Ipv4Address.parse(address_text);
        const port = try parsePort(port_text);
        return .{
            .address = ipv4,
            .port = port,
        };
    }

    pub fn format(self: Ipv4Endpoint, out: []u8) errors.EndpointFormatError![]const u8 {
        var cursor: usize = 0;

        const address_text = try self.address.format(out[cursor..]);
        cursor += address_text.len;
        try appendByte(out, &cursor, ':');
        try appendPort(out, &cursor, self.port);
        return out[0..cursor];
    }
};

pub const Ipv6Endpoint = struct {
    address: address.Ipv6Address,
    port: Port,

    pub const static_name: []const u8 = "static.net.Ipv6Endpoint";
    pub const static_version: u32 = 1;

    pub fn init(ipv6: address.Ipv6Address, port: Port) Ipv6Endpoint {
        return .{
            .address = ipv6,
            .port = port,
        };
    }

    pub fn parseLiteral(text: []const u8) errors.EndpointParseError!Ipv6Endpoint {
        if (text.len < 4) return error.InvalidInput;
        if (text[0] != '[') return error.InvalidInput;

        const close_index = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidInput;
        if (close_index <= 1) return error.InvalidInput;
        if (close_index + 2 > text.len) return error.InvalidInput;
        if (text[close_index + 1] != ':') return error.InvalidInput;

        const address_text = text[1..close_index];
        const port_text = text[close_index + 2 ..];
        const ipv6 = try address.Ipv6Address.parse(address_text);
        const port = try parsePort(port_text);
        return .{
            .address = ipv6,
            .port = port,
        };
    }

    pub fn format(self: Ipv6Endpoint, out: []u8) errors.EndpointFormatError![]const u8 {
        var cursor: usize = 0;
        try appendByte(out, &cursor, '[');

        const address_text = try self.address.format(out[cursor..]);
        cursor += address_text.len;

        try appendByte(out, &cursor, ']');
        try appendByte(out, &cursor, ':');
        try appendPort(out, &cursor, self.port);
        return out[0..cursor];
    }
};

pub const Endpoint = union(enum) {
    ipv4: Ipv4Endpoint,
    ipv6: Ipv6Endpoint,

    pub const static_name: []const u8 = "static.net.Endpoint";
    pub const static_version: u32 = 1;

    pub fn parseLiteral(text: []const u8) errors.EndpointParseError!Endpoint {
        if (text.len == 0) return error.InvalidInput;
        if (text[0] == '[') {
            return .{ .ipv6 = try Ipv6Endpoint.parseLiteral(text) };
        }
        if (std.mem.indexOfScalar(u8, text, '.')) |_| {
            return .{ .ipv4 = try Ipv4Endpoint.parseLiteral(text) };
        }
        return error.InvalidInput;
    }

    pub fn format(self: Endpoint, out: []u8) errors.EndpointFormatError![]const u8 {
        return switch (self) {
            .ipv4 => |ipv4| ipv4.format(out),
            .ipv6 => |ipv6| ipv6.format(out),
        };
    }
};

fn parsePort(text: []const u8) errors.EndpointParseError!Port {
    if (text.len == 0 or text.len > 5) return error.InvalidInput;

    var value: u32 = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte < '0' or byte > '9') return error.InvalidInput;
        value = value * 10 + (byte - '0');
        if (value > std.math.maxInt(u16)) return error.InvalidInput;
    }
    return @intCast(value);
}

fn appendByte(out: []u8, cursor: *usize, byte: u8) errors.EndpointFormatError!void {
    if (cursor.* >= out.len) return error.NoSpaceLeft;
    out[cursor.*] = byte;
    cursor.* += 1;
}

fn appendPort(out: []u8, cursor: *usize, port: Port) errors.EndpointFormatError!void {
    var scratch: [5]u8 = [_]u8{0} ** 5;
    var count: usize = 0;
    var value: u32 = port;

    if (value == 0) {
        scratch[0] = '0';
        count = 1;
    } else {
        while (value > 0) {
            assert(count < scratch.len);
            const digit = @as(u8, @intCast(value % 10));
            scratch[count] = '0' + digit;
            value /= 10;
            count += 1;
        }
    }

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const reverse_index = count - 1 - index;
        try appendByte(out, cursor, scratch[reverse_index]);
    }
}

test "ipv4 endpoint parse and format roundtrip" {
    const parsed = try Ipv4Endpoint.parseLiteral("10.4.7.9:443");
    try testing.expectEqual(@as(u16, 443), parsed.port);
    try testing.expectEqualSlices(u8, &.{ 10, 4, 7, 9 }, &parsed.address.octets);

    var out: [21]u8 = [_]u8{0} ** 21;
    const formatted = try parsed.format(&out);
    try testing.expectEqualStrings("10.4.7.9:443", formatted);
}

test "ipv6 endpoint parse and format roundtrip" {
    const parsed = try Ipv6Endpoint.parseLiteral("[2001:db8::1]:8080");
    try testing.expectEqual(@as(u16, 8080), parsed.port);
    try testing.expectEqual(@as(u16, 0x2001), parsed.address.segments[0]);
    try testing.expectEqual(@as(u16, 0x0db8), parsed.address.segments[1]);
    try testing.expectEqual(@as(u16, 0x0001), parsed.address.segments[7]);

    var out: [47]u8 = [_]u8{0} ** 47;
    const formatted = try parsed.format(&out);
    try testing.expectEqualStrings(
        "[2001:0db8:0000:0000:0000:0000:0000:0001]:8080",
        formatted,
    );
}

test "endpoint parser rejects malformed literals" {
    try testing.expectError(error.InvalidInput, Endpoint.parseLiteral("127.0.0.1"));
    try testing.expectError(error.InvalidInput, Endpoint.parseLiteral("127.0.0.1:70000"));
    try testing.expectError(error.InvalidInput, Endpoint.parseLiteral("[::1:80"));
    try testing.expectError(error.InvalidInput, Endpoint.parseLiteral("::1:80"));
}

test "endpoint parser rejects unsupported IPv6 scope IDs" {
    try testing.expectError(error.Unsupported, Endpoint.parseLiteral("[fe80::1%eth0]:80"));
}

test "endpoint format reports no space left and exact fit succeeds" {
    const endpoint_value = Endpoint{
        .ipv6 = Ipv6Endpoint.init(
            address.Ipv6Address.parse("2001:db8::1") catch unreachable,
            65535,
        ),
    };

    var too_small: [46]u8 = [_]u8{0} ** 46;
    try testing.expectError(error.NoSpaceLeft, endpoint_value.format(&too_small));

    var exact: [47]u8 = [_]u8{0} ** 47;
    const formatted = try endpoint_value.format(&exact);
    try testing.expectEqual(@as(usize, 47), formatted.len);
}
