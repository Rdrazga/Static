const std = @import("std");
const testing = std.testing;
const static_core = @import("static_core");

test "root surface negative contracts stay classified under the shared vocabulary" {
    try testing.expectError(error.InvalidConfig, static_core.config.validate(false));
    try testing.expectError(error.InvalidConfig, static_core.config.ensureUnlocked(.locked));
    try testing.expectError(error.InvalidConfig, static_core.config.ensureLocked(.mutable));

    const validate_err: static_core.errors.Vocabulary = blk: {
        _ = static_core.config.validate(false) catch |err| break :blk err;
        unreachable;
    };
    const unlocked_err: static_core.errors.Vocabulary = blk: {
        _ = static_core.config.ensureUnlocked(.locked) catch |err| break :blk err;
        unreachable;
    };
    const locked_err: static_core.errors.Vocabulary = blk: {
        _ = static_core.config.ensureLocked(.mutable) catch |err| break :blk err;
        unreachable;
    };
    try testing.expect(static_core.errors.has(.InvalidConfig, validate_err));
    try testing.expect(static_core.errors.has(.InvalidConfig, unlocked_err));
    try testing.expect(static_core.errors.has(.InvalidConfig, locked_err));
}

test "root surface error tags and option names round-trip cleanly" {
    inline for (std.meta.fields(static_core.errors.Tag)) |field| {
        const tag: static_core.errors.Tag = @field(static_core.errors.Tag, field.name);
        const vocabulary_error = static_core.errors.toError(tag);
        try testing.expectEqual(tag, static_core.errors.tagOf(vocabulary_error));
        try testing.expect(static_core.errors.has(tag, vocabulary_error));
    }

    const options = static_core.options.current();
    try testing.expectEqualStrings("single_threaded", static_core.options.OptionNames.single_threaded);
    try testing.expectEqualStrings("enable_os_backends", static_core.options.OptionNames.enable_os_backends);
    try testing.expectEqualStrings("enable_tracing", static_core.options.OptionNames.enable_tracing);
    try testing.expectEqual(options.single_threaded, static_core.options.current().single_threaded);
    try testing.expectEqual(options.enable_os_backends, static_core.options.current().enable_os_backends);
    try testing.expectEqual(options.enable_tracing, static_core.options.current().enable_tracing);
}

test "root surface timeout budget exposes timeout and bounded positive path" {
    try testing.expectError(error.Timeout, static_core.time_budget.TimeoutBudget.init(0));
    const timeout_err: static_core.errors.Vocabulary = blk: {
        _ = static_core.time_budget.TimeoutBudget.init(0) catch |err| break :blk err;
        unreachable;
    };
    try testing.expect(static_core.errors.has(.Timeout, timeout_err));

    const timeout_ns: u64 = std.time.ns_per_ms;
    var budget = try static_core.time_budget.TimeoutBudget.init(timeout_ns);
    const remaining_ns = try budget.remainingOrTimeout();
    try testing.expect(remaining_ns <= timeout_ns);
    try testing.expect(remaining_ns > 0);
}
