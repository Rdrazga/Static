//! `static_net_native` package root.
//!
//! OS-facing adapters that translate `static_net` endpoint values to native
//! socket-address layouts without pulling syscall types into `static_net`.

pub const static_net = @import("static_net");

pub const common = @import("net_native/common.zig");
pub const windows = @import("net_native/windows.zig");
pub const windows_compat = @import("net_native/windows_compat.zig");
pub const posix = @import("net_native/posix.zig");
pub const linux = @import("net_native/linux.zig");

pub const Endpoint = static_net.Endpoint;

test {
    _ = static_net;
    _ = common;
    _ = windows;
    _ = windows_compat;
    _ = posix;
    _ = linux;
}
