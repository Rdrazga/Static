//! Deterministic bounded frame encoder.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_serial = @import("static_serial");
const errors = @import("errors.zig");
const frame_config = @import("frame_config.zig");

pub const EncodeError = errors.FrameEncodeError;

pub fn encodeInto(cfg: frame_config.Config, dst: []u8, payload: []const u8) EncodeError!usize {
    const needed = try frame_config.encodedLength(cfg, payload.len);
    if (dst.len < needed) return error.NoSpaceLeft;

    var writer = static_serial.writer.Writer.init(dst);
    writer.writeInt(cfg.protocol_version, .little) catch |err| return mapWriterError(err);

    const flags: u8 = if (cfg.checksumEnabled()) frame_config.flag_checksum_present else 0;
    writer.writeInt(flags, .little) catch |err| return mapWriterError(err);

    const payload_len_u32: u32 = @intCast(payload.len);
    writer.writeVarint(payload_len_u32) catch |err| return mapWriterError(err);
    writer.writeBytes(payload) catch |err| return mapWriterError(err);

    if (cfg.checksumEnabled()) {
        static_serial.checksum.writeChecksum32(&writer, payload) catch |err| return mapWriterError(err);
    }

    const written = writer.position();
    assert(written == needed);
    return written;
}

fn mapWriterError(err: static_serial.writer.Error) EncodeError {
    return switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.InvalidInput => error.InvalidInput,
        error.Overflow => error.Overflow,
        error.Underflow => error.Overflow,
    };
}

test "frame encode handles zero-length payload without checksum" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 128 }).init();
    var out: [8]u8 = [_]u8{0} ** 8;
    const written = try encodeInto(cfg, &out, &.{});
    try testing.expectEqual(@as(usize, 3), written);
    try testing.expectEqual(cfg.protocol_version, out[0]);
    try testing.expectEqual(@as(u8, 0), out[1]);
    try testing.expectEqual(@as(u8, 0), out[2]);
}

test "frame encode rejects payload larger than configured maximum" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 3 }).init();
    var out: [32]u8 = [_]u8{0} ** 32;
    try testing.expectError(
        error.NoSpaceLeft,
        encodeInto(cfg, &out, "toolarge"),
    );
}

test "frame encode writes checksum trailers when enabled" {
    const cfg = try (frame_config.Config{
        .max_payload_bytes = 128,
        .checksum_mode = .enabled,
    }).init();
    var out: [64]u8 = [_]u8{0} ** 64;
    const payload = "hello";
    const written = try encodeInto(cfg, &out, payload);
    try testing.expect(written > payload.len);
    try testing.expectEqual(frame_config.flag_checksum_present, out[1]);
}

test "frame encode rejects destination buffers that are too small" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 128 }).init();
    var out: [4]u8 = [_]u8{0} ** 4;
    try testing.expectError(error.NoSpaceLeft, encodeInto(cfg, &out, "abcd"));
}
