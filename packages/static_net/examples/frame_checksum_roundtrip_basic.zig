const std = @import("std");
const static_net = @import("static_net");

pub fn main() !void {
    const cfg = try (static_net.FrameConfig{
        .max_payload_bytes = 128,
        .checksum_mode = .enabled,
    }).init();

    const payload = "checksummed-frame";
    var encoded: [256]u8 = [_]u8{0} ** 256;
    const written = try static_net.frame_encode.encodeInto(cfg, &encoded, payload);

    var decoder = try static_net.Decoder.init(cfg);
    var decoded: [128]u8 = [_]u8{0} ** 128;

    const first = decoder.decode(encoded[0..4], &decoded);
    std.debug.assert(first.status == .need_more_input);

    const second = decoder.decode(encoded[4..written], &decoded);
    std.debug.assert(second.status == .frame);
    std.debug.assert(second.status.frame.payload_len == payload.len);
    std.debug.assert(second.status.frame.checksum_present);
    std.debug.assert(std.mem.eql(u8, decoded[0..payload.len], payload));
}
