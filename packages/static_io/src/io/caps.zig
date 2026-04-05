//! Build-time capability helpers for `static_io`.

const std = @import("std");
const testing = std.testing;
const static_core = @import("static_core");

const core_build_options = static_core.options.current();

pub const threads_enabled = !core_build_options.single_threaded;
pub const os_backends_enabled = core_build_options.enable_os_backends;
pub const tracing_enabled = core_build_options.enable_tracing;

pub fn threadedBackendEnabled() bool {
    return os_backends_enabled and threads_enabled;
}

pub fn windowsBackendEnabled() bool {
    return threadedBackendEnabled() and builtinOsTag() == .windows;
}

pub fn linuxBackendEnabled() bool {
    return threadedBackendEnabled() and builtinOsTag() == .linux;
}

pub fn bsdBackendEnabled(os_tag: std.Target.Os.Tag) bool {
    return threadedBackendEnabled() and isBsdLike(os_tag);
}

pub fn platformBackendEnabled(os_tag: std.Target.Os.Tag) bool {
    return threadedBackendEnabled() and (os_tag == .windows or os_tag == .linux or isBsdLike(os_tag));
}

pub fn isBsdLike(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };
}

fn builtinOsTag() std.Target.Os.Tag {
    return @import("builtin").os.tag;
}

test "threaded backend capability matches build options" {
    try testing.expectEqual(threadedBackendEnabled(), os_backends_enabled and threads_enabled);
}

test "platform capability includes windows linux and bsd" {
    try testing.expect(platformBackendEnabled(.windows) == threadedBackendEnabled());
    try testing.expect(platformBackendEnabled(.linux) == threadedBackendEnabled());
    try testing.expect(platformBackendEnabled(.macos) == threadedBackendEnabled());
}
