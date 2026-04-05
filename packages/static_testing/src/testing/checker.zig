//! Shared checker vocabulary and contracts for deterministic validation.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// One deterministic checker violation with a stable code and message.
pub const Violation = struct {
    code: []const u8,
    message: []const u8,
};

/// The result of validating one execution or replay candidate.
pub const CheckResult = struct {
    passed: bool,
    violations: []const Violation,
    checkpoint_digest: ?CheckpointDigest = null,

    /// Construct a passing result with no violations.
    pub fn pass(checkpoint_digest: ?CheckpointDigest) CheckResult {
        return .{
            .passed = true,
            .violations = &.{},
            .checkpoint_digest = checkpoint_digest,
        };
    }

    /// Construct a failing result with one or more violations.
    pub fn fail(
        violations: []const Violation,
        checkpoint_digest: ?CheckpointDigest,
    ) CheckResult {
        assert(violations.len > 0);
        assertValidViolations(violations);
        return .{
            .passed = false,
            .violations = violations,
            .checkpoint_digest = checkpoint_digest,
        };
    }
};

/// Opaque fixed-width digest used for state comparison across checks.
pub const CheckpointDigest = struct {
    value: u128,

    /// Construct one digest from a raw `u128` value.
    pub fn init(value: u128) CheckpointDigest {
        return .{ .value = value };
    }

    /// Compare two checkpoint digests for exact equality.
    pub fn eql(self: CheckpointDigest, other: CheckpointDigest) bool {
        return self.value == other.value;
    }
};

/// Generic checker callback bundle for one deterministic input type.
pub fn Checker(comptime Input: type, comptime CheckError: type) type {
    return struct {
        context: *const anyopaque,
        run_fn: *const fn (context: *const anyopaque, input: Input) CheckError!CheckResult,

        /// Run the checker over one input value.
        pub fn run(self: @This(), input: Input) CheckError!CheckResult {
            return self.run_fn(self.context, input);
        }
    };
}

/// Run one checker and assert the returned pass/fail shape is internally consistent.
pub fn runChecker(
    comptime Input: type,
    comptime CheckError: type,
    checker: Checker(Input, CheckError),
    input: Input,
) CheckError!CheckResult {
    const result = try checker.run(input);
    if (result.passed) {
        assert(result.violations.len == 0);
    } else {
        assert(result.violations.len > 0);
        assertValidViolations(result.violations);
    }
    return result;
}

comptime {
    assert(@sizeOf(CheckpointDigest) == @sizeOf(u128));
}

fn assertValidViolations(violations: []const Violation) void {
    for (violations) |violation| {
        assert(violation.code.len > 0);
        assert(violation.message.len > 0);
    }
}

test "checker pass result propagates without violations" {
    const IntChecker = Checker(u32, error{Unexpected});
    const Context = struct {
        fn run(_: *const anyopaque, value: u32) error{Unexpected}!CheckResult {
            return if (value == 7) CheckResult.pass(CheckpointDigest.init(11)) else error.Unexpected;
        }
    };

    const checker = IntChecker{
        .context = undefined,
        .run_fn = Context.run,
    };
    const result = try runChecker(u32, error{Unexpected}, checker, 7);

    try testing.expect(result.passed);
    try testing.expectEqual(@as(usize, 0), result.violations.len);
    try testing.expect(result.checkpoint_digest != null);
}

test "checker failure result must carry violations" {
    const IntChecker = Checker(u32, error{});
    const violations = [_]Violation{
        .{ .code = "mismatch", .message = "value did not match expected" },
    };
    const Context = struct {
        fn run(_: *const anyopaque, _: u32) error{}!CheckResult {
            return CheckResult.fail(&violations, CheckpointDigest.init(99));
        }
    };

    const checker = IntChecker{
        .context = undefined,
        .run_fn = Context.run,
    };
    const result = try runChecker(u32, error{}, checker, 3);

    try testing.expect(!result.passed);
    try testing.expectEqual(@as(usize, 1), result.violations.len);
    try testing.expectEqualStrings("mismatch", result.violations[0].code);
}

test "checkpoint digest equality and inequality are stable" {
    const a = CheckpointDigest.init(1);
    const b = CheckpointDigest.init(1);
    const c = CheckpointDigest.init(2);

    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}
