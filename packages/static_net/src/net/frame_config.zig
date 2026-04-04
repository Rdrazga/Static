//! Frame codec configuration and constants.

const std = @import("std");
const core = @import("static_core");
const errors = @import("errors.zig");

pub const protocol_version_current: u8 = 1;
pub const flag_checksum_present: u8 = 0x01;
pub const max_varint_bytes_u32: usize = 5;
pub const max_header_bytes: usize = 2 + max_varint_bytes_u32;

pub const ChecksumMode = enum {
    disabled,
    enabled,
};

pub const Config = struct {
    max_payload_bytes: u32,
    checksum_mode: ChecksumMode = .disabled,
    protocol_version: u8 = protocol_version_current,

    pub fn validate(self: Config) errors.FrameConfigError!void {
        try core.config.validate(self.max_payload_bytes != 0);
        try core.config.validate(self.protocol_version != 0);
    }

    pub fn init(self: Config) errors.FrameConfigError!Config {
        try self.validate();
        return self;
    }

    pub fn checksumEnabled(self: Config) bool {
        return self.checksum_mode == .enabled;
    }
};

pub fn encodedLength(cfg: Config, payload_len: usize) errors.FrameEncodeError!usize {
    cfg.validate() catch |err| switch (err) {
        error.InvalidConfig => return error.InvalidConfig,
    };
    if (payload_len > cfg.max_payload_bytes) return error.NoSpaceLeft;
    if (cfg.checksumEnabled() and payload_len == 0) return error.InvalidInput;
    if (payload_len > std.math.maxInt(u32)) return error.Overflow;

    const payload_len_u32: u32 = @intCast(payload_len);
    const varint_len = serialVarintLen(payload_len_u32);
    const checksum_len: usize = if (cfg.checksumEnabled()) 4 else 0;

    var total = std.math.add(usize, 2, varint_len) catch return error.Overflow;
    total = std.math.add(usize, total, payload_len) catch return error.Overflow;
    total = std.math.add(usize, total, checksum_len) catch return error.Overflow;
    return total;
}

fn serialVarintLen(value: u32) usize {
    const static_serial = @import("static_serial");
    return static_serial.varint.varintLen(value);
}

test "frame config validates required bounds" {
    try (Config{ .max_payload_bytes = 64 }).validate();
    try std.testing.expectError(
        error.InvalidConfig,
        (Config{ .max_payload_bytes = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        (Config{
            .max_payload_bytes = 16,
            .protocol_version = 0,
        }).validate(),
    );
}

test "frame encoded length is deterministic and bounded" {
    const cfg = try (Config{ .max_payload_bytes = 256 }).init();
    try std.testing.expectEqual(@as(usize, 3), try encodedLength(cfg, 0));
    try std.testing.expectEqual(@as(usize, 13), try encodedLength(cfg, 10));
}

test "checksum mode rejects empty payload at encode boundary" {
    const cfg = try (Config{
        .max_payload_bytes = 256,
        .checksum_mode = .enabled,
    }).init();
    try std.testing.expectError(error.InvalidInput, encodedLength(cfg, 0));
}
