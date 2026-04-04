//! Build-time capability helpers for `static_profile`.

const std = @import("std");
const static_core = @import("static_core");

const core_build_options = static_core.options.current();

pub const tracing_enabled = core_build_options.enable_tracing;

test "tracing capability mirrors core option" {
    try std.testing.expectEqual(core_build_options.enable_tracing, tracing_enabled);
}
