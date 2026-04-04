const std = @import("std");
const static_net_native = @import("static_net_native");
const static_testing = @import("static_testing");

const identity = static_testing.testing.identity;
const trace = static_testing.testing.trace;

pub const Endpoint = static_net_native.Endpoint;

pub fn buildIpv4Endpoint(seed_value: u64) Endpoint {
    var octets: [4]u8 = .{
        @truncate(seed_value | 1),
        @truncate(seed_value >> 8),
        @truncate(seed_value >> 16),
        @truncate(seed_value >> 24),
    };
    if (octets[0] == 0) octets[0] = 1;
    return .{ .ipv4 = .{
        .address = .{ .octets = octets },
        .port = 1024 + @as(u16, @intCast(seed_value % 50_000)),
    } };
}

pub fn buildIpv6Endpoint(seed_value: u64) Endpoint {
    var segments: [8]u16 = [_]u16{0} ** 8;
    var index: usize = 0;
    while (index < segments.len) : (index += 1) {
        const shift: u6 = @intCast((index % 4) * 16);
        const lane_seed = (seed_value >> shift) ^ (seed_value *% (index + 1));
        segments[index] = @truncate(lane_seed | 1);
    }
    return .{ .ipv6 = .{
        .address = .{ .segments = segments },
        .port = 1024 + @as(u16, @intCast((seed_value >> 7) % 50_000)),
    } };
}

pub fn endpointFromIoAddress(address: std.Io.net.IpAddress) Endpoint {
    return switch (address) {
        .ip4 => |ip4| .{ .ipv4 = .{
            .address = .{ .octets = ip4.bytes },
            .port = ip4.port,
        } },
        .ip6 => |ip6| .{ .ipv6 = .{
            .address = .{ .segments = static_net_native.common.ipv6SegmentsFromBytes(ip6.bytes) },
            .port = ip6.port,
        } },
    };
}

pub fn makeTraceMetadata(
    run_identity: identity.RunIdentity,
    event_count: u32,
    digest: u128,
) trace.TraceMetadata {
    const low = @as(u64, @truncate(digest)) ^ run_identity.seed.value;
    return .{
        .event_count = event_count,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = run_identity.case_index,
        .last_sequence_no = run_identity.case_index +% (if (event_count == 0) 0 else event_count - 1),
        .first_timestamp_ns = low,
        .last_timestamp_ns = low +% event_count,
    };
}

pub fn appendEvent(
    context: anytype,
    next_sequence_no: *u32,
    label: []const u8,
    category: trace.TraceCategory,
    surface_label: []const u8,
    cause_sequence_no: ?u32,
    value: u64,
) !u32 {
    return context.appendTraceEvent(
        next_sequence_no,
        label,
        category,
        surface_label,
        cause_sequence_no,
        value,
    );
}

pub fn digestEndpoint(endpoint: Endpoint) u64 {
    return switch (endpoint) {
        .ipv4 => |ipv4| blk: {
            var digest = foldDigest(0x4950_7634, ipv4.port);
            for (ipv4.address.octets) |octet| {
                digest = foldDigest(digest, octet);
            }
            break :blk digest;
        },
        .ipv6 => |ipv6| blk: {
            var digest = foldDigest(0x4950_7636, ipv6.port);
            for (ipv6.address.segments) |segment| {
                digest = foldDigest(digest, segment);
            }
            break :blk digest;
        },
    };
}

pub fn digestBytes(bytes: []const u8) u64 {
    var state: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |byte| {
        state ^= byte;
        state *%= 0x0000_0100_0000_01b3;
    }
    return mix64(state ^ @as(u64, @intCast(bytes.len)));
}

pub fn foldDigest(left: u64, right: u64) u64 {
    return mix64(left ^ (right +% 0x9e37_79b9_7f4a_7c15));
}

fn mix64(value: u64) u64 {
    var mixed = value ^ (value >> 33);
    mixed *%= 0xff51_afd7_ed55_8ccd;
    mixed ^= mixed >> 33;
    mixed *%= 0xc4ce_b9fe_1a85_ec53;
    mixed ^= mixed >> 33;
    return mixed;
}
