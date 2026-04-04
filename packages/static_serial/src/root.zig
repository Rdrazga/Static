//! Bounded serialization helpers including readers, writers, varints, checksums, and views.
//!
//! Package boundary:
//! - `static_serial` owns structured wire-format flows.
//! - Primitive cursor, endian, cast, and raw LEB128 mechanics stay in `static_bits`.
//! - Reader/writer/varint here are adaptors over `static_bits` primitives, not a second
//!   home for generic byte or bit utilities.

pub const errors = @import("serial/errors.zig");
pub const reader = @import("serial/reader.zig");
pub const writer = @import("serial/writer.zig");
pub const varint = @import("serial/varint.zig");
pub const zigzag = @import("serial/zigzag.zig");
pub const checksum = @import("serial/checksum.zig");
pub const view = @import("serial/view.zig");

test {
    _ = errors;
    _ = reader;
    _ = writer;
    _ = varint;
    _ = zigzag;
    _ = checksum;
    _ = view;
}
