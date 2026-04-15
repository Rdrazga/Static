//! Shared configuration, error, and option vocabulary used across the workspace packages.

pub const errors = @import("core/errors.zig");
pub const config = @import("core/config.zig");
pub const options = @import("core/options.zig");
pub const time_compat = @import("core/time_compat.zig");
pub const time_budget = @import("core/time_budget.zig");

test {
    // Smoke-test module wiring; real tests arrive with implementations.
    _ = errors;
    _ = config;
    _ = options;
    _ = time_compat;
    _ = time_budget;
}
