//! `static_net` error sets.

const std = @import("std");
const core = @import("static_core");

pub const AddressParseError = error{
    InvalidInput,
    Unsupported,
};

pub const AddressFormatError = error{
    NoSpaceLeft,
};

pub const EndpointParseError = error{
    InvalidInput,
    Unsupported,
};

pub const EndpointFormatError = error{
    NoSpaceLeft,
};

pub const FrameConfigError = error{
    InvalidConfig,
};

pub const FrameEncodeError = error{
    InvalidConfig,
    InvalidInput,
    NoSpaceLeft,
    Overflow,
};

pub const FrameDecodeError = error{
    InvalidConfig,
    InvalidInput,
    NoSpaceLeft,
    EndOfStream,
    CorruptData,
    Unsupported,
    Overflow,
};

comptime {
    core.errors.assertVocabularySubset(AddressParseError);
    core.errors.assertVocabularySubset(AddressFormatError);
    core.errors.assertVocabularySubset(EndpointParseError);
    core.errors.assertVocabularySubset(EndpointFormatError);
    core.errors.assertVocabularySubset(FrameConfigError);
    core.errors.assertVocabularySubset(FrameEncodeError);
    core.errors.assertVocabularySubset(FrameDecodeError);
}

test "error tags map to shared vocabulary tags" {
    try std.testing.expect(core.errors.has(.InvalidInput, error.InvalidInput));
    try std.testing.expect(core.errors.has(.Unsupported, error.Unsupported));
    try std.testing.expect(core.errors.has(.NoSpaceLeft, error.NoSpaceLeft));
    try std.testing.expect(core.errors.has(.InvalidConfig, error.InvalidConfig));
    try std.testing.expect(core.errors.has(.EndOfStream, error.EndOfStream));
    try std.testing.expect(core.errors.has(.CorruptData, error.CorruptData));
    try std.testing.expect(core.errors.has(.Overflow, error.Overflow));
}
