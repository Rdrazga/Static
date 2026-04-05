const std = @import("std");
const assert = std.debug.assert;
const static_net = @import("static_net");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const trace = static_testing.testing.trace;

pub const max_payload_bytes: usize = 48;
pub const max_frame_bytes: usize = 96;

pub const FrameResult = struct {
    payload_len: u32,
    checksum_present: bool,
    consumed: usize,
    payload_digest: u64,
};

pub const ParseOutcome = union(enum) {
    need_more_input,
    frame: FrameResult,
    err: static_net.FrameDecodeError,
};

pub const CloseBehavior = enum {
    success,
    end_of_stream,
};

pub const ObservedResult = struct {
    consumed: usize,
    outcome: ParseOutcome,
    close_behavior: CloseBehavior,
};

pub const CaseCheck = struct {
    digest: u64,
    violations: ?[]const checker.Violation = null,
};

pub const GeneratedFrameCase = struct {
    cfg: static_net.FrameConfig,
    bytes: [max_frame_bytes]u8 = [_]u8{0} ** max_frame_bytes,
    len: usize = 0,
};

pub const RetainedMalformedCase = struct {
    cfg: static_net.FrameConfig,
    bytes: [max_frame_bytes]u8 = [_]u8{0} ** max_frame_bytes,
    len: usize,
    label: []const u8,
    violations: []const checker.Violation,
    digest: u128,
};

pub fn evaluateGeneratedCase(
    generated: GeneratedFrameCase,
    violation: []const checker.Violation,
) CaseCheck {
    const observed = observeDecoder(generated.cfg, generated.bytes[0..generated.len]);
    const reference = parseReference(generated.cfg, generated.bytes[0..generated.len]);
    var digest = digestCase(generated.cfg, generated.bytes[0..generated.len]);
    digest = foldDigest(digest, digestObserved(observed));
    digest = foldDigest(digest, digestObserved(reference));

    if (!observedEqual(observed, reference)) {
        return .{
            .digest = digest,
            .violations = violation,
        };
    }
    return .{ .digest = digest };
}

pub fn retainedMalformedCaseMatches(retained_case: RetainedMalformedCase) bool {
    const observed = observeDecoder(retained_case.cfg, retained_case.bytes[0..retained_case.len]);
    const reference = parseReference(retained_case.cfg, retained_case.bytes[0..retained_case.len]);
    return observedEqual(observed, reference);
}

pub fn observeDecoder(cfg: static_net.FrameConfig, bytes: []const u8) ObservedResult {
    var decoder = static_net.Decoder.init(cfg) catch unreachable;
    var payload_out: [max_payload_bytes]u8 = [_]u8{0} ** max_payload_bytes;
    const step = decoder.decode(bytes, &payload_out);
    const outcome: ParseOutcome = switch (step.status) {
        .need_more_input => .need_more_input,
        .frame => |frame| .{
            .frame = .{
                .payload_len = frame.payload_len,
                .checksum_present = frame.checksum_present,
                .consumed = step.consumed,
                .payload_digest = digestBytes(payload_out[0..@as(usize, @intCast(frame.payload_len))]),
            },
        },
        .err => |err| .{ .err = err },
    };
    const close_behavior: CloseBehavior = blk: {
        decoder.endOfInput() catch |err| switch (err) {
            error.EndOfStream => break :blk .end_of_stream,
        };
        break :blk .success;
    };
    return .{
        .consumed = step.consumed,
        .outcome = outcome,
        .close_behavior = close_behavior,
    };
}

pub fn parseReference(cfg: static_net.FrameConfig, bytes: []const u8) ObservedResult {
    const parse = parseReferenceOutcome(cfg, bytes);
    return .{
        .consumed = switch (parse.outcome) {
            .need_more_input => parse.consumed,
            .frame => |frame| frame.consumed,
            .err => parse.consumed,
        },
        .outcome = parse.outcome,
        .close_behavior = parse.close_behavior,
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

pub fn fillPayload(buffer: []u8, seed_value: u64) void {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x6e47_5e65_6420_2026);
    const random = prng.random();
    random.bytes(buffer);
    for (buffer, 0..) |*byte, index| {
        byte.* ^= @truncate(index *% 0x2f);
    }
}

pub fn encodeFrame(
    cfg: static_net.FrameConfig,
    buffer: []u8,
    payload: []const u8,
) !usize {
    return static_net.frame_encode.encodeInto(cfg, buffer, payload);
}

pub fn corruptLastChecksumByte(bytes: []u8, written_len: usize) void {
    assert(written_len >= 4);
    bytes[written_len - 1] ^= 0x5a;
}

pub fn writeNoncanonicalLengthFrame(
    cfg: static_net.FrameConfig,
    buffer: []u8,
) usize {
    buffer[0] = cfg.protocol_version;
    buffer[1] = if (cfg.checksumEnabled()) static_net.frame_config.flag_checksum_present else 0;
    buffer[2] = 0x81;
    buffer[3] = 0x00;
    buffer[4] = 0xaa;
    buffer[5] = 0xbb;
    buffer[6] = 0xcc;
    buffer[7] = 0xdd;
    return 8;
}

pub fn writeOverLimitHeader(
    cfg: static_net.FrameConfig,
    buffer: []u8,
) usize {
    buffer[0] = cfg.protocol_version;
    buffer[1] = if (cfg.checksumEnabled()) static_net.frame_config.flag_checksum_present else 0;
    var varint_bytes: [5]u8 = undefined;
    const encoded_len = encodeUleb128(cfg.max_payload_bytes + 1, &varint_bytes);
    @memcpy(buffer[2 .. 2 + encoded_len], varint_bytes[0..encoded_len]);
    return 2 + encoded_len;
}

pub fn buildGeneratedFrameCase(seed_value: u64) GeneratedFrameCase {
    var generated = GeneratedFrameCase{
        .cfg = chooseConfig(seed_value, false),
    };
    var payload: [max_payload_bytes]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x6e47_6574_6672_616d);
    const random = prng.random();
    const scenario = random.uintLessThan(u32, 12);

    switch (scenario) {
        0 => {
            const payload_len = random.uintLessThan(usize, @as(usize, @intCast(generated.cfg.max_payload_bytes + 1)));
            fillPayload(payload[0..payload_len], seed_value ^ 0x1001);
            generated.len = encodeFrame(generated.cfg, generated.bytes[0..], payload[0..payload_len]) catch unreachable;
        },
        1 => {
            generated.cfg = chooseConfig(seed_value, true);
            const payload_len = 1 + random.uintLessThan(usize, @as(usize, @intCast(generated.cfg.max_payload_bytes)));
            fillPayload(payload[0..payload_len], seed_value ^ 0x1002);
            generated.len = encodeFrame(generated.cfg, generated.bytes[0..], payload[0..payload_len]) catch unreachable;
            corruptLastChecksumByte(generated.bytes[0..generated.len], generated.len);
        },
        2 => {
            const payload_len = 1 + random.uintLessThan(usize, @as(usize, @intCast(generated.cfg.max_payload_bytes)));
            fillPayload(payload[0..payload_len], seed_value ^ 0x1003);
            const written = encodeFrame(generated.cfg, generated.bytes[0..], payload[0..payload_len]) catch unreachable;
            generated.len = @max(@as(usize, 1), written - 1 - random.uintLessThan(usize, @min(@as(usize, 4), written - 1)));
        },
        3 => {
            generated.len = writeNoncanonicalLengthFrame(generated.cfg, generated.bytes[0..]);
        },
        4 => {
            generated.len = writeOverLimitHeader(generated.cfg, generated.bytes[0..]);
        },
        5 => {
            generated.bytes[0] = generated.cfg.protocol_version +% 1;
            generated.bytes[1] = 0;
            generated.len = 2;
        },
        6 => {
            generated.bytes[0] = generated.cfg.protocol_version;
            generated.bytes[1] = 0x80;
            generated.len = 2;
        },
        7 => {
            generated.cfg = chooseConfig(seed_value, true);
            generated.bytes[0] = generated.cfg.protocol_version;
            generated.bytes[1] = 0;
            generated.bytes[2] = 0x01;
            generated.bytes[3] = 0xaa;
            generated.len = 4;
        },
        8 => {
            generated.len = 0;
        },
        9 => {
            generated.bytes[0] = generated.cfg.protocol_version;
            generated.len = 1;
        },
        10 => {
            const payload_len = random.uintLessThan(usize, @as(usize, @intCast(generated.cfg.max_payload_bytes + 1)));
            fillPayload(payload[0..payload_len], seed_value ^ 0x1004);
            const written = encodeFrame(generated.cfg, generated.bytes[0..], payload[0..payload_len]) catch unreachable;
            const trailing_len = 1 + random.uintLessThan(usize, @min(@as(usize, 4), generated.bytes.len - written));
            random.bytes(generated.bytes[written .. written + trailing_len]);
            generated.len = written + trailing_len;
        },
        else => {
            generated.len = 1 + random.uintLessThan(usize, generated.bytes.len);
            random.bytes(generated.bytes[0..generated.len]);
        },
    }

    assert(generated.len <= generated.bytes.len);
    return generated;
}

pub fn buildRetainedMalformedCase(
    seed_value: u64,
    checksum_violation: []const checker.Violation,
    truncated_violation: []const checker.Violation,
    noncanonical_violation: []const checker.Violation,
) RetainedMalformedCase {
    var retained = RetainedMalformedCase{
        .cfg = chooseConfig(seed_value, true),
        .len = 0,
        .label = "",
        .violations = checksum_violation,
        .digest = 0,
    };
    var payload: [max_payload_bytes]u8 = undefined;

    switch (seed_value % 3) {
        0 => {
            retained.cfg = chooseConfig(seed_value, true);
            const payload_len = 12;
            fillPayload(payload[0..payload_len], seed_value ^ 0x2001);
            retained.len = encodeFrame(retained.cfg, retained.bytes[0..], payload[0..payload_len]) catch unreachable;
            corruptLastChecksumByte(retained.bytes[0..retained.len], retained.len);
            retained.label = "checksum_mismatch";
            retained.violations = checksum_violation;
        },
        1 => {
            retained.cfg = chooseConfig(seed_value, false);
            const payload_len = 14;
            fillPayload(payload[0..payload_len], seed_value ^ 0x2002);
            const written = encodeFrame(retained.cfg, retained.bytes[0..], payload[0..payload_len]) catch unreachable;
            retained.len = written - 3;
            retained.label = "truncated_payload";
            retained.violations = truncated_violation;
        },
        else => {
            retained.cfg = chooseConfig(seed_value, false);
            retained.len = writeNoncanonicalLengthFrame(retained.cfg, retained.bytes[0..]);
            retained.label = "noncanonical_length";
            retained.violations = noncanonical_violation;
        },
    }

    retained.digest = @as(u128, foldDigest(
        digestCase(retained.cfg, retained.bytes[0..retained.len]),
        digestBytes(retained.label),
    ));
    return retained;
}

pub fn digestBytes(bytes: []const u8) u64 {
    var state: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |byte| {
        state ^= byte;
        state *%= 0x0000_0100_0000_01b3;
    }
    return state ^ @as(u64, @intCast(bytes.len));
}

pub fn foldDigest(left: u64, right: u64) u64 {
    return mix64(left ^ (right +% 0x9e37_79b9_7f4a_7c15));
}

fn chooseConfig(seed_value: u64, force_checksum: bool) static_net.FrameConfig {
    const payload_limits = [_]u32{ 8, 16, 32, 48 };
    const index: usize = @intCast(seed_value % payload_limits.len);
    return (static_net.FrameConfig{
        .max_payload_bytes = payload_limits[index],
        .checksum_mode = if (force_checksum or ((seed_value >> 8) & 1) == 1) .enabled else .disabled,
    }).init() catch unreachable;
}

const ReferenceParse = struct {
    consumed: usize,
    outcome: ParseOutcome,
    close_behavior: CloseBehavior,
};

fn parseReferenceOutcome(cfg: static_net.FrameConfig, bytes: []const u8) ReferenceParse {
    if (bytes.len < 2) {
        return .{
            .consumed = bytes.len,
            .outcome = .need_more_input,
            .close_behavior = if (bytes.len == 0) .success else .end_of_stream,
        };
    }

    const protocol_version = bytes[0];
    if (protocol_version != cfg.protocol_version) {
        return .{
            .consumed = 2,
            .outcome = .{ .err = error.Unsupported },
            .close_behavior = .success,
        };
    }

    const flags = bytes[1];
    const unknown_flags = flags & ~static_net.frame_config.flag_checksum_present;
    if (unknown_flags != 0) {
        return .{
            .consumed = 2,
            .outcome = .{ .err = error.InvalidInput },
            .close_behavior = .success,
        };
    }

    const checksum_present = (flags & static_net.frame_config.flag_checksum_present) != 0;
    if (checksum_present != cfg.checksumEnabled()) {
        return .{
            .consumed = 2,
            .outcome = .{ .err = error.InvalidInput },
            .close_behavior = .success,
        };
    }

    const decoded_len = decodeLengthPrefix(bytes[2..]);
    switch (decoded_len.outcome) {
        .need_more_input => |consumed| {
            const total_consumed = 2 + consumed;
            return .{
                .consumed = total_consumed,
                .outcome = .need_more_input,
                .close_behavior = .end_of_stream,
            };
        },
        .err => |decode_err| {
            const total_consumed = 2 + decoded_len.err_consumed;
            return .{
                .consumed = total_consumed,
                .outcome = .{ .err = decode_err },
                .close_behavior = .success,
            };
        },
        .ready => |ready| {
            if (ready.value > cfg.max_payload_bytes) {
                return .{
                    .consumed = 2 + ready.bytes_read,
                    .outcome = .{ .err = error.NoSpaceLeft },
                    .close_behavior = .success,
                };
            }
            if (checksum_present and ready.value == 0) {
                return .{
                    .consumed = 2 + ready.bytes_read,
                    .outcome = .{ .err = error.InvalidInput },
                    .close_behavior = .success,
                };
            }

            const payload_start = 2 + ready.bytes_read;
            const checksum_len: usize = if (checksum_present) 4 else 0;
            const payload_end = payload_start + ready.value;
            const total_len = payload_end + checksum_len;
            if (bytes.len < total_len) {
                return .{
                    .consumed = bytes.len,
                    .outcome = .need_more_input,
                    .close_behavior = .end_of_stream,
                };
            }

            if (checksum_present) {
                const checksum_bytes: *const [4]u8 = @ptrCast(bytes[payload_end..total_len].ptr);
                const expected_checksum = std.mem.readInt(u32, checksum_bytes, .little);
                static_net.serial.checksum.verifyChecksum32(bytes[payload_start..payload_end], expected_checksum) catch {
                    return .{
                        .consumed = total_len,
                        .outcome = .{ .err = error.CorruptData },
                        .close_behavior = .success,
                    };
                };
            }

            return .{
                .consumed = total_len,
                .outcome = .{
                    .frame = .{
                        .payload_len = ready.value,
                        .checksum_present = checksum_present,
                        .consumed = total_len,
                        .payload_digest = digestBytes(bytes[payload_start..payload_end]),
                    },
                },
                .close_behavior = .success,
            };
        },
    }
}

const DecodedLengthPrefix = struct {
    outcome: union(enum) {
        need_more_input: usize,
        ready: struct {
            value: u32,
            bytes_read: usize,
        },
        err: static_net.FrameDecodeError,
    },
    err_consumed: usize = 0,
};

fn decodeLengthPrefix(bytes: []const u8) DecodedLengthPrefix {
    var value: u64 = 0;
    var shift: u8 = 0;
    var index: usize = 0;

    while (index < bytes.len and index < static_net.frame_config.max_varint_bytes_u32) : (index += 1) {
        const byte = bytes[index];
        const payload = byte & 0x7f;
        if (shift == 28 and payload > 0x0f) {
            return .{
                .outcome = .{ .err = error.Overflow },
                .err_consumed = index + 1,
            };
        }

        const shift_amount: u6 = @intCast(shift);
        value |= @as(u64, payload) << shift_amount;
        if ((byte & 0x80) == 0) {
            const bytes_read = index + 1;
            if (encodedUlebLen(value) != bytes_read) {
                return .{
                    .outcome = .{ .err = error.InvalidInput },
                    .err_consumed = bytes_read,
                };
            }
            if (value > std.math.maxInt(u32)) {
                return .{
                    .outcome = .{ .err = error.Overflow },
                    .err_consumed = bytes_read,
                };
            }
            return .{
                .outcome = .{
                    .ready = .{
                        .value = @intCast(value),
                        .bytes_read = bytes_read,
                    },
                },
            };
        }

        shift += 7;
    }

    if (bytes.len < static_net.frame_config.max_varint_bytes_u32) {
        return .{ .outcome = .{ .need_more_input = bytes.len } };
    }
    return .{
        .outcome = .{ .err = error.InvalidInput },
        .err_consumed = static_net.frame_config.max_varint_bytes_u32,
    };
}

fn observedEqual(left: ObservedResult, right: ObservedResult) bool {
    if (left.consumed != right.consumed) return false;
    if (left.close_behavior != right.close_behavior) return false;

    return switch (left.outcome) {
        .need_more_input => switch (right.outcome) {
            .need_more_input => true,
            else => false,
        },
        .frame => |left_frame| switch (right.outcome) {
            .frame => |right_frame| {
                return left_frame.payload_len == right_frame.payload_len and
                    left_frame.checksum_present == right_frame.checksum_present and
                    left_frame.consumed == right_frame.consumed and
                    left_frame.payload_digest == right_frame.payload_digest;
            },
            else => false,
        },
        .err => |left_err| switch (right.outcome) {
            .err => |right_err| left_err == right_err,
            else => false,
        },
    };
}

fn digestCase(cfg: static_net.FrameConfig, bytes: []const u8) u64 {
    var digest = digestBytes(bytes);
    digest = foldDigest(digest, cfg.max_payload_bytes);
    digest = foldDigest(digest, cfg.protocol_version);
    digest = foldDigest(digest, if (cfg.checksumEnabled()) 1 else 0);
    return digest;
}

fn digestObserved(observed: ObservedResult) u64 {
    const digest = foldDigest(observed.consumed, @intFromEnum(observed.close_behavior));
    return switch (observed.outcome) {
        .need_more_input => foldDigest(digest, 0x4e45_4544_4d4f_5245),
        .frame => |frame| foldDigest(
            digest,
            foldDigest(
                foldDigest(frame.payload_len, if (frame.checksum_present) 1 else 0),
                foldDigest(frame.consumed, frame.payload_digest),
            ),
        ),
        .err => |err| foldDigest(digest, digestBytes(@errorName(err))),
    };
}

fn encodeUleb128(value: u32, out: *[5]u8) usize {
    var remaining = value;
    var index: usize = 0;
    while (true) : (index += 1) {
        const payload: u8 = @truncate(remaining & 0x7f);
        remaining >>= 7;
        if (remaining == 0) {
            out[index] = payload;
            return index + 1;
        }
        out[index] = payload | 0x80;
    }
}

fn encodedUlebLen(value: u64) usize {
    var remaining = value;
    var len: usize = 1;
    while (remaining >= 0x80) : (len += 1) {
        remaining >>= 7;
    }
    return len;
}

fn mix64(value: u64) u64 {
    var mixed = value ^ (value >> 33);
    mixed *%= 0xff51_afd7_ed55_8ccd;
    mixed ^= mixed >> 33;
    mixed *%= 0xc4ce_b9fe_1a85_ec53;
    mixed ^= mixed >> 33;
    return mixed;
}
