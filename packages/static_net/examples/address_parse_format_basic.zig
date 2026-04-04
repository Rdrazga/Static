const std = @import("std");
const static_net = @import("static_net");

pub fn main() !void {
    const ip_v4 = try static_net.Ipv4Address.parse("192.168.1.40");
    const ip_v6 = try static_net.Ipv6Address.parse("2001:db8::7");

    var v4_buf: [15]u8 = [_]u8{0} ** 15;
    var v6_buf: [39]u8 = [_]u8{0} ** 39;
    const v4_text = try ip_v4.format(&v4_buf);
    const v6_text = try ip_v6.format(&v6_buf);

    std.debug.print("ipv4: {s}\n", .{v4_text});
    std.debug.print("ipv6: {s}\n", .{v6_text});
}
