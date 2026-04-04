//! Zone token type for matching beginZone/endZone pairs.
//!
//! `ZoneToken` is returned by `beginZone` and consumed by `endZone`. It carries the
//! zone name slice (borrowed from the caller) and thread/process IDs so that the end
//! event can be correlated with its matching begin in the trace export.
//!
//! Thread safety: value type; no shared state.
const std = @import("std");

pub const ZoneToken = struct {
    name: []const u8,
    tid: u32,
    pid: u32 = 0,
};

// ZoneToken carries name (slice = 2 words) + tid + pid; must never collapse to zero size.
comptime {
    std.debug.assert(@sizeOf(ZoneToken) > 0);
}
