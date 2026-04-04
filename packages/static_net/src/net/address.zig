//! IPv4/IPv6 value types with strict parse and deterministic format contracts.

const std = @import("std");
const errors = @import("errors.zig");

pub const Ipv4Address = struct {
    octets: [4]u8,

    pub const static_name: []const u8 = "static.net.Ipv4Address";
    pub const static_version: u32 = 1;

    pub const any: Ipv4Address = .{ .octets = .{ 0, 0, 0, 0 } };
    pub const loopback: Ipv4Address = .{ .octets = .{ 127, 0, 0, 1 } };
    pub const broadcast: Ipv4Address = .{ .octets = .{ 255, 255, 255, 255 } };

    pub fn init(a: u8, b: u8, c: u8, d: u8) Ipv4Address {
        return .{ .octets = .{ a, b, c, d } };
    }

    pub fn parse(text: []const u8) errors.AddressParseError!Ipv4Address {
        if (text.len < 7 or text.len > 15) return error.InvalidInput;

        var octets: [4]u8 = undefined;
        var octet_count: usize = 0;
        var token_start: usize = 0;
        var index: usize = 0;
        while (index <= text.len) : (index += 1) {
            if (index < text.len and text[index] != '.') continue;

            if (octet_count >= 4) return error.InvalidInput;
            const token = text[token_start..index];
            octets[octet_count] = try parseIpv4Octet(token);
            octet_count += 1;
            token_start = index + 1;
        }

        if (octet_count != 4) return error.InvalidInput;
        return .{ .octets = octets };
    }

    pub fn format(self: Ipv4Address, out: []u8) errors.AddressFormatError![]const u8 {
        var cursor: usize = 0;
        var index: usize = 0;
        while (index < 4) : (index += 1) {
            if (index != 0) try appendByte(out, &cursor, '.');
            try appendDecimalU8(out, &cursor, self.octets[index]);
        }
        return out[0..cursor];
    }
};

pub const Ipv6Address = struct {
    segments: [8]u16,

    pub const static_name: []const u8 = "static.net.Ipv6Address";
    pub const static_version: u32 = 1;

    pub const any: Ipv6Address = .{ .segments = [_]u16{0} ** 8 };
    pub const loopback: Ipv6Address = .{
        .segments = .{ 0, 0, 0, 0, 0, 0, 0, 1 },
    };

    pub fn parse(text: []const u8) errors.AddressParseError!Ipv6Address {
        if (text.len == 0) return error.InvalidInput;
        if (std.mem.indexOfScalar(u8, text, '%') != null) return error.Unsupported;
        if (std.mem.indexOfScalar(u8, text, ':') == null) return error.InvalidInput;

        var segments: [8]u16 = [_]u16{0} ** 8;
        const double_colon = try findDoubleColon(text);
        if (double_colon) |split_at| {
            const left_text = text[0..split_at];
            const right_text = text[split_at + 2 ..];

            var left_segments: [8]u16 = [_]u16{0} ** 8;
            var right_segments: [8]u16 = [_]u16{0} ** 8;

            const left = try parseIpv6Part(left_text, &left_segments, true);
            const right = try parseIpv6Part(right_text, &right_segments, true);

            if (left.uses_ipv4 and right.count != 0) return error.InvalidInput;
            if (left.count + right.count >= 8) return error.InvalidInput;

            const zeros = 8 - (left.count + right.count);
            var out_index: usize = 0;
            var left_index: usize = 0;
            while (left_index < left.count) : (left_index += 1) {
                segments[out_index] = left_segments[left_index];
                out_index += 1;
            }
            var zero_index: usize = 0;
            while (zero_index < zeros) : (zero_index += 1) {
                segments[out_index] = 0;
                out_index += 1;
            }
            var right_index: usize = 0;
            while (right_index < right.count) : (right_index += 1) {
                segments[out_index] = right_segments[right_index];
                out_index += 1;
            }
            std.debug.assert(out_index == 8);
        } else {
            const parsed = try parseIpv6Part(text, &segments, true);
            if (parsed.count != 8) return error.InvalidInput;
        }

        return .{ .segments = segments };
    }

    pub fn format(self: Ipv6Address, out: []u8) errors.AddressFormatError![]const u8 {
        // Canonical package format is full 8-hextet lowercase expansion.
        // This keeps formatting deterministic without relying on compression heuristics.
        const required_len: usize = 39;
        if (out.len < required_len) return error.NoSpaceLeft;

        var cursor: usize = 0;
        var segment_index: usize = 0;
        while (segment_index < 8) : (segment_index += 1) {
            if (segment_index != 0) {
                out[cursor] = ':';
                cursor += 1;
            }
            try appendHexU16Fixed(out, &cursor, self.segments[segment_index]);
        }
        return out[0..cursor];
    }
};

pub const Address = union(enum) {
    ipv4: Ipv4Address,
    ipv6: Ipv6Address,

    pub const static_name: []const u8 = "static.net.Address";
    pub const static_version: u32 = 1;

    pub fn parse(text: []const u8) errors.AddressParseError!Address {
        if (std.mem.indexOfScalar(u8, text, ':') != null) {
            return .{ .ipv6 = try Ipv6Address.parse(text) };
        }
        if (std.mem.indexOfScalar(u8, text, '.') != null) {
            return .{ .ipv4 = try Ipv4Address.parse(text) };
        }
        return error.InvalidInput;
    }

    pub fn format(self: Address, out: []u8) errors.AddressFormatError![]const u8 {
        return switch (self) {
            .ipv4 => |ipv4| ipv4.format(out),
            .ipv6 => |ipv6| ipv6.format(out),
        };
    }
};

const Ipv6PartParse = struct {
    count: usize,
    uses_ipv4: bool,
};

fn parseIpv4Octet(text: []const u8) errors.AddressParseError!u8 {
    if (text.len == 0 or text.len > 3) return error.InvalidInput;
    if (text.len > 1 and text[0] == '0') return error.InvalidInput;

    var value: u16 = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte < '0' or byte > '9') return error.InvalidInput;
        value = value * 10 + (byte - '0');
        if (value > 255) return error.InvalidInput;
    }
    return @intCast(value);
}

fn parseHexU16(text: []const u8) errors.AddressParseError!u16 {
    if (text.len == 0 or text.len > 4) return error.InvalidInput;

    var value: u16 = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        value = value << 4;
        value |= try hexNibble(text[index]);
    }
    return value;
}

fn hexNibble(byte: u8) errors.AddressParseError!u16 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return 10 + (byte - 'a');
    if (byte >= 'A' and byte <= 'F') return 10 + (byte - 'A');
    return error.InvalidInput;
}

fn parseIpv6Part(text: []const u8, out: *[8]u16, allow_ipv4_tail: bool) errors.AddressParseError!Ipv6PartParse {
    if (text.len == 0) {
        return .{
            .count = 0,
            .uses_ipv4 = false,
        };
    }

    var count: usize = 0;
    var uses_ipv4 = false;
    var token_start: usize = 0;
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        const at_end = index == text.len;
        const is_separator = !at_end and text[index] == ':';
        if (!at_end and !is_separator) continue;

        const token = text[token_start..index];
        if (token.len == 0) return error.InvalidInput;
        const is_last_token = at_end;

        if (std.mem.indexOfScalar(u8, token, '.')) |_| {
            if (!allow_ipv4_tail or !is_last_token or uses_ipv4) return error.InvalidInput;
            if (count > 6) return error.InvalidInput;
            const ipv4 = try Ipv4Address.parse(token);
            out[count] = (@as(u16, ipv4.octets[0]) << 8) | @as(u16, ipv4.octets[1]);
            out[count + 1] = (@as(u16, ipv4.octets[2]) << 8) | @as(u16, ipv4.octets[3]);
            count += 2;
            uses_ipv4 = true;
        } else {
            if (count >= 8) return error.InvalidInput;
            out[count] = try parseHexU16(token);
            count += 1;
        }

        token_start = index + 1;
    }

    return .{
        .count = count,
        .uses_ipv4 = uses_ipv4,
    };
}

fn findDoubleColon(text: []const u8) errors.AddressParseError!?usize {
    var result: ?usize = null;
    var index: usize = 0;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] != ':' or text[index + 1] != ':') continue;
        if (result != null) return error.InvalidInput;
        result = index;
        index += 1;
    }
    return result;
}

fn appendByte(out: []u8, cursor: *usize, byte: u8) errors.AddressFormatError!void {
    if (cursor.* >= out.len) return error.NoSpaceLeft;
    out[cursor.*] = byte;
    cursor.* += 1;
}

fn appendDecimalU8(out: []u8, cursor: *usize, value: u8) errors.AddressFormatError!void {
    var scratch: [3]u8 = [_]u8{0} ** 3;
    var count: usize = 0;
    if (value >= 100) {
        scratch[count] = '0' + @as(u8, @intCast(value / 100));
        count += 1;
        scratch[count] = '0' + @as(u8, @intCast((value / 10) % 10));
        count += 1;
        scratch[count] = '0' + (value % 10);
        count += 1;
    } else if (value >= 10) {
        scratch[count] = '0' + @as(u8, @intCast(value / 10));
        count += 1;
        scratch[count] = '0' + (value % 10);
        count += 1;
    } else {
        scratch[count] = '0' + value;
        count += 1;
    }

    var index: usize = 0;
    while (index < count) : (index += 1) {
        try appendByte(out, cursor, scratch[index]);
    }
}

fn appendHexU16Fixed(out: []u8, cursor: *usize, value: u16) errors.AddressFormatError!void {
    const hex = "0123456789abcdef";
    const shifts = [_]u4{ 12, 8, 4, 0 };

    var shift_index: usize = 0;
    while (shift_index < shifts.len) : (shift_index += 1) {
        const shift = shifts[shift_index];
        const nibble: u4 = @intCast((value >> shift) & 0xF);
        try appendByte(out, cursor, hex[nibble]);
    }
}

test "ipv4 parse and format roundtrip" {
    const parsed = try Ipv4Address.parse("192.168.0.1");
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 0, 1 }, &parsed.octets);

    var out: [15]u8 = [_]u8{0} ** 15;
    const text = try parsed.format(&out);
    try std.testing.expectEqualStrings("192.168.0.1", text);
}

test "ipv4 parse rejects non-canonical decimal tokens" {
    try std.testing.expectError(error.InvalidInput, Ipv4Address.parse("01.2.3.4"));
    try std.testing.expectError(error.InvalidInput, Ipv4Address.parse("256.1.1.1"));
    try std.testing.expectError(error.InvalidInput, Ipv4Address.parse("1.2.3"));
}

test "ipv6 parse accepts compression and formats deterministically" {
    const parsed = try Ipv6Address.parse("2001:db8::1");
    try std.testing.expectEqual(@as(u16, 0x2001), parsed.segments[0]);
    try std.testing.expectEqual(@as(u16, 0x0db8), parsed.segments[1]);
    try std.testing.expectEqual(@as(u16, 0x0001), parsed.segments[7]);

    var out: [39]u8 = [_]u8{0} ** 39;
    const text = try parsed.format(&out);
    try std.testing.expectEqualStrings(
        "2001:0db8:0000:0000:0000:0000:0000:0001",
        text,
    );
}

test "ipv6 parse accepts IPv4-mapped tail" {
    const parsed = try Ipv6Address.parse("::ffff:192.168.0.1");
    try std.testing.expectEqual(@as(u16, 0x0000), parsed.segments[0]);
    try std.testing.expectEqual(@as(u16, 0xffff), parsed.segments[5]);
    try std.testing.expectEqual(@as(u16, 0xc0a8), parsed.segments[6]);
    try std.testing.expectEqual(@as(u16, 0x0001), parsed.segments[7]);
}

test "ipv6 parse rejects invalid forms and unsupported scope IDs" {
    try std.testing.expectError(error.InvalidInput, Ipv6Address.parse("2001::db8::1"));
    try std.testing.expectError(error.InvalidInput, Ipv6Address.parse("2001:db8:::1"));
    try std.testing.expectError(error.Unsupported, Ipv6Address.parse("fe80::1%2"));
}

test "address tagged parse dispatches by format" {
    const v4 = try Address.parse("10.0.0.7");
    try std.testing.expect(v4 == .ipv4);

    const v6 = try Address.parse("::1");
    try std.testing.expect(v6 == .ipv6);
}
