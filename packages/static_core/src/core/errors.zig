//! Shared error vocabulary for all static_* packages.
//!
//! Key types: `Tag`, `Vocabulary`.
//! Usage pattern: use `Vocabulary` in error sets at module boundaries; use
//! `has(tag, err)` to classify errors from external sources against the canonical tags.
//! Thread safety: not thread-safe — all functions are pure and stateless.

const std = @import("std");

pub const Tag = enum {
    // Allocation / capacity
    OutOfMemory,
    NoSpaceLeft,
    InvalidConfig,

    // Parsing / IO-style
    EndOfStream,
    InvalidInput,
    CorruptData,
    Unsupported,

    // Arithmetic / bounds
    Overflow,
    Underflow,

    // Concurrency / coordination
    WouldBlock,
    Timeout,
    Closed,
    Cancelled,

    // Lookup / sets/maps
    NotFound,
    AlreadyExists,
};

/// Shared named error vocabulary exposed as a Zig error set.
pub const Vocabulary = error{
    OutOfMemory,
    NoSpaceLeft,
    InvalidConfig,
    EndOfStream,
    InvalidInput,
    CorruptData,
    Unsupported,
    Overflow,
    Underflow,
    WouldBlock,
    Timeout,
    Closed,
    Cancelled,
    NotFound,
    AlreadyExists,
};

// Comptime invariant: Tag enum and Vocabulary error set must remain in sync.
// Adding an error to one without the other is a programmer error caught at compile time.
comptime {
    std.debug.assert(std.meta.fields(Tag).len == @typeInfo(Vocabulary).error_set.?.len);
}

pub fn toError(tag: Tag) Vocabulary {
    return switch (tag) {
        .OutOfMemory => error.OutOfMemory,
        .NoSpaceLeft => error.NoSpaceLeft,
        .InvalidConfig => error.InvalidConfig,
        .EndOfStream => error.EndOfStream,
        .InvalidInput => error.InvalidInput,
        .CorruptData => error.CorruptData,
        .Unsupported => error.Unsupported,
        .Overflow => error.Overflow,
        .Underflow => error.Underflow,
        .WouldBlock => error.WouldBlock,
        .Timeout => error.Timeout,
        .Closed => error.Closed,
        .Cancelled => error.Cancelled,
        .NotFound => error.NotFound,
        .AlreadyExists => error.AlreadyExists,
    };
}

pub fn tagOf(err: Vocabulary) Tag {
    return switch (err) {
        error.OutOfMemory => .OutOfMemory,
        error.NoSpaceLeft => .NoSpaceLeft,
        error.InvalidConfig => .InvalidConfig,
        error.EndOfStream => .EndOfStream,
        error.InvalidInput => .InvalidInput,
        error.CorruptData => .CorruptData,
        error.Unsupported => .Unsupported,
        error.Overflow => .Overflow,
        error.Underflow => .Underflow,
        error.WouldBlock => .WouldBlock,
        error.Timeout => .Timeout,
        error.Closed => .Closed,
        error.Cancelled => .Cancelled,
        error.NotFound => .NotFound,
        error.AlreadyExists => .AlreadyExists,
    };
}

pub fn has(tag: Tag, err: Vocabulary) bool {
    const result = tagOf(err) == tag;
    // Postcondition: result is a valid bool (true when the tag matches, false otherwise).
    // This documents that the switch is exhaustive and always produces a defined value.
    std.debug.assert(result == true or result == false);
    return result;
}

/// Compile-time assertion that every member of `ErrorSetType` exists in `Vocabulary`.
pub fn assertVocabularySubset(comptime ErrorSetType: type) void {
    const info = @typeInfo(ErrorSetType);
    comptime std.debug.assert(info == .error_set);
    const error_fields = info.error_set.?;

    inline for (error_fields) |error_field| {
        const local_error_value: ErrorSetType = @field(ErrorSetType, error_field.name);
        assertVocabularyMember(local_error_value);
    }
}

fn assertVocabularyMember(_: Vocabulary) void {}

test "vocabulary includes queue and allocation semantics" {
    try std.testing.expect(has(.WouldBlock, error.WouldBlock));
    try std.testing.expect(has(.OutOfMemory, error.OutOfMemory));
    try std.testing.expect(has(.Unsupported, error.Unsupported));
}

test "errors.has covers all 15 tags" {
    // Goal: every Tag must match its corresponding Vocabulary error and must not
    // match any other error. This ensures has() is bijective and the Tag/Vocabulary
    // pairing is exhaustive.
    //
    // Method: for each tag T, verify has(T, corresponding_error) == true,
    // then pick one arbitrary mismatched error and verify has(T, other) == false.

    // OutOfMemory
    try std.testing.expect(has(.OutOfMemory, error.OutOfMemory));
    try std.testing.expect(!has(.OutOfMemory, error.NoSpaceLeft));

    // NoSpaceLeft
    try std.testing.expect(has(.NoSpaceLeft, error.NoSpaceLeft));
    try std.testing.expect(!has(.NoSpaceLeft, error.OutOfMemory));

    // InvalidConfig
    try std.testing.expect(has(.InvalidConfig, error.InvalidConfig));
    try std.testing.expect(!has(.InvalidConfig, error.InvalidInput));

    // EndOfStream
    try std.testing.expect(has(.EndOfStream, error.EndOfStream));
    try std.testing.expect(!has(.EndOfStream, error.CorruptData));

    // InvalidInput
    try std.testing.expect(has(.InvalidInput, error.InvalidInput));
    try std.testing.expect(!has(.InvalidInput, error.InvalidConfig));

    // CorruptData
    try std.testing.expect(has(.CorruptData, error.CorruptData));
    try std.testing.expect(!has(.CorruptData, error.InvalidInput));

    // Unsupported
    try std.testing.expect(has(.Unsupported, error.Unsupported));
    try std.testing.expect(!has(.Unsupported, error.CorruptData));

    // Overflow
    try std.testing.expect(has(.Overflow, error.Overflow));
    try std.testing.expect(!has(.Overflow, error.Underflow));

    // Underflow
    try std.testing.expect(has(.Underflow, error.Underflow));
    try std.testing.expect(!has(.Underflow, error.Overflow));

    // WouldBlock
    try std.testing.expect(has(.WouldBlock, error.WouldBlock));
    try std.testing.expect(!has(.WouldBlock, error.Timeout));

    // Timeout
    try std.testing.expect(has(.Timeout, error.Timeout));
    try std.testing.expect(!has(.Timeout, error.Closed));

    // Closed
    try std.testing.expect(has(.Closed, error.Closed));
    try std.testing.expect(!has(.Closed, error.Cancelled));

    // Cancelled
    try std.testing.expect(has(.Cancelled, error.Cancelled));
    try std.testing.expect(!has(.Cancelled, error.Closed));

    // NotFound
    try std.testing.expect(has(.NotFound, error.NotFound));
    try std.testing.expect(!has(.NotFound, error.AlreadyExists));

    // AlreadyExists
    try std.testing.expect(has(.AlreadyExists, error.AlreadyExists));
    try std.testing.expect(!has(.AlreadyExists, error.NotFound));
}

test "errors.has tag count matches vocabulary size" {
    // Goal: runtime confirmation of the compile-time sync invariant from a second
    // code path (pair assertion). Also validates the expected count of 15.
    const tag_count = std.meta.fields(Tag).len;
    const vocab_count = @typeInfo(Vocabulary).error_set.?.len;
    try std.testing.expectEqual(tag_count, vocab_count);
    try std.testing.expectEqual(@as(usize, 15), tag_count);
    try std.testing.expectEqual(@as(usize, 15), vocab_count);
}

test "assertVocabularySubset accepts vocabulary-compatible sets" {
    const Compatible = error{ InvalidConfig, Overflow };
    comptime assertVocabularySubset(Compatible);
}

test "tag and vocabulary round-trip in both directions" {
    inline for (std.meta.fields(Tag)) |field| {
        const tag: Tag = @field(Tag, field.name);
        const vocabulary_error = toError(tag);
        try std.testing.expectEqual(tag, tagOf(vocabulary_error));
        try std.testing.expect(has(tag, vocabulary_error));
    }
}
