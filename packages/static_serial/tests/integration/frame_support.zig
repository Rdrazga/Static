const std = @import("std");
const static_serial = @import("static_serial");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const trace = static_testing.testing.trace;

pub const max_frame_bytes: usize = 96;
pub const max_payload_bytes: usize = 48;

pub const FrameChecksumMode = enum {
    valid,
    mismatch,
};

pub const ParseStatus = enum {
    ready,
    need_more,
    rejected,
    checksum_mismatch,
};

pub const ParsedFrame = struct {
    payload_len: u16,
    consumed: usize,
    payload_digest: u64,
};

pub const FrameParseOutcome = union(ParseStatus) {
    ready: ParsedFrame,
    need_more: void,
    rejected: void,
    checksum_mismatch: void,
};

pub const GeneratedFrameBytes = struct {
    bytes: [max_frame_bytes]u8 = [_]u8{0} ** max_frame_bytes,
    len: usize = 0,
};

pub const CaseCheck = struct {
    digest: u64,
    violations: ?[]const checker.Violation = null,
};

pub const RetainedMalformedCase = struct {
    bytes: [max_frame_bytes]u8 = [_]u8{0} ** max_frame_bytes,
    len: usize,
    label: []const u8,
    expected: ParseStatus,
    violations: []const checker.Violation,
    digest: u128,
};

pub fn evaluateFrameCase(
    bytes: []const u8,
    violation: []const checker.Violation,
) CaseCheck {
    const actual = parseFrameWithSerial(bytes);
    const reference = parseFrameReference(bytes);
    var digest = foldDigest(digestBytes(bytes), outcomeDigest(actual));
    digest = foldDigest(digest, outcomeDigest(reference));
    if (!outcomesEqual(actual, reference)) {
        return .{
            .digest = digest,
            .violations = violation,
        };
    }
    return .{ .digest = digest };
}

pub fn parseFrameWithSerial(bytes: []const u8) FrameParseOutcome {
    var reader = static_serial.reader.Reader.init(bytes);
    const payload_len = reader.readVarint(u16) catch |err| return mapSerialReadError(err);
    if (payload_len == 0) return .{ .rejected = {} };

    const payload = reader.readBytes(payload_len) catch |err| return mapSerialReadError(err);
    const stored_checksum = reader.readInt(u32, .little) catch |err| return mapSerialReadError(err);
    static_serial.checksum.verifyChecksum32(payload, stored_checksum) catch {
        return .{ .checksum_mismatch = {} };
    };

    return .{
        .ready = .{
            .payload_len = payload_len,
            .consumed = reader.position(),
            .payload_digest = digestBytes(payload),
        },
    };
}

pub fn parseFrameReference(bytes: []const u8) FrameParseOutcome {
    const decoded_len = decodeLengthPrefix(bytes);
    switch (decoded_len) {
        .need_more => return .{ .need_more = {} },
        .rejected => return .{ .rejected = {} },
        .ready => |prefix| {
            if (prefix.value == 0) return .{ .rejected = {} };

            const payload_start = prefix.bytes_read;
            const payload_end = payload_start + prefix.value;
            if (payload_end > bytes.len) return .{ .need_more = {} };

            const checksum_end = payload_end + 4;
            if (checksum_end > bytes.len) return .{ .need_more = {} };

            const payload = bytes[payload_start..payload_end];
            const checksum_bytes: *const [4]u8 = @ptrCast(bytes[payload_end..checksum_end].ptr);
            const stored_checksum = std.mem.readInt(u32, checksum_bytes, .little);
            if (computeChecksum(payload) != stored_checksum) {
                return .{ .checksum_mismatch = {} };
            }

            return .{
                .ready = .{
                    .payload_len = @intCast(prefix.value),
                    .consumed = checksum_end,
                    .payload_digest = digestBytes(payload),
                },
            };
        },
    }
}

pub fn outcomesEqual(left: FrameParseOutcome, right: FrameParseOutcome) bool {
    return switch (left) {
        .ready => |left_ready| switch (right) {
            .ready => |right_ready| {
                return left_ready.payload_len == right_ready.payload_len and
                    left_ready.consumed == right_ready.consumed and
                    left_ready.payload_digest == right_ready.payload_digest;
            },
            else => false,
        },
        .need_more => switch (right) {
            .need_more => true,
            else => false,
        },
        .rejected => switch (right) {
            .rejected => true,
            else => false,
        },
        .checksum_mismatch => switch (right) {
            .checksum_mismatch => true,
            else => false,
        },
    };
}

pub fn outcomeTag(outcome: FrameParseOutcome) ParseStatus {
    return switch (outcome) {
        .ready => .ready,
        .need_more => .need_more,
        .rejected => .rejected,
        .checksum_mismatch => .checksum_mismatch,
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
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x5173_5e64_fa31_2026);
    const random = prng.random();
    random.bytes(buffer);
    for (buffer, 0..) |*byte, index| {
        byte.* ^= @truncate(index *% 0x3d);
    }
}

pub fn writeFrame(
    buffer: []u8,
    payload: []const u8,
    checksum_mode: FrameChecksumMode,
) static_serial.writer.Error!usize {
    std.debug.assert(payload.len > 0);

    var writer = static_serial.writer.Writer.init(buffer);
    try writer.writeVarint(@as(u16, @intCast(payload.len)));
    try writer.writeBytes(payload);
    try static_serial.checksum.writeChecksum32(&writer, payload);
    const written_len = writer.position();
    if (checksum_mode == .mismatch) {
        buffer[written_len - 1] ^= 0x5a;
    }
    return written_len;
}

pub fn buildGeneratedFrameBytes(seed_value: u64) GeneratedFrameBytes {
    var generated = GeneratedFrameBytes{};
    var payload: [max_payload_bytes]u8 = undefined;

    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x5e71_a111_2026_0320);
    const random = prng.random();
    const scenario = random.uintLessThan(u32, 10);

    switch (scenario) {
        0 => {
            const payload_len = 1 + random.uintLessThan(usize, max_payload_bytes);
            fillPayload(payload[0..payload_len], seed_value ^ 0x1001);
            generated.len = writeFrame(
                generated.bytes[0..],
                payload[0..payload_len],
                .valid,
            ) catch unreachable;
        },
        1 => {
            const payload_len = 1 + random.uintLessThan(usize, max_payload_bytes / 2);
            fillPayload(payload[0..payload_len], seed_value ^ 0x1002);
            const frame_len = writeFrame(
                generated.bytes[0..],
                payload[0..payload_len],
                .valid,
            ) catch unreachable;
            const trailing_max = @min(@as(usize, 4), max_frame_bytes - frame_len);
            const trailing_len = 1 + random.uintLessThan(usize, trailing_max);
            random.bytes(generated.bytes[frame_len .. frame_len + trailing_len]);
            generated.len = frame_len + trailing_len;
        },
        2 => {
            const payload_len = 1 + random.uintLessThan(usize, max_payload_bytes / 2);
            fillPayload(payload[0..payload_len], seed_value ^ 0x1003);
            generated.len = writeFrame(
                generated.bytes[0..],
                payload[0..payload_len],
                .mismatch,
            ) catch unreachable;
        },
        3 => {
            const payload_len = 1 + random.uintLessThan(usize, max_payload_bytes / 2);
            fillPayload(payload[0..payload_len], seed_value ^ 0x1004);
            _ = writeFrame(
                generated.bytes[0..],
                payload[0..payload_len],
                .valid,
            ) catch unreachable;
            const prefix_len = static_serial.varint.varintLen(@as(u16, @intCast(payload_len)));
            const retained_payload_bytes = random.uintLessThan(usize, payload_len);
            generated.len = prefix_len + retained_payload_bytes;
        },
        4 => {
            const payload_len = 1 + random.uintLessThan(usize, max_payload_bytes / 2);
            fillPayload(payload[0..payload_len], seed_value ^ 0x1005);
            const frame_len = writeFrame(
                generated.bytes[0..],
                payload[0..payload_len],
                .valid,
            ) catch unreachable;
            const checksum_bytes_kept = random.uintLessThan(usize, 4);
            generated.len = frame_len - (4 - checksum_bytes_kept);
        },
        5 => {
            generated.bytes[0] = 0x81;
            generated.bytes[1] = 0x00;
            generated.bytes[2] = 0x53;
            generated.bytes[3] = 0xaa;
            generated.bytes[4] = 0xbb;
            generated.bytes[5] = 0xcc;
            generated.bytes[6] = 0xdd;
            generated.len = 7;
        },
        6 => {
            generated.bytes[0] = 0x80;
            generated.bytes[1] = 0x80;
            generated.bytes[2] = 0x04;
            generated.bytes[3] = 0x11;
            generated.bytes[4] = 0x22;
            generated.bytes[5] = 0x33;
            generated.bytes[6] = 0x44;
            generated.len = 7;
        },
        7 => {
            generated.bytes[0] = 0x00;
            @memset(generated.bytes[1..5], 0);
            generated.len = 5;
        },
        8 => {
            generated.bytes[0] = 0x80;
            generated.bytes[1] = 0x80;
            generated.len = 2;
        },
        else => {
            generated.len = 1 + random.uintLessThan(usize, max_frame_bytes);
            random.bytes(generated.bytes[0..generated.len]);
        },
    }

    std.debug.assert(generated.len <= generated.bytes.len);
    return generated;
}

pub fn buildRetainedMalformedCase(
    seed_value: u64,
    checksum_violation: []const checker.Violation,
    truncated_violation: []const checker.Violation,
    noncanonical_violation: []const checker.Violation,
) RetainedMalformedCase {
    var retained = RetainedMalformedCase{
        .len = 0,
        .label = "",
        .expected = .rejected,
        .violations = checksum_violation,
        .digest = 0,
    };
    var payload: [max_payload_bytes]u8 = undefined;

    switch (seed_value % 3) {
        0 => {
            const payload_len: usize = 16;
            fillPayload(payload[0..payload_len], seed_value ^ 0x2001);
            retained.len = writeFrame(
                retained.bytes[0..],
                payload[0..payload_len],
                .mismatch,
            ) catch unreachable;
            retained.label = "checksum_mismatch";
            retained.expected = .checksum_mismatch;
            retained.violations = checksum_violation;
        },
        1 => {
            const payload_len: usize = 18;
            fillPayload(payload[0..payload_len], seed_value ^ 0x2002);
            _ = writeFrame(
                retained.bytes[0..],
                payload[0..payload_len],
                .valid,
            ) catch unreachable;
            const prefix_len = static_serial.varint.varintLen(@as(u16, @intCast(payload_len)));
            retained.len = prefix_len + 9;
            retained.label = "truncated_payload";
            retained.expected = .need_more;
            retained.violations = truncated_violation;
        },
        else => {
            retained.bytes[0] = 0x81;
            retained.bytes[1] = 0x00;
            retained.bytes[2] = 0x41;
            retained.bytes[3] = 0x10;
            retained.bytes[4] = 0x20;
            retained.bytes[5] = 0x30;
            retained.bytes[6] = 0x40;
            retained.len = 7;
            retained.label = "noncanonical_prefix";
            retained.expected = .rejected;
            retained.violations = noncanonical_violation;
        },
    }

    retained.digest = @as(u128, foldDigest(
        digestBytes(retained.bytes[0..retained.len]),
        digestBytes(retained.label),
    ));
    return retained;
}

pub fn retainedMalformedCaseMatches(retained_case: RetainedMalformedCase) bool {
    const actual = parseFrameWithSerial(retained_case.bytes[0..retained_case.len]);
    const reference = parseFrameReference(retained_case.bytes[0..retained_case.len]);

    return retained_case.expected == outcomeTag(actual) and
        retained_case.expected == outcomeTag(reference) and
        outcomesEqual(actual, reference);
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

fn mapSerialReadError(err: static_serial.reader.Error) FrameParseOutcome {
    return switch (err) {
        error.EndOfStream => .{ .need_more = {} },
        error.InvalidInput,
        error.Overflow,
        error.Underflow,
        error.CorruptData,
        => .{ .rejected = {} },
    };
}

const LengthPrefixOutcome = union(enum) {
    ready: struct {
        value: usize,
        bytes_read: usize,
    },
    need_more: void,
    rejected: void,
};

fn decodeLengthPrefix(bytes: []const u8) LengthPrefixOutcome {
    var count: usize = 0;
    var shift: u8 = 0;
    var value: u64 = 0;

    while (count < bytes.len and count < 10) : (count += 1) {
        const byte = bytes[count];
        const payload = byte & 0x7f;
        if (shift == 63 and payload > 1) return .{ .rejected = {} };

        const shift_amount: u6 = @intCast(shift);
        value |= @as(u64, payload) << shift_amount;
        if ((byte & 0x80) == 0) {
            const consumed = count + 1;
            if (encodedUlebLen(value) != consumed) return .{ .rejected = {} };
            if (value > std.math.maxInt(u16)) return .{ .rejected = {} };
            return .{
                .ready = .{
                    .value = @intCast(value),
                    .bytes_read = consumed,
                },
            };
        }
        shift += 7;
    }

    if (bytes.len < 10) return .{ .need_more = {} };
    return .{ .rejected = {} };
}

fn computeChecksum(payload: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(payload);
    return hasher.final();
}

fn encodedUlebLen(value: u64) usize {
    var remaining = value;
    var len: usize = 1;
    while (remaining >= 0x80) : (len += 1) {
        remaining >>= 7;
    }
    return len;
}

fn outcomeDigest(outcome: FrameParseOutcome) u64 {
    return switch (outcome) {
        .ready => |ready| foldDigest(
            foldDigest(ready.payload_digest, ready.payload_len),
            ready.consumed,
        ),
        .need_more => 0x4e45_4544_4d4f_5245,
        .rejected => 0x5245_4a45_4354_4544,
        .checksum_mismatch => 0x4348_4543_4b53_554d,
    };
}

fn mix64(value: u64) u64 {
    var mixed = value ^ (value >> 33);
    mixed *%= 0xff51_afd7_ed55_8ccd;
    mixed ^= mixed >> 33;
    mixed *%= 0xc4ce_b9fe_1a85_ec53;
    mixed ^= mixed >> 33;
    return mixed;
}
