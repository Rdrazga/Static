//! Incremental bounded frame decoder.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_bits = @import("static_bits");
const static_serial = @import("static_serial");
const errors = @import("errors.zig");
const frame_config = @import("frame_config.zig");
const frame_encode = @import("frame_encode.zig");

pub const FrameInfo = struct {
    payload_len: u32,
    checksum_present: bool,
};

pub const DecodeStatus = union(enum) {
    need_more_input,
    frame: FrameInfo,
    err: errors.FrameDecodeError,
};

pub const DecodeStep = struct {
    consumed: usize,
    status: DecodeStatus,
};

const Stage = enum {
    header,
    payload,
    checksum,
};

const HeaderParse = union(enum) {
    need_more_input,
    ready: FrameInfo,
    err: errors.FrameDecodeError,
};

pub const Decoder = struct {
    cfg: frame_config.Config,
    stage: Stage = .header,

    header_buf: [frame_config.max_header_bytes]u8 = [_]u8{0} ** frame_config.max_header_bytes,
    header_len: u8 = 0,

    payload_len: u32 = 0,
    payload_written: u32 = 0,
    checksum_present: bool = false,

    checksum_buf: [4]u8 = [_]u8{0} ** 4,
    checksum_len: u8 = 0,

    output_ptr: ?[*]u8 = null,
    output_len: usize = 0,

    pub fn init(cfg: frame_config.Config) errors.FrameConfigError!Decoder {
        const validated = try cfg.init();
        return .{
            .cfg = validated,
        };
    }

    pub fn reset(self: *Decoder) void {
        self.stage = .header;
        self.header_len = 0;
        self.payload_len = 0;
        self.payload_written = 0;
        self.checksum_present = false;
        self.checksum_len = 0;
        self.output_ptr = null;
        self.output_len = 0;
    }

    pub fn isIdle(self: *const Decoder) bool {
        return self.stage == .header and
            self.header_len == 0 and
            self.payload_len == 0 and
            self.payload_written == 0 and
            self.checksum_len == 0 and
            self.output_ptr == null;
    }

    pub fn endOfInput(self: *Decoder) error{EndOfStream}!void {
        if (self.isIdle()) return;
        self.reset();
        return error.EndOfStream;
    }

    pub fn decode(self: *Decoder, input: []const u8, out_payload: []u8) DecodeStep {
        var consumed: usize = 0;

        while (true) {
            switch (self.stage) {
                .header => {
                    const maybe_step = self.consumeHeader(input, &consumed);
                    if (maybe_step) |step| return step;
                },
                .payload => {
                    const maybe_step = self.consumePayload(input, &consumed, out_payload);
                    if (maybe_step) |step| return step;
                },
                .checksum => {
                    const maybe_step = self.consumeChecksum(input, &consumed, out_payload);
                    if (maybe_step) |step| return step;
                },
            }
        }
    }

    fn consumeHeader(self: *Decoder, input: []const u8, consumed: *usize) ?DecodeStep {
        while (consumed.* < input.len) {
            if (self.header_len >= frame_config.max_header_bytes) {
                self.reset();
                return .{
                    .consumed = consumed.*,
                    .status = .{ .err = error.InvalidInput },
                };
            }

            self.header_buf[self.header_len] = input[consumed.*];
            self.header_len += 1;
            consumed.* += 1;

            const header_parse = self.tryParseHeader();
            switch (header_parse) {
                .need_more_input => continue,
                .err => |decode_err| {
                    self.reset();
                    return .{
                        .consumed = consumed.*,
                        .status = .{ .err = decode_err },
                    };
                },
                .ready => |info| {
                    self.payload_len = info.payload_len;
                    self.payload_written = 0;
                    self.checksum_present = info.checksum_present;
                    self.checksum_len = 0;

                    if (info.payload_len == 0 and !info.checksum_present) {
                        self.reset();
                        return .{
                            .consumed = consumed.*,
                            .status = .{ .frame = info },
                        };
                    }

                    if (info.payload_len == 0 and info.checksum_present) {
                        self.stage = .checksum;
                    } else {
                        self.stage = .payload;
                    }
                    return null;
                },
            }
        }

        return .{
            .consumed = consumed.*,
            .status = .need_more_input,
        };
    }

    fn tryParseHeader(self: *Decoder) HeaderParse {
        if (self.header_len < 2) return .need_more_input;

        const protocol_version = self.header_buf[0];
        if (protocol_version != self.cfg.protocol_version) return .{ .err = error.Unsupported };

        const flags = self.header_buf[1];
        const unknown_flags = flags & ~frame_config.flag_checksum_present;
        if (unknown_flags != 0) return .{ .err = error.InvalidInput };

        const checksum_present = (flags & frame_config.flag_checksum_present) != 0;
        if (checksum_present and !self.cfg.checksumEnabled()) return .{ .err = error.InvalidInput };
        if (!checksum_present and self.cfg.checksumEnabled()) return .{ .err = error.InvalidInput };

        const varint_len = @as(usize, self.header_len) - 2;
        if (varint_len == 0) return .need_more_input;

        const varint_bytes = self.header_buf[2..self.header_len];
        var reader = static_bits.cursor.ByteReader.init(varint_bytes);
        const payload_len = static_serial.varint.readVarint(&reader, u32) catch |err| switch (err) {
            error.EndOfStream => {
                if (varint_len >= frame_config.max_varint_bytes_u32 and
                    (varint_bytes[varint_bytes.len - 1] & 0x80) != 0)
                {
                    return .{ .err = error.InvalidInput };
                }
                return .need_more_input;
            },
            error.InvalidInput => return .{ .err = error.InvalidInput },
            error.Overflow => return .{ .err = error.Overflow },
            error.Underflow => return .{ .err = error.Overflow },
            error.NoSpaceLeft => return .{ .err = error.InvalidInput },
        };

        if (reader.remaining() != 0) return .{ .err = error.InvalidInput };
        if (payload_len > self.cfg.max_payload_bytes) return .{ .err = error.NoSpaceLeft };
        if (checksum_present and payload_len == 0) return .{ .err = error.InvalidInput };

        return .{
            .ready = .{
                .payload_len = payload_len,
                .checksum_present = checksum_present,
            },
        };
    }

    fn consumePayload(self: *Decoder, input: []const u8, consumed: *usize, out_payload: []u8) ?DecodeStep {
        assert(self.stage == .payload);
        assert(self.payload_len > 0);
        assert(self.payload_written <= self.payload_len);

        if (out_payload.len < self.payload_len) {
            self.reset();
            return .{
                .consumed = consumed.*,
                .status = .{ .err = error.NoSpaceLeft },
            };
        }
        if (self.ensureOutputStable(out_payload)) |stable_err| {
            self.reset();
            return .{
                .consumed = consumed.*,
                .status = .{ .err = stable_err },
            };
        }

        const remaining_payload: usize = self.payload_len - self.payload_written;
        const available_input: usize = input.len - consumed.*;
        const take = @min(remaining_payload, available_input);
        if (take > 0) {
            const dst_offset: usize = self.payload_written;
            @memcpy(out_payload[dst_offset .. dst_offset + take], input[consumed.* .. consumed.* + take]);
            consumed.* += take;
            self.payload_written += @intCast(take);
        }

        if (self.payload_written < self.payload_len) {
            return .{
                .consumed = consumed.*,
                .status = .need_more_input,
            };
        }

        if (self.checksum_present) {
            self.stage = .checksum;
            return null;
        }

        const info: FrameInfo = .{
            .payload_len = self.payload_len,
            .checksum_present = false,
        };
        self.reset();
        return .{
            .consumed = consumed.*,
            .status = .{ .frame = info },
        };
    }

    fn consumeChecksum(self: *Decoder, input: []const u8, consumed: *usize, out_payload: []u8) ?DecodeStep {
        assert(self.stage == .checksum);
        if (self.ensureOutputStable(out_payload)) |stable_err| {
            self.reset();
            return .{
                .consumed = consumed.*,
                .status = .{ .err = stable_err },
            };
        }
        if (out_payload.len < self.payload_len) {
            self.reset();
            return .{
                .consumed = consumed.*,
                .status = .{ .err = error.NoSpaceLeft },
            };
        }

        while (self.checksum_len < 4 and consumed.* < input.len) {
            self.checksum_buf[self.checksum_len] = input[consumed.*];
            self.checksum_len += 1;
            consumed.* += 1;
        }
        if (self.checksum_len < 4) {
            return .{
                .consumed = consumed.*,
                .status = .need_more_input,
            };
        }

        const expected_checksum = std.mem.readInt(u32, self.checksum_buf[0..4], .little);
        const payload_len_usize: usize = self.payload_len;
        const payload = out_payload[0..payload_len_usize];
        static_serial.checksum.verifyChecksum32(payload, expected_checksum) catch |verify_err| switch (verify_err) {
            error.CorruptData => {
                self.reset();
                return .{
                    .consumed = consumed.*,
                    .status = .{ .err = error.CorruptData },
                };
            },
        };

        const info: FrameInfo = .{
            .payload_len = self.payload_len,
            .checksum_present = true,
        };
        self.reset();
        return .{
            .consumed = consumed.*,
            .status = .{ .frame = info },
        };
    }

    fn ensureOutputStable(self: *Decoder, out_payload: []u8) ?errors.FrameDecodeError {
        if (self.output_ptr == null) {
            self.output_ptr = out_payload.ptr;
            self.output_len = out_payload.len;
            return null;
        }

        if (self.output_ptr.? != out_payload.ptr) return error.InvalidInput;
        if (self.output_len != out_payload.len) return error.InvalidInput;
        return null;
    }
};

test "decode roundtrip for zero-length payload" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 64 }).init();
    var encoded: [16]u8 = [_]u8{0} ** 16;
    const written = try frame_encode.encodeInto(cfg, &encoded, &.{});

    var decoder = try Decoder.init(cfg);
    var payload_out: [64]u8 = [_]u8{0} ** 64;
    const step = decoder.decode(encoded[0..written], &payload_out);
    try testing.expectEqual(written, step.consumed);
    try testing.expect(step.status == .frame);
    try testing.expectEqual(@as(u32, 0), step.status.frame.payload_len);
    try testing.expect(!step.status.frame.checksum_present);
}

test "decode roundtrip for maximum allowed payload" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 5 }).init();
    var encoded: [32]u8 = [_]u8{0} ** 32;
    const payload = "abcde";
    const written = try frame_encode.encodeInto(cfg, &encoded, payload);

    var decoder = try Decoder.init(cfg);
    var payload_out: [8]u8 = [_]u8{0} ** 8;
    const step = decoder.decode(encoded[0..written], &payload_out);
    try testing.expect(step.status == .frame);
    try testing.expectEqual(@as(u32, payload.len), step.status.frame.payload_len);
    try testing.expectEqualSlices(u8, payload, payload_out[0..payload.len]);
}

test "decode rejects over-limit payload lengths from headers" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 4 }).init();
    const encoded = [_]u8{
        cfg.protocol_version,
        0,
        0x05,
    };

    var decoder = try Decoder.init(cfg);
    var payload_out: [8]u8 = [_]u8{0} ** 8;
    const step = decoder.decode(&encoded, &payload_out);
    try testing.expect(step.status == .err);
    try testing.expectEqual(error.NoSpaceLeft, step.status.err);
}

test "decode reports EndOfStream on truncated frame when stream closes" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 64 }).init();
    var encoded: [32]u8 = [_]u8{0} ** 32;
    const payload = "abcdef";
    const written = try frame_encode.encodeInto(cfg, &encoded, payload);

    var decoder = try Decoder.init(cfg);
    var payload_out: [64]u8 = [_]u8{0} ** 64;
    const step = decoder.decode(encoded[0 .. written - 1], &payload_out);
    try testing.expect(step.status == .need_more_input);
    try testing.expectError(error.EndOfStream, decoder.endOfInput());
}

test "decode rejects non-canonical varint length encodings" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 64 }).init();
    const encoded = [_]u8{
        cfg.protocol_version,
        0,
        0x81,
        0x00,
        0xAA,
    };

    var decoder = try Decoder.init(cfg);
    var payload_out: [64]u8 = [_]u8{0} ** 64;
    const step = decoder.decode(&encoded, &payload_out);
    try testing.expect(step.status == .err);
    try testing.expectEqual(error.InvalidInput, step.status.err);
}

test "decode detects checksum mismatches when checksum mode is enabled" {
    const cfg = try (frame_config.Config{
        .max_payload_bytes = 64,
        .checksum_mode = .enabled,
    }).init();
    var encoded: [64]u8 = [_]u8{0} ** 64;
    const payload = "checksum";
    const written = try frame_encode.encodeInto(cfg, &encoded, payload);

    // Flip one payload bit but keep the trailer checksum unchanged.
    encoded[3] ^= 0x01;

    var decoder = try Decoder.init(cfg);
    var payload_out: [64]u8 = [_]u8{0} ** 64;
    const step = decoder.decode(encoded[0..written], &payload_out);
    try testing.expect(step.status == .err);
    try testing.expectEqual(error.CorruptData, step.status.err);
}

test "decode is deterministic across chunk boundaries" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 64 }).init();
    var encoded: [128]u8 = [_]u8{0} ** 128;
    const payload = "chunked-transport-payload";
    const written = try frame_encode.encodeInto(cfg, &encoded, payload);

    const boundaries = [_]usize{ 1, 2, 3, 5, 8, 13 };
    for (boundaries) |first_chunk| {
        var decoder = try Decoder.init(cfg);
        var out: [64]u8 = [_]u8{0} ** 64;

        const split = @min(first_chunk, written);
        const step_a = decoder.decode(encoded[0..split], &out);
        if (split < written) {
            try testing.expect(step_a.status == .need_more_input);
            const step_b = decoder.decode(encoded[split..written], &out);
            try testing.expect(step_b.status == .frame);
            try testing.expectEqual(@as(u32, payload.len), step_b.status.frame.payload_len);
        } else {
            try testing.expect(step_a.status == .frame);
            try testing.expectEqual(@as(u32, payload.len), step_a.status.frame.payload_len);
        }
        try testing.expectEqualSlices(u8, payload, out[0..payload.len]);
    }
}

test "seeded malformed corpus does not violate decoder bounds contracts" {
    const cfg = try (frame_config.Config{ .max_payload_bytes = 32 }).init();
    var decoder = try Decoder.init(cfg);
    var payload_out: [64]u8 = [_]u8{0} ** 64;

    const corpus = [_][]const u8{
        &.{},
        &.{0x01},
        &.{ 0x01, 0x02, 0x80 },
        &.{ 0x01, 0x00, 0x80, 0x80, 0x80, 0x80, 0x80 },
        &.{ 0x01, 0xFF, 0x01 },
        &.{ 0x00, 0x00, 0x00 },
        &.{ 0x01, 0x00, 0x01, 0xAA },
    };

    for (corpus) |sample| {
        decoder.reset();
        const step = decoder.decode(sample, &payload_out);
        switch (step.status) {
            .need_more_input => {
                if (decoder.isIdle()) {
                    try decoder.endOfInput();
                } else {
                    try testing.expectError(error.EndOfStream, decoder.endOfInput());
                }
            },
            .frame => |frame| {
                try testing.expect(frame.payload_len <= cfg.max_payload_bytes);
                try testing.expect(decoder.isIdle());
            },
            .err => try testing.expect(decoder.isIdle()),
        }
    }

    var prng = std.Random.DefaultPrng.init(0x5eed_1234_abcd_9876);
    const random = prng.random();
    var random_buf: [24]u8 = [_]u8{0} ** 24;
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        decoder.reset();
        const len = random.uintAtMost(usize, random_buf.len);
        random.bytes(random_buf[0..len]);

        const step = decoder.decode(random_buf[0..len], &payload_out);
        switch (step.status) {
            .need_more_input => {
                if (decoder.isIdle()) {
                    try decoder.endOfInput();
                } else {
                    try testing.expectError(error.EndOfStream, decoder.endOfInput());
                }
            },
            .frame => |frame| {
                try testing.expect(frame.payload_len <= cfg.max_payload_bytes);
                try testing.expect(decoder.isIdle());
            },
            .err => try testing.expect(decoder.isIdle()),
        }
    }
}
