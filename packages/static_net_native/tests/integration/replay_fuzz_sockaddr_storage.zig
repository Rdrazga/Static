const std = @import("std");
const testing = std.testing;
const static_net_native = @import("static_net_native");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const corpus = static_testing.testing.corpus;
const failure_bundle = static_testing.testing.failure_bundle;
const fuzz_runner = static_testing.testing.fuzz_runner;
const identity = static_testing.testing.identity;
const replay_artifact = static_testing.testing.replay_artifact;
const replay_runner = static_testing.testing.replay_runner;
const support = @import("support.zig");

const invariant_case_count: u32 = 160;

const storage_violation = [_]checker.Violation{
    .{
        .code = "static_net_native.sockaddr_storage",
        .message = "native sockaddr conversion lost endpoint roundtrip or invalid-family invariants",
    },
};

const retained_invalid_violation = [_]checker.Violation{
    .{
        .code = "static_net_native.retained_invalid_family",
        .message = "retained invalid-family sockaddr reproducer",
    },
};

const RetainedTargetError = error{
    UnexpectedRetainedCase,
};

const CaseCheck = struct {
    digest: u64,
    violations: ?[]const checker.Violation = null,
};

const RetainedInvalidCase = struct {
    label: []const u8,
    digest: u128,
    violations: []const checker.Violation,
    storage_case: StorageCase,
};

const StorageCase = union(enum) {
    windows_roundtrip: support.Endpoint,
    windows_any_v4,
    windows_any_v6,
    windows_invalid_family,
    posix_roundtrip: support.Endpoint,
    posix_invalid_family,
    linux_roundtrip: support.Endpoint,
    linux_invalid_family,
};

test "static_net_native sockaddr storage invariants stay replayable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var artifact_buffer: [640]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const summary = try (Runner{
        .config = .{
            .package_name = "static_net_native",
            .run_name = "sockaddr_storage_invariants",
            .base_seed = .init(0x6e47_6e61_7469_0001),
            .build_mode = .debug,
            .case_count_max = invariant_case_count,
        },
        .target = .{
            .context = undefined,
            .run_fn = InvariantTarget.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_net_native_sockaddr" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }).run();

    try expectNoFailureOrReplay(io, tmp_dir.dir, summary);
    try testing.expectEqual(invariant_case_count, summary.executed_case_count);
}

test "static_net_native retained invalid-family bundles preserve replay metadata" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var artifact_buffer: [640]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(RetainedTargetError, error{});
    const summary = try (Runner{
        .config = .{
            .package_name = "static_net_native",
            .run_name = "retained_invalid_family",
            .base_seed = .init(0x6e47_6e61_7469_0002),
            .build_mode = .debug,
            .case_count_max = 8,
        },
        .target = .{
            .context = undefined,
            .run_fn = RetainedInvalidTarget.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_net_native_retained" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }).run();

    try testing.expectEqual(@as(u32, 1), summary.executed_case_count);
    try testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try testing.expect(failed_case.persisted_entry_name != null);

    const retained_case = buildRetainedInvalidCase(failed_case.run_identity.seed.value);
    try testing.expect(retainedInvalidCaseMatches(retained_case));

    var corpus_buffer: [640]u8 = undefined;
    const entry = try corpus.readCorpusEntry(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        &corpus_buffer,
    );
    try testing.expectEqual(
        failed_case.run_identity.seed.value,
        entry.artifact.identity.seed.value,
    );

    const replay_outcome = try replay_runner.runReplay(
        RetainedTargetError,
        corpus_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))],
        .{
            .context = undefined,
            .run_fn = RetainedInvalidTarget.replay,
        },
        .{
            .expected_identity_hash = entry.meta.identity_hash,
        },
    );
    try testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, replay_outcome);

    var bundle_entry_name_buffer: [128]u8 = undefined;
    var bundle_artifact_buffer: [640]u8 = undefined;
    var bundle_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var bundle_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var bundle_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    const bundle_meta = try failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "static_net_native_bundle" },
        .entry_name_buffer = &bundle_entry_name_buffer,
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &bundle_manifest_buffer,
        .trace_buffer = &bundle_trace_buffer,
        .violations_buffer = &bundle_violations_buffer,
    }, failed_case.run_identity, failed_case.trace_metadata, failed_case.check_result, .{
        .campaign_profile = "sockaddr_storage",
        .scenario_variant_label = retained_case.label,
    });

    var read_manifest_source: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_violations_source: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const bundle = try failure_bundle.readFailureBundle(io, tmp_dir.dir, bundle_meta.entry_name, .{
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try testing.expectEqualStrings("static_net_native", bundle.manifest_document.package_name);
    try testing.expectEqualStrings("retained_invalid_family", bundle.manifest_document.run_name);
    try testing.expectEqualStrings(retained_case.label, bundle.manifest_document.scenario_variant_label.?);
    try testing.expectEqual(
        failed_case.run_identity.seed.value,
        bundle.replay_artifact_view.identity.seed.value,
    );
    try testing.expect(bundle.trace_document != null);
    try testing.expectEqualStrings(
        failed_case.check_result.violations[0].code,
        bundle.violations_document.violations[0].code,
    );
}

const InvariantTarget = struct {
    fn run(
        _: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const evaluation = evaluateInvariantCase(run_identity.seed.value);
        return .{
            .trace_metadata = support.makeTraceMetadata(
                run_identity,
                1,
                evaluation.checkpoint_digest.value,
            ),
            .check_result = evaluation.toCheckResult(),
        };
    }

    fn replay(
        _: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution {
        const evaluation = evaluateInvariantCase(artifact.identity.seed.value);
        return .{
            .trace_metadata = support.makeTraceMetadata(
                artifact.identity,
                1,
                evaluation.checkpoint_digest.value,
            ),
            .check_result = evaluation.toCheckResult(),
        };
    }
};

const RetainedInvalidTarget = struct {
    fn run(
        _: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) RetainedTargetError!fuzz_runner.FuzzExecution {
        const retained_case = buildRetainedInvalidCase(run_identity.seed.value);
        if (!retainedInvalidCaseMatches(retained_case)) {
            return error.UnexpectedRetainedCase;
        }
        return .{
            .trace_metadata = support.makeTraceMetadata(
                run_identity,
                1,
                retained_case.digest,
            ),
            .check_result = checker.CheckResult.fail(
                retained_case.violations,
                checker.CheckpointDigest.init(retained_case.digest),
            ),
        };
    }

    fn replay(
        _: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) RetainedTargetError!replay_runner.ReplayExecution {
        const retained_case = buildRetainedInvalidCase(artifact.identity.seed.value);
        if (!retainedInvalidCaseMatches(retained_case)) {
            return error.UnexpectedRetainedCase;
        }
        return .{
            .trace_metadata = support.makeTraceMetadata(
                artifact.identity,
                1,
                retained_case.digest,
            ),
            .check_result = checker.CheckResult.fail(
                retained_case.violations,
                checker.CheckpointDigest.init(retained_case.digest),
            ),
        };
    }
};

const Evaluation = struct {
    checkpoint_digest: checker.CheckpointDigest,
    violations: ?[]const checker.Violation,

    fn toCheckResult(self: Evaluation) checker.CheckResult {
        if (self.violations) |violations| {
            return checker.CheckResult.fail(violations, self.checkpoint_digest);
        }
        return checker.CheckResult.pass(self.checkpoint_digest);
    }
};

fn expectNoFailureOrReplay(
    io: std.Io,
    dir: std.Io.Dir,
    summary: fuzz_runner.FuzzRunSummary,
) !void {
    if (summary.failed_case) |failed_case| {
        try testing.expect(failed_case.persisted_entry_name != null);

        var read_buffer: [640]u8 = undefined;
        const entry = try corpus.readCorpusEntry(
            io,
            dir,
            failed_case.persisted_entry_name.?,
            &read_buffer,
        );
        const outcome = try replay_runner.runReplay(
            error{},
            read_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))],
            .{
                .context = undefined,
                .run_fn = InvariantTarget.replay,
            },
            .{
                .expected_identity_hash = entry.meta.identity_hash,
            },
        );
        try testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, outcome);
        return error.TestUnexpectedResult;
    }
}

fn evaluateInvariantCase(seed_value: u64) Evaluation {
    const storage_case = buildStorageCase(seed_value);
    const check = evaluateStorageCase(storage_case);
    return .{
        .checkpoint_digest = checker.CheckpointDigest.init(check.digest),
        .violations = check.violations,
    };
}

fn buildStorageCase(seed_value: u64) StorageCase {
    return switch (seed_value % 8) {
        0 => .{ .windows_roundtrip = support.buildIpv4Endpoint(seed_value ^ 0x1001) },
        1 => .{ .windows_roundtrip = support.buildIpv6Endpoint(seed_value ^ 0x1002) },
        2 => if ((seed_value & 1) == 0) .windows_any_v4 else .windows_any_v6,
        3 => .windows_invalid_family,
        4 => .{ .posix_roundtrip = support.buildIpv4Endpoint(seed_value ^ 0x1003) },
        5 => .{ .posix_roundtrip = support.buildIpv6Endpoint(seed_value ^ 0x1004) },
        6 => if ((seed_value & 1) == 0)
            .{ .linux_roundtrip = support.buildIpv4Endpoint(seed_value ^ 0x1005) }
        else
            .{ .linux_roundtrip = support.buildIpv6Endpoint(seed_value ^ 0x1006) },
        else => if ((seed_value & 1) == 0) .posix_invalid_family else .linux_invalid_family,
    };
}

fn evaluateStorageCase(storage_case: StorageCase) CaseCheck {
    return switch (storage_case) {
        .windows_roundtrip => |endpoint| evaluateWindowsRoundtrip(endpoint),
        .windows_any_v4 => evaluateWindowsAnyFamily(std.os.windows.ws2_32.AF.INET),
        .windows_any_v6 => evaluateWindowsAnyFamily(std.os.windows.ws2_32.AF.INET6),
        .windows_invalid_family => evaluateWindowsInvalidFamily(),
        .posix_roundtrip => |endpoint| evaluatePosixRoundtrip(endpoint),
        .posix_invalid_family => evaluatePosixInvalidFamily(),
        .linux_roundtrip => |endpoint| evaluateLinuxRoundtrip(endpoint),
        .linux_invalid_family => evaluateLinuxInvalidFamily(),
    };
}

fn evaluateWindowsRoundtrip(endpoint: support.Endpoint) CaseCheck {
    const sockaddr = static_net_native.windows.SockaddrAny.fromEndpoint(endpoint);
    const storage: *const std.os.windows.ws2_32.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    const roundtrip = static_net_native.windows.endpointFromStorage(storage);
    var digest = support.foldDigest(0x7769_6e64_6f77_7300, support.digestEndpoint(endpoint));
    digest = support.foldDigest(digest, @as(u64, @intCast(sockaddr.len())));

    if (roundtrip == null or !std.meta.eql(endpoint, roundtrip.?)) {
        return .{
            .digest = digest,
            .violations = &storage_violation,
        };
    }

    const expected_len: i32 = switch (endpoint) {
        .ipv4 => @sizeOf(std.os.windows.ws2_32.sockaddr.in),
        .ipv6 => @sizeOf(std.os.windows.ws2_32.sockaddr.in6),
    };
    if (sockaddr.len() != expected_len) {
        return .{
            .digest = support.foldDigest(digest, @as(u64, @intCast(expected_len))),
            .violations = &storage_violation,
        };
    }
    return .{ .digest = digest };
}

fn evaluateWindowsAnyFamily(family: i32) CaseCheck {
    const sockaddr = static_net_native.windows.SockaddrAny.anyForFamily(family);
    var digest = support.foldDigest(0x7769_6e64_616e_7900, @as(u64, @intCast(family)));
    digest = support.foldDigest(digest, @as(u64, @intCast(sockaddr.len())));

    if (family == std.os.windows.ws2_32.AF.INET) {
        if (sockaddr != .ipv4 or sockaddr.ipv4.port != 0 or sockaddr.ipv4.addr != 0) {
            return .{
                .digest = digest,
                .violations = &storage_violation,
            };
        }
        return .{ .digest = digest };
    }

    if (sockaddr != .ipv6 or sockaddr.ipv6.port != 0 or sockaddr.ipv6.flowinfo != 0 or sockaddr.ipv6.scope_id != 0) {
        return .{
            .digest = digest,
            .violations = &storage_violation,
        };
    }
    return .{ .digest = digest };
}

fn evaluateWindowsInvalidFamily() CaseCheck {
    var storage = std.mem.zeroes(std.os.windows.ws2_32.sockaddr.storage);
    storage.family = 255;
    if (static_net_native.windows.endpointFromStorage(&storage) != null) {
        return .{
            .digest = 0x7769_6e64_6261_6400,
            .violations = &storage_violation,
        };
    }
    return .{ .digest = 0x7769_6e64_6261_6400 };
}

fn evaluatePosixRoundtrip(endpoint: support.Endpoint) CaseCheck {
    const sockaddr = static_net_native.posix.SockaddrAny.fromEndpoint(endpoint);
    const storage: *const std.posix.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    const roundtrip = static_net_native.posix.endpointFromStorage(storage);
    var digest = support.foldDigest(0x706f_7369_7800_0000, support.digestEndpoint(endpoint));
    digest = support.foldDigest(digest, @as(u64, @intCast(sockaddr.len())));

    if (roundtrip == null or !std.meta.eql(endpoint, roundtrip.?)) {
        return .{
            .digest = digest,
            .violations = &storage_violation,
        };
    }

    const expected_len: std.posix.socklen_t = switch (endpoint) {
        .ipv4 => @sizeOf(std.posix.sockaddr.in),
        .ipv6 => @sizeOf(std.posix.sockaddr.in6),
    };
    if (sockaddr.len() != expected_len) {
        return .{
            .digest = support.foldDigest(digest, @as(u64, @intCast(expected_len))),
            .violations = &storage_violation,
        };
    }
    return .{ .digest = digest };
}

fn evaluatePosixInvalidFamily() CaseCheck {
    var storage = std.mem.zeroes(std.posix.sockaddr.storage);
    storage.family = 255;
    if (static_net_native.posix.endpointFromStorage(&storage) != null) {
        return .{
            .digest = 0x706f_7369_7862_6164,
            .violations = &storage_violation,
        };
    }
    return .{ .digest = 0x706f_7369_7862_6164 };
}

fn evaluateLinuxRoundtrip(endpoint: support.Endpoint) CaseCheck {
    const sockaddr = static_net_native.linux.SockaddrAny.fromEndpoint(endpoint);
    const storage: *const std.os.linux.sockaddr.storage = @ptrCast(@alignCast(sockaddr.ptr()));
    const roundtrip = static_net_native.linux.endpointFromStorage(storage);
    var digest = support.foldDigest(0x6c69_6e75_7800_0000, support.digestEndpoint(endpoint));
    digest = support.foldDigest(digest, @as(u64, @intCast(sockaddr.len())));

    if (roundtrip == null or !std.meta.eql(endpoint, roundtrip.?)) {
        return .{
            .digest = digest,
            .violations = &storage_violation,
        };
    }

    const expected_len: std.os.linux.socklen_t = switch (endpoint) {
        .ipv4 => @sizeOf(std.os.linux.sockaddr.in),
        .ipv6 => @sizeOf(std.os.linux.sockaddr.in6),
    };
    if (sockaddr.len() != expected_len) {
        return .{
            .digest = support.foldDigest(digest, @as(u64, @intCast(expected_len))),
            .violations = &storage_violation,
        };
    }
    return .{ .digest = digest };
}

fn evaluateLinuxInvalidFamily() CaseCheck {
    var storage = std.mem.zeroes(std.os.linux.sockaddr.storage);
    storage.family = 255;
    if (static_net_native.linux.endpointFromStorage(&storage) != null) {
        return .{
            .digest = 0x6c69_6e75_7862_6164,
            .violations = &storage_violation,
        };
    }
    return .{ .digest = 0x6c69_6e75_7862_6164 };
}

fn buildRetainedInvalidCase(seed_value: u64) RetainedInvalidCase {
    const storage_case: StorageCase = switch (seed_value % 3) {
        0 => .windows_invalid_family,
        1 => .posix_invalid_family,
        else => .linux_invalid_family,
    };
    const label = switch (storage_case) {
        .windows_invalid_family => "windows_invalid_family",
        .posix_invalid_family => "posix_invalid_family",
        .linux_invalid_family => "linux_invalid_family",
        else => unreachable,
    };
    return .{
        .label = label,
        .digest = @as(u128, support.foldDigest(0x7265_7461_696e_6564, support.digestBytes(label))),
        .violations = &retained_invalid_violation,
        .storage_case = storage_case,
    };
}

fn retainedInvalidCaseMatches(retained_case: RetainedInvalidCase) bool {
    const check = evaluateStorageCase(retained_case.storage_case);
    return check.violations == null;
}
