const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_meta = @import("static_meta");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const model = static_testing.testing.model;
const seed_mod = static_testing.testing.seed;

const meta = static_meta;

const max_entries: usize = 3;

const TypeAlpha = struct {
    pub const static_name: []const u8 = "tests/static_meta/alpha";
    pub const static_version: u32 = 1;
};

const TypeBeta = struct {
    pub const static_name: []const u8 = "tests/static_meta/beta";
    pub const static_version: u32 = 2;
};

const TypeGamma = struct {
    pub const static_name: []const u8 = "tests/static_meta/gamma";
    pub const static_version: u32 = 3;
};

const TypeOverflow = struct {
    pub const static_name: []const u8 = "tests/static_meta/overflow";
    pub const static_version: u32 = 4;
};

const RegistryKind = enum(u8) {
    alpha,
    beta,
    gamma,
    overflow,
};

const registry_kinds = [_]RegistryKind{
    .alpha,
    .beta,
    .gamma,
    .overflow,
};

const ActionTag = enum(u32) {
    register_alpha = 1,
    assert_alpha = 2,
    register_beta = 3,
    assert_beta = 4,
    register_gamma = 5,
    assert_gamma = 6,
    missing_lookup = 7,
    register_overflow = 8,
    reset_registry = 9,
};

const registry_violation = [_]checker.Violation{
    .{
        .code = "static_meta.registry_model",
        .message = "type registry sequence diverged from the bounded reference model",
    },
};

const ReferenceRegistry = struct {
    kinds: [max_entries]RegistryKind = undefined,
    len: usize = 0,

    fn reset(self: *@This()) void {
        self.len = 0;
        assert(self.len == 0);
        assert(self.len <= max_entries);
    }

    fn register(self: *@This(), kind: RegistryKind) meta.RegistryError!void {
        const id = typeId(kind);
        if (self.containsId(id)) return error.AlreadyExists;
        if (self.len >= max_entries) return error.NoSpaceLeft;
        self.kinds[self.len] = kind;
        self.len += 1;
        assert(self.len <= max_entries);
        assert(self.containsId(id));
    }

    fn containsId(self: *const @This(), id: meta.TypeId) bool {
        return self.findKind(id) != null;
    }

    fn findKind(self: *const @This(), id: meta.TypeId) ?RegistryKind {
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            if (typeId(self.kinds[index]) == id) return self.kinds[index];
        }
        return null;
    }

    fn list(self: *const @This()) []const RegistryKind {
        assert(self.len <= max_entries);
        return self.kinds[0..self.len];
    }
};

const Context = struct {
    entry_storage: [max_entries]meta.Entry = undefined,
    registry: meta.TypeRegistry = undefined,
    reference: ReferenceRegistry = .{},

    fn resetState(self: *@This()) void {
        self.registry = meta.TypeRegistry.init(self.entry_storage[0..]) catch unreachable;
        self.reference.reset();
        assert(self.registry.len() == 0);
        assert(self.registry.capacity() == max_entries);
    }

    fn validate(self: *@This()) checker.CheckResult {
        var digest: u128 = foldDigest(0, self.registry.len());
        digest = foldDigest(digest, self.registry.capacity());

        if (self.registry.len() != self.reference.len) {
            return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
        }

        const actual_list = self.registry.list();
        if (actual_list.len != self.reference.len) {
            return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
        }

        for (self.reference.list(), 0..) |kind, index| {
            const actual = actual_list[index];
            expectEntryMatchesKind(kind, actual) catch {
                return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
            };
            digest = foldDigest(digest, actual.type_id);
            digest = foldDigest(digest, actual.runtime_fingerprint64);
            digest = foldDigest(digest, actual.stable_version orelse 0);
        }

        for (registry_kinds) |kind| {
            const id = typeId(kind);
            const expected_present = self.reference.containsId(id);
            const actual_present = self.registry.contains(id);
            if (actual_present != expected_present) {
                return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
            }

            if (expected_present) {
                const actual_entry = self.registry.get(id) catch {
                    return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
                };
                expectEntryMatchesKind(kind, actual_entry) catch {
                    return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
                };
            } else {
                if (self.registry.get(id)) |_| {
                    return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
                } else |err| switch (err) {
                    error.NotFound => {},
                    else => return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest)),
                }
            }
        }

        const missing_id = meta.type_id.fromName("tests/static_meta/missing");
        if (self.registry.contains(missing_id)) {
            return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
        }
        if (self.registry.get(missing_id)) |_| {
            return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest));
        } else |err| switch (err) {
            error.NotFound => {},
            else => return checker.CheckResult.fail(&registry_violation, checker.CheckpointDigest.init(digest)),
        }

        return checker.CheckResult.pass(checker.CheckpointDigest.init(digest));
    }

    fn registerKind(self: *@This(), kind: RegistryKind) checker.CheckResult {
        const expected = self.reference.register(kind);
        const actual = self.registry.register(entryForKind(kind));
        if (expected) |_| {
            if (actual) |_| {} else |_| {
                return checker.CheckResult.fail(&registry_violation, null);
            }
        } else |expected_err| {
            if (actual) |_| {
                return checker.CheckResult.fail(&registry_violation, null);
            } else |actual_err| {
                if (actual_err != expected_err) {
                    return checker.CheckResult.fail(&registry_violation, null);
                }
            }
        }
        return self.validate();
    }

    fn verifyKind(self: *@This(), kind: RegistryKind) checker.CheckResult {
        const id = typeId(kind);
        const expected_present = self.reference.containsId(id);
        const actual_present = self.registry.contains(id);
        if (actual_present != expected_present) {
            return checker.CheckResult.fail(&registry_violation, null);
        }

        if (expected_present) {
            const actual_entry = self.registry.get(id) catch {
                return checker.CheckResult.fail(&registry_violation, null);
            };
            expectEntryMatchesKind(kind, actual_entry) catch {
                return checker.CheckResult.fail(&registry_violation, null);
            };
        } else {
            if (self.registry.get(id)) |_| {
                return checker.CheckResult.fail(&registry_violation, null);
            } else |err| switch (err) {
                error.NotFound => {},
                else => return checker.CheckResult.fail(&registry_violation, null),
            }
        }

        return self.validate();
    }

    fn checkMissingLookup(self: *@This()) checker.CheckResult {
        const missing_id = meta.type_id.fromName("tests/static_meta/missing");
        if (self.registry.contains(missing_id)) {
            return checker.CheckResult.fail(&registry_violation, null);
        }
        if (self.registry.get(missing_id)) |_| {
            return checker.CheckResult.fail(&registry_violation, null);
        } else |err| switch (err) {
            error.NotFound => {},
            else => return checker.CheckResult.fail(&registry_violation, null),
        }
        return self.validate();
    }
};

test "static_meta registry runtime sequences stay aligned with testing.model" {
    const Target = model.ModelTarget(error{});
    const Runner = model.ModelRunner(error{});

    var context = Context{};
    context.resetState();

    var action_storage: [24]model.RecordedAction = undefined;
    var reduction_scratch: [24]model.RecordedAction = undefined;

    const summary = try model.runModelCases(error{}, Runner{
        .config = .{
            .package_name = "static_meta",
            .run_name = "registry_runtime_sequences",
            .base_seed = .init(0x7354_4d44_0000_0001),
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

    try testing.expectEqual(@as(u32, 96), summary.executed_case_count);
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
    var prng = std.Random.DefaultPrng.init(action_seed.value ^ 0x7354_4d45_5441_0002);
    const random = prng.random();
    const tag: ActionTag = switch (random.uintLessThan(u32, 9)) {
        0 => .register_alpha,
        1 => .assert_alpha,
        2 => .register_beta,
        3 => .assert_beta,
        4 => .register_gamma,
        5 => .assert_gamma,
        6 => .missing_lookup,
        7 => .register_overflow,
        else => .reset_registry,
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
        .register_alpha => context.registerKind(.alpha),
        .assert_alpha => context.verifyKind(.alpha),
        .register_beta => context.registerKind(.beta),
        .assert_beta => context.verifyKind(.beta),
        .register_gamma => context.registerKind(.gamma),
        .assert_gamma => context.verifyKind(.gamma),
        .missing_lookup => context.checkMissingLookup(),
        .register_overflow => context.registerKind(.overflow),
        .reset_registry => blk: {
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
            .register_alpha => "register_alpha",
            .assert_alpha => "assert_alpha",
            .register_beta => "register_beta",
            .assert_beta => "assert_beta",
            .register_gamma => "register_gamma",
            .assert_gamma => "assert_gamma",
            .missing_lookup => "missing_lookup",
            .register_overflow => "register_overflow",
            .reset_registry => "reset_registry",
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

fn typeId(kind: RegistryKind) meta.TypeId {
    return switch (kind) {
        .alpha => meta.type_id.fromType(TypeAlpha),
        .beta => meta.type_id.fromType(TypeBeta),
        .gamma => meta.type_id.fromType(TypeGamma),
        .overflow => meta.type_id.fromType(TypeOverflow),
    };
}

fn entryForKind(kind: RegistryKind) meta.Entry {
    return switch (kind) {
        .alpha => entryForType(TypeAlpha),
        .beta => entryForType(TypeBeta),
        .gamma => entryForType(TypeGamma),
        .overflow => entryForType(TypeOverflow),
    };
}

fn entryForType(comptime T: type) meta.Entry {
    const stable = meta.type_name.requireStableIdentity(T);
    return .{
        .type_id = meta.type_id.fromType(T),
        .runtime_name = @typeName(T),
        .runtime_fingerprint64 = meta.type_fingerprint.runtime64(T),
        .stable_name = stable.name,
        .stable_version = stable.version,
        .stable_fingerprint64 = meta.type_fingerprint.stable64Required(T),
    };
}

fn expectEntryMatchesKind(kind: RegistryKind, entry: meta.Entry) !void {
    switch (kind) {
        .alpha => try expectEntryMatchesType(TypeAlpha, entry),
        .beta => try expectEntryMatchesType(TypeBeta, entry),
        .gamma => try expectEntryMatchesType(TypeGamma, entry),
        .overflow => try expectEntryMatchesType(TypeOverflow, entry),
    }
}

fn expectEntryMatchesType(comptime T: type, entry: meta.Entry) !void {
    try testing.expectEqual(meta.type_id.fromType(T), entry.type_id);
    try testing.expectEqualStrings(@typeName(T), entry.runtime_name);
    try testing.expectEqual(meta.type_fingerprint.runtime64(T), entry.runtime_fingerprint64);
    try testing.expectEqualStrings(@field(T, "static_name"), entry.stable_name.?);
    try testing.expectEqual(@field(T, "static_version"), entry.stable_version.?);
    try testing.expectEqual(meta.type_fingerprint.stable64Required(T), entry.stable_fingerprint64.?);
}

fn foldDigest(digest: u128, value: anytype) u128 {
    const widened: u128 = @as(u128, @intCast(value));
    const next = (digest ^ (widened +% 0x9e37_79b9_7f4a_7c15)) *% 0x0000_0001_0000_01b3;
    assert(next == (digest ^ (widened +% 0x9e37_79b9_7f4a_7c15)) *% 0x0000_0001_0000_01b3);
    assert(next != digest or widened == 0);
    return next;
}
