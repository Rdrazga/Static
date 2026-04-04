const std = @import("std");
const static_string = @import("static_string");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;
const support = @import("support.zig");

const max_entries: usize = 8;
const max_bytes: usize = 48;
const invalid_token_index = std.math.maxInt(u8);

const ActionTag = enum(u32) {
    intern_ascii = 1,
    intern_utf8 = 2,
    resolve_symbol = 3,
    contains_token = 4,
    restart_pool = 5,
};

const pool_violation = [_]checker.Violation{
    .{
        .code = "static_string.intern_pool_model",
        .message = "intern pool sequence behavior diverged from the bounded reference model",
    },
};

const ReferencePool = struct {
    token_indices: [max_entries]u8 = [_]u8{invalid_token_index} ** max_entries,
    len: usize = 0,
    bytes_used: usize = 0,

    fn reset(self: *@This()) void {
        self.token_indices = [_]u8{invalid_token_index} ** max_entries;
        self.len = 0;
        self.bytes_used = 0;
        std.debug.assert(self.len == 0);
        std.debug.assert(self.bytes_used == 0);
    }

    fn intern(self: *@This(), token_index: u8) static_string.InternError!static_string.Symbol {
        const value = support.vocabulary[token_index];
        if (self.findToken(token_index)) |symbol| return symbol;
        if (self.len >= max_entries) return error.NoSpaceLeft;
        if (self.bytes_used + value.len > max_bytes) return error.NoSpaceLeft;

        const symbol: static_string.Symbol = @intCast(self.len);
        self.token_indices[self.len] = token_index;
        self.len += 1;
        self.bytes_used += value.len;

        std.debug.assert(self.len <= max_entries);
        std.debug.assert(self.bytes_used <= max_bytes);
        return symbol;
    }

    fn resolve(self: *const @This(), symbol: static_string.Symbol) static_string.LookupError![]const u8 {
        const index: usize = symbol;
        if (index >= self.len) return error.NotFound;
        const token_index = self.token_indices[index];
        std.debug.assert(token_index != invalid_token_index);
        return support.vocabulary[token_index];
    }

    fn contains(self: *const @This(), token_index: u8) bool {
        return self.findToken(token_index) != null;
    }

    fn findToken(self: *const @This(), token_index: u8) ?static_string.Symbol {
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            if (self.token_indices[index] == token_index) return @intCast(index);
        }
        return null;
    }
};

const Context = struct {
    entry_storage: [max_entries]static_string.Entry = undefined,
    byte_storage: [max_bytes]u8 = undefined,
    pool: static_string.InternPool = undefined,
    reference: ReferencePool = .{},

    fn resetState(self: *@This()) void {
        @memset(self.byte_storage[0..], 0);
        self.pool = static_string.InternPool.init(self.entry_storage[0..], self.byte_storage[0..]) catch unreachable;
        self.reference.reset();
        std.debug.assert(self.pool.len() == 0);
        std.debug.assert(self.pool.bytesUsed() == 0);
    }

    fn validate(self: *@This()) checker.CheckResult {
        var digest = support.foldDigest(self.pool.len(), self.pool.bytesUsed());
        if (self.pool.len() != self.reference.len) {
            return checker.CheckResult.fail(&pool_violation, checker.CheckpointDigest.init(@as(u128, digest)));
        }
        if (self.pool.bytesUsed() != self.reference.bytes_used) {
            return checker.CheckResult.fail(&pool_violation, checker.CheckpointDigest.init(@as(u128, digest)));
        }

        var index: usize = 0;
        while (index < self.reference.len) : (index += 1) {
            const symbol: static_string.Symbol = @intCast(index);
            const actual = self.pool.resolve(symbol) catch {
                return checker.CheckResult.fail(&pool_violation, checker.CheckpointDigest.init(@as(u128, digest)));
            };
            const expected = self.reference.resolve(symbol) catch {
                return checker.CheckResult.fail(&pool_violation, checker.CheckpointDigest.init(@as(u128, digest)));
            };
            if (!std.mem.eql(u8, actual, expected)) {
                return checker.CheckResult.fail(&pool_violation, checker.CheckpointDigest.init(@as(u128, digest)));
            }
            digest = support.foldDigest(digest, support.digestBytes(actual));
        }

        for (support.vocabulary, 0..) |token, token_index| {
            const actual_contains = self.pool.contains(token);
            const expected_contains = self.reference.contains(@intCast(token_index));
            if (actual_contains != expected_contains) {
                return checker.CheckResult.fail(&pool_violation, checker.CheckpointDigest.init(@as(u128, digest)));
            }
        }

        return checker.CheckResult.pass(checker.CheckpointDigest.init(@as(u128, digest)));
    }

    fn internToken(self: *@This(), token_index: u8) checker.CheckResult {
        const value = support.vocabulary[token_index];
        const expected = self.reference.intern(token_index);
        const actual = self.pool.intern(value);

        if (expected) |expected_symbol| {
            if (actual) |actual_symbol| {
                if (actual_symbol != expected_symbol) {
                    return checker.CheckResult.fail(&pool_violation, null);
                }
            } else |_| {
                return checker.CheckResult.fail(&pool_violation, null);
            }
        } else |expected_err| switch (expected_err) {
            error.InvalidConfig => unreachable,
            error.NoSpaceLeft => {
                if (actual) |_| {
                    return checker.CheckResult.fail(&pool_violation, null);
                } else |actual_err| {
                    if (actual_err != error.NoSpaceLeft) {
                        return checker.CheckResult.fail(&pool_violation, null);
                    }
                }
            },
        }

        return self.validate();
    }

    fn resolveSymbol(self: *@This(), symbol: static_string.Symbol) checker.CheckResult {
        const expected = self.reference.resolve(symbol);
        const actual = self.pool.resolve(symbol);
        if (expected) |expected_value| {
            if (actual) |actual_value| {
                if (!std.mem.eql(u8, actual_value, expected_value)) {
                    return checker.CheckResult.fail(&pool_violation, null);
                }
            } else |_| {
                return checker.CheckResult.fail(&pool_violation, null);
            }
        } else |expected_err| switch (expected_err) {
            error.NotFound => {
                if (actual) |_| {
                    return checker.CheckResult.fail(&pool_violation, null);
                } else |actual_err| {
                    if (actual_err != error.NotFound) {
                        return checker.CheckResult.fail(&pool_violation, null);
                    }
                }
            },
        }
        return self.validate();
    }

    fn containsToken(self: *@This(), token_index: u8) checker.CheckResult {
        const value = support.vocabulary[token_index];
        const actual = self.pool.contains(value);
        const expected = self.reference.contains(token_index);
        if (actual != expected) {
            return checker.CheckResult.fail(&pool_violation, null);
        }
        return self.validate();
    }
};

test "static_string intern pool sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();

    var action_storage: [32]model.RecordedAction = undefined;
    var reduction_scratch: [32]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_string",
            .run_name = "intern_pool_model",
            .base_seed = .init(0x5737_7269_6e67_0003),
            .build_mode = .debug,
            .case_count_max = 96,
            .action_count_max = action_storage.len,
        },
        .target = Target{
            .context = &context,
            .reset_fn = reset,
            .next_action_fn = nextAction,
            .step_fn = step,
            .finish_fn = finish,
            .describe_action_fn = describe,
        },
        .action_storage = &action_storage,
        .reduction_scratch = &reduction_scratch,
    });

    try std.testing.expectEqual(@as(u32, 96), summary.executed_case_count);
    if (summary.failed_case) |failed_case| {
        var summary_buffer: [1536]u8 = undefined;
        const summary_text = try model.formatFailedCaseSummary(
            error{},
            &summary_buffer,
            Target{
                .context = &context,
                .reset_fn = reset,
                .next_action_fn = nextAction,
                .step_fn = step,
                .finish_fn = finish,
                .describe_action_fn = describe,
            },
            failed_case,
        );
        std.debug.print("{s}", .{summary_text});
        return error.TestUnexpectedResult;
    }
}

fn nextAction(
    _: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action_seed: seed_mod.Seed,
) error{}!model.RecordedAction {
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x5737_6d6f_6465_0001);
    const random = prng.random();
    const choice = random.uintLessThan(u32, 5);
    const tag: ActionTag = switch (choice) {
        0 => .intern_ascii,
        1 => .intern_utf8,
        2 => .resolve_symbol,
        3 => .contains_token,
        else => .restart_pool,
    };
    return .{
        .tag = @intFromEnum(tag),
        .value = random.int(u64),
    };
}

fn step(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
    action: model.RecordedAction,
) error{}!model.ModelStep {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const tag: ActionTag = @enumFromInt(action.tag);
    const result = switch (tag) {
        .intern_ascii => context.internToken(@intCast(action.value % 6)),
        .intern_utf8 => context.internToken(@intCast(6 + (action.value % (support.vocabulary.len - 6)))),
        .resolve_symbol => context.resolveSymbol(@intCast(action.value % (max_entries + 3))),
        .contains_token => context.containsToken(@intCast(action.value % support.vocabulary.len)),
        .restart_pool => blk: {
            context.resetState();
            break :blk context.validate();
        },
    };
    return .{ .check_result = result };
}

fn finish(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
    _: u32,
) error{}!checker.CheckResult {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return context.validate();
}

fn describe(_: *anyopaque, action: model.RecordedAction) model.ActionDescriptor {
    const tag: ActionTag = @enumFromInt(action.tag);
    return .{
        .label = switch (tag) {
            .intern_ascii => "intern_ascii",
            .intern_utf8 => "intern_utf8",
            .resolve_symbol => "resolve_symbol",
            .contains_token => "contains_token",
            .restart_pool => "restart_pool",
        },
    };
}

fn reset(
    context_ptr: *anyopaque,
    _: identity.RunIdentity,
) error{}!void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.resetState();
}
