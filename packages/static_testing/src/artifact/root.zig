//! Internal artifact-storage helpers for `static_testing`.
//!
//! This boundary is intentionally narrow so it can move into a dedicated
//! package later without forcing feature modules to redesign their schemas.

pub const document = @import("document.zig");
pub const record_log = @import("record_log.zig");

test {
    _ = document;
    _ = record_log;
}
