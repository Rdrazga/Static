//! Configuration validation helpers.
//!
//! Key types: `LockState`, `ValidateError`.
//! Usage pattern: call `validate(ok)` in init functions to enforce configuration
//! invariants; use `ensureUnlocked`/`ensureLocked` to guard state transitions.
//! Thread safety: not thread-safe — each function is pure and stateless.

const std = @import("std");
const errors = @import("errors.zig");

pub const ValidateError = error{InvalidConfig};

comptime {
    errors.assertVocabularySubset(ValidateError);
}

pub const LockState = enum {
    mutable,
    locked,
};

pub fn validate(ok: bool) ValidateError!void {
    if (!ok) return error.InvalidConfig;
    // Postcondition: if we reach here the configuration check passed.
    std.debug.assert(ok);
}

pub fn ensureUnlocked(state: LockState) ValidateError!void {
    if (state == .locked) return error.InvalidConfig;
    // Postcondition: the lock is confirmed to be in the mutable (unlocked) state.
    std.debug.assert(state == .mutable);
}

pub fn ensureLocked(state: LockState) ValidateError!void {
    if (state != .locked) return error.InvalidConfig;
    // Postcondition: the lock is confirmed to be in the locked state.
    std.debug.assert(state == .locked);
}

test "lock state helpers enforce expected mode" {
    try validate(true);
    try ensureUnlocked(.mutable);
    try ensureLocked(.locked);
    try std.testing.expectError(error.InvalidConfig, validate(false));
    try std.testing.expectError(error.InvalidConfig, ensureUnlocked(.locked));
    try std.testing.expectError(error.InvalidConfig, ensureLocked(.mutable));
}
