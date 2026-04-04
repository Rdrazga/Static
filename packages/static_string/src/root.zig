//! static_string - Bounded string utilities with explicit encoding choices.
//!
//! This package provides:
//! - fixed-capacity append buffers
//! - explicit UTF-8 validation
//! - ASCII-focused helpers
//! - deterministic bounded interning
//!
//! Package boundary:
//! - keep this package centered on bounded storage, deterministic interning,
//!   and the explicit encoding-policy checks that feed them;
//! - generic text-manipulation convenience helpers belong in std unless bounded storage
//!   or deterministic symbol handling requires an owned package surface.

pub const bounded_buffer = @import("string/bounded_buffer.zig");
pub const utf8 = @import("string/utf8.zig");
pub const ascii = @import("string/ascii.zig");
pub const intern_pool = @import("string/intern_pool.zig");

pub const BufferError = bounded_buffer.BufferError;
pub const BoundedBuffer = bounded_buffer.BoundedBuffer;
pub const Utf8Error = utf8.Utf8Error;
pub const Symbol = intern_pool.Symbol;
pub const Entry = intern_pool.Entry;
pub const InternError = intern_pool.InternError;
pub const LookupError = intern_pool.LookupError;
pub const InternPool = intern_pool.InternPool;

test {
    _ = bounded_buffer;
    _ = utf8;
    _ = ascii;
    _ = intern_pool;
}
