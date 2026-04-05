const std = @import("std");
const assert = std.debug.assert;
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
    assert(first.status == .need_more_input);

    const second = decoder.decode(encoded[4..written], &decoded);
    assert(second.status == .frame);
    assert(second.status.frame.payload_len == payload.len);
    assert(second.status.frame.checksum_present);
    assert(std.mem.eql(u8, decoded[0..payload.len], payload));
}
