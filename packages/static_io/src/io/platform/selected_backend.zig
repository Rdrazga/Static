//! Selected platform backend implementation for the host target.

const builtin = @import("builtin");

/// Host-selected backend type used by `runtime.zig`.
pub const SelectedBackend = if (builtin.os.tag == .windows)
    @import("windows_backend.zig").WindowsBackend
else
    @import("posix_backend.zig").PosixBackend;
