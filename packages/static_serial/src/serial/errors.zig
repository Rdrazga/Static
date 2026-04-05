//! Unified error taxonomy for all serial operations.
//!
//! Key types: `SerialError`.
//! Usage pattern: use `SerialError` as the error set for public-boundary functions
//! in reader, writer, varint, zigzag, and checksum modules.
//! Thread safety: not applicable — this module contains only type and comptime declarations.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("static_core");

/// SE-R2: Unified serial error taxonomy.
///
/// All serial operations (reading, writing, varint, zigzag, checksum) draw
/// from this single named set so that error handling at module boundaries is
/// consistent and callers can pattern-match on a common set.
///
/// Each variant is used as follows:
/// - `EndOfStream`:  A read ran past the end of the buffer.
/// - `NoSpaceLeft`:  A write ran past the end of the buffer.
/// - `InvalidInput`: The encoded data violates the format contract (e.g.
///                   non-canonical varint encoding).
/// - `Overflow`:     An arithmetic or cast result exceeded the target type.
/// - `Underflow`:    A cast result was below the minimum of the target type.
/// - `CorruptData`:  A checksum or integrity check failed.
pub const SerialError = error{
    EndOfStream,
    NoSpaceLeft,
    InvalidInput,
    Overflow,
    Underflow,
    CorruptData,
};

comptime {
    // Pair assertion: the error set has exactly the expected number of variants.
    // Update this count whenever a variant is added or removed.
    assert(@typeInfo(SerialError).error_set.?.len == 6);
    core.errors.assertVocabularySubset(SerialError);
}
