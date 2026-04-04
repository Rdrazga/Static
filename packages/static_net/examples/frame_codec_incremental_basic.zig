const std = @import("std");
const static_net = @import("static_net");

pub fn main() !void {
    const cfg = try (static_net.FrameConfig{
        .max_payload_bytes = 128,
    }).init();

    const payload = "frame-over-stream";
    var encoded: [256]u8 = [_]u8{0} ** 256;
    const written = try static_net.frame_encode.encodeInto(cfg, &encoded, payload);

    var decoder = try static_net.Decoder.init(cfg);
    var out: [128]u8 = [_]u8{0} ** 128;

    const first = decoder.decode(encoded[0..3], &out);
    std.debug.assert(first.status == .need_more_input);

    const second = decoder.decode(encoded[3..written], &out);
    std.debug.assert(second.status == .frame);
    std.debug.assert(second.status.frame.payload_len == payload.len);

    std.debug.print("decoded: {s}\n", .{out[0..payload.len]});
}
