//! Build-time option accessors for the static_* library family.
//!
//! Key types: `BuildOptions`, `OptionNames`.
//! Usage pattern: call `current()` once at startup to obtain a snapshot of all
//! active build options; compare against `OptionNames` constants for documentation.
//! Thread safety: not thread-safe — `current()` is pure but reads build-time constants.

const std = @import("std");
const build_options = @import("static_build_options");

pub const OptionNames = struct {
    pub const single_threaded: []const u8 = "single_threaded";
    pub const enable_os_backends: []const u8 = "enable_os_backends";
    pub const enable_tracing: []const u8 = "enable_tracing";
};

pub const BuildOptions = struct {
    single_threaded: bool,
    enable_os_backends: bool,
    enable_tracing: bool,
};

pub fn current() BuildOptions {
    const result = BuildOptions{
        .single_threaded = build_options.single_threaded,
        .enable_os_backends = build_options.enable_os_backends,
        .enable_tracing = build_options.enable_tracing,
    };
    // Postcondition: every field in the returned struct matches the underlying
    // build_options exactly. A discrepancy here would indicate a mapping bug.
    std.debug.assert(result.single_threaded == build_options.single_threaded);
    std.debug.assert(result.enable_os_backends == build_options.enable_os_backends);
    std.debug.assert(result.enable_tracing == build_options.enable_tracing);
    return result;
}

test "canonical option names and values are exposed" {
    const opts = current();
    try std.testing.expectEqual(opts.single_threaded, build_options.single_threaded);
    try std.testing.expectEqual(opts.enable_os_backends, build_options.enable_os_backends);
    try std.testing.expectEqual(opts.enable_tracing, build_options.enable_tracing);
    try std.testing.expectEqualStrings("single_threaded", OptionNames.single_threaded);
    try std.testing.expectEqualStrings("enable_os_backends", OptionNames.enable_os_backends);
    try std.testing.expectEqualStrings("enable_tracing", OptionNames.enable_tracing);
}
