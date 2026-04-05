const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_string = @import("static_string");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const corpus = static_testing.testing.corpus;
const failure_bundle = static_testing.testing.failure_bundle;
const fuzz_runner = static_testing.testing.fuzz_runner;
const identity = static_testing.testing.identity;
const replay_artifact = static_testing.testing.replay_artifact;
const replay_runner = static_testing.testing.replay_runner;
const trace = static_testing.testing.trace;
const support = @import("support.zig");

const invariant_case_count: u32 = 192;
const max_text_bytes: usize = 16;
const max_buffer_bytes: usize = 16;

const text_violation = [_]checker.Violation{
    .{
        .code = "static_string.text_invariants",
        .message = "text validation, normalization, or bounded append invariants diverged from the bounded reference behavior",
    },
};

const retained_invalid_utf8_violation = [_]checker.Violation{
    .{
        .code = "static_string.retained_invalid_utf8",
        .message = "retained invalid utf8 reproducer",
    },
};

const ByteCase = struct {
    bytes: [max_text_bytes]u8 = [_]u8{0} ** max_text_bytes,
    len: u8 = 0,

    fn slice(self: *const @This()) []const u8 {
        assert(self.len <= self.bytes.len);
        const result = self.bytes[0..self.len];
        assert(result.len == self.len);
        return result;
    }
};

const BufferMode = enum(u8) {
    append = 1,
    append_fmt = 2,
    append_byte = 3,
};

const BufferCase = struct {
    capacity: u8 = 0,
    prefix: [max_buffer_bytes]u8 = [_]u8{0} ** max_buffer_bytes,
    prefix_len: u8 = 0,
    suffix: [max_buffer_bytes]u8 = [_]u8{0} ** max_buffer_bytes,
    suffix_len: u8 = 0,
    mode: BufferMode = .append,

    fn prefixSlice(self: *const @This()) []const u8 {
        assert(self.prefix_len <= self.capacity);
        return self.prefix[0..self.prefix_len];
    }

    fn suffixSlice(self: *const @This()) []const u8 {
        assert(self.suffix_len <= self.suffix.len);
        return self.suffix[0..self.suffix_len];
    }
};

const TextCase = union(enum) {
    utf8: ByteCase,
    ascii: ByteCase,
    buffer: BufferCase,
};

const RetainedInvalidUtf8Case = struct {
    label: []const u8,
    digest: u128,
    violations: []const checker.Violation,
    byte_case: ByteCase,
};

const Evaluation = struct {
    violations: ?[]const checker.Violation = null,
    checkpoint_digest: checker.CheckpointDigest,
    event_count: u32,

    fn toCheckResult(self: @This()) checker.CheckResult {
        if (self.violations) |violations| {
            return checker.CheckResult.fail(violations, self.checkpoint_digest);
        }
        return checker.CheckResult.pass(self.checkpoint_digest);
    }
};

test "static_string deterministic malformed text invariants stay replayable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const summary = try (Runner{
        .config = .{
            .package_name = "static_string",
            .run_name = "malformed_text_invariants",
            .base_seed = .init(0x5737_7269_6e67_0001),
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
            .naming = .{ .prefix = "static_string_text" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }).run();

    try expectNoFailureOrReplay(io, tmp_dir.dir, summary);
    try testing.expectEqual(invariant_case_count, summary.executed_case_count);
}

test "static_string retained invalid utf8 bundles preserve replay metadata" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const summary = try (Runner{
        .config = .{
            .package_name = "static_string",
            .run_name = "retained_invalid_utf8",
            .base_seed = .init(0x5737_7269_6e67_0002),
            .build_mode = .debug,
            .case_count_max = 8,
        },
        .target = .{
            .context = undefined,
            .run_fn = RetainedInvalidUtf8Target.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_string_retained" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }).run();

    try testing.expectEqual(@as(u32, 1), summary.executed_case_count);
    try testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try testing.expect(failed_case.persisted_entry_name != null);

    const retained_case = buildRetainedInvalidUtf8Case(failed_case.run_identity.seed.value);
    try testing.expect(!static_string.utf8.isValid(retained_case.byte_case.slice()));
    try testing.expect(!std.unicode.utf8ValidateSlice(retained_case.byte_case.slice()));

    var corpus_buffer: [512]u8 = undefined;
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

    const replay_outcome = try replay_runner.runReplay(error{}, corpus_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))], .{
        .context = undefined,
        .run_fn = RetainedInvalidUtf8Target.replay,
    }, .{
        .expected_identity_hash = entry.meta.identity_hash,
    });
    try testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, replay_outcome);

    var bundle_entry_name_buffer: [128]u8 = undefined;
    var bundle_artifact_buffer: [512]u8 = undefined;
    var bundle_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var bundle_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var bundle_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    const bundle_meta = try failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "static_string_bundle" },
        .entry_name_buffer = &bundle_entry_name_buffer,
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &bundle_manifest_buffer,
        .trace_buffer = &bundle_trace_buffer,
        .violations_buffer = &bundle_violations_buffer,
    }, failed_case.run_identity, failed_case.trace_metadata, failed_case.check_result, .{
        .campaign_profile = "text_validation",
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

    try testing.expectEqualStrings("static_string", bundle.manifest_document.package_name);
    try testing.expectEqualStrings("retained_invalid_utf8", bundle.manifest_document.run_name);
    try testing.expectEqualStrings(retained_case.label, bundle.manifest_document.scenario_variant_label.?);
    try testing.expectEqual(
        failed_case.run_identity.seed.value,
        bundle.replay_artifact_view.identity.seed.value,
    );
}

const InvariantTarget = struct {
    fn run(
        _: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const evaluation = evaluateInvariantCase(run_identity.seed.value);
        return .{
            .trace_metadata = makeTraceMetadata(
                run_identity,
                evaluation.event_count,
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
            .trace_metadata = makeTraceMetadata(
                artifact.identity,
                evaluation.event_count,
                evaluation.checkpoint_digest.value,
            ),
            .check_result = evaluation.toCheckResult(),
        };
    }
};

const RetainedInvalidUtf8Target = struct {
    fn run(
        _: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const retained_case = buildRetainedInvalidUtf8Case(run_identity.seed.value);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity, 1, retained_case.digest),
            .check_result = checker.CheckResult.fail(
                retained_case.violations,
                checker.CheckpointDigest.init(retained_case.digest),
            ),
        };
    }

    fn replay(
        _: *const anyopaque,
        artifact: replay_artifact.ReplayArtifactView,
    ) error{}!replay_runner.ReplayExecution {
        const retained_case = buildRetainedInvalidUtf8Case(artifact.identity.seed.value);
        return .{
            .trace_metadata = makeTraceMetadata(artifact.identity, 1, retained_case.digest),
            .check_result = checker.CheckResult.fail(
                retained_case.violations,
                checker.CheckpointDigest.init(retained_case.digest),
            ),
        };
    }
};

fn expectNoFailureOrReplay(
    io: std.Io,
    dir: std.Io.Dir,
    summary: fuzz_runner.FuzzRunSummary,
) !void {
    if (summary.failed_case) |failed_case| {
        try testing.expect(failed_case.persisted_entry_name != null);

        var read_buffer: [512]u8 = undefined;
        const entry = try corpus.readCorpusEntry(
            io,
            dir,
            failed_case.persisted_entry_name.?,
            &read_buffer,
        );
        const outcome = try replay_runner.runReplay(error{}, read_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))], .{
            .context = undefined,
            .run_fn = InvariantTarget.replay,
        }, .{
            .expected_identity_hash = entry.meta.identity_hash,
        });
        try testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, outcome);
        return error.TestUnexpectedResult;
    }
}

fn evaluateInvariantCase(seed_value: u64) Evaluation {
    const text_case = buildInvariantCase(seed_value);
    return switch (text_case) {
        .utf8 => |byte_case| evaluateUtf8Case(byte_case),
        .ascii => |byte_case| evaluateAsciiCase(byte_case),
        .buffer => |buffer_case| evaluateBufferCase(buffer_case),
    };
}

fn evaluateUtf8Case(byte_case: ByteCase) Evaluation {
    const bytes = byte_case.slice();
    const expected_valid = std.unicode.utf8ValidateSlice(bytes);
    const actual_valid = static_string.utf8.isValid(bytes);
    const validate_result = static_string.utf8.validate(bytes);
    const digest = support.foldDigest(
        0x7574_6638_0000_0001,
        support.digestBytes(bytes),
    );
    const checkpoint = checker.CheckpointDigest.init(@as(u128, digest));

    if (actual_valid != expected_valid) {
        return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 1 };
    }

    if (expected_valid) {
        if (validate_result) |_| {} else |_| {
            return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 2 };
        }
    } else {
        if (validate_result) |_| {
            return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 2 };
        } else |err| {
            if (err != error.InvalidInput) {
                return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 2 };
            }
        }
    }

    return .{ .checkpoint_digest = checkpoint, .event_count = 2 };
}

fn evaluateAsciiCase(byte_case: ByteCase) Evaluation {
    const bytes = byte_case.slice();
    const expected_is_ascii = referenceIsAscii(bytes);
    const actual_is_ascii = static_string.ascii.isAscii(bytes);
    const trimmed_actual = static_string.ascii.trimWhitespace(bytes);
    const trimmed_reference = support.manualTrimWhitespace(bytes);

    var lowered_actual_storage: [max_text_bytes]u8 = [_]u8{0} ** max_text_bytes;
    var lowered_reference_storage: [max_text_bytes]u8 = [_]u8{0} ** max_text_bytes;
    _ = support.copyBytes(lowered_actual_storage[0..bytes.len], bytes);
    static_string.ascii.toLowerInPlace(lowered_actual_storage[0..bytes.len]);
    const lowered_reference = support.manualLower(bytes, lowered_reference_storage[0..]);
    const digest = support.foldDigest(
        support.foldDigest(0x6173_6369_6900_0002, support.digestBytes(bytes)),
        support.digestBytes(lowered_actual_storage[0..bytes.len]),
    );
    const checkpoint = checker.CheckpointDigest.init(@as(u128, digest));

    if (expected_is_ascii != actual_is_ascii) {
        return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 1 };
    }
    if (!std.mem.eql(u8, trimmed_actual, trimmed_reference)) {
        return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 2 };
    }
    if (!std.mem.eql(u8, lowered_actual_storage[0..bytes.len], lowered_reference)) {
        return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 3 };
    }
    if (!support.manualEqIgnoreCase(bytes, lowered_reference)) {
        return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 4 };
    }

    return .{ .checkpoint_digest = checkpoint, .event_count = 4 };
}

fn evaluateBufferCase(buffer_case: BufferCase) Evaluation {
    var storage: [max_buffer_bytes]u8 = [_]u8{0} ** max_buffer_bytes;
    var buffer = static_string.BoundedBuffer.init(storage[0..buffer_case.capacity]);
    buffer.append(buffer_case.prefixSlice()) catch {
        const digest = support.foldDigest(0x6275_6666_6572_0003, support.digestBytes(buffer_case.prefixSlice()));
        return .{
            .violations = &text_violation,
            .checkpoint_digest = checker.CheckpointDigest.init(@as(u128, digest)),
            .event_count = 1,
        };
    };

    const before_len = buffer.len();
    var before_bytes: [max_buffer_bytes]u8 = [_]u8{0} ** max_buffer_bytes;
    _ = support.copyBytes(before_bytes[0..before_len], buffer.bytes());

    const expected_extra_len: usize = switch (buffer_case.mode) {
        .append => buffer_case.suffix_len,
        .append_fmt => buffer_case.suffix_len,
        .append_byte => if (buffer_case.suffix_len == 0) 0 else 1,
    };
    const expected_success = before_len + expected_extra_len <= buffer_case.capacity;

    switch (buffer_case.mode) {
        .append => {
            if (expected_success) {
                tryExpectBufferOk(buffer.append(buffer_case.suffixSlice()));
            } else {
                tryExpectBufferNoSpace(buffer.append(buffer_case.suffixSlice()));
            }
        },
        .append_fmt => {
            if (expected_success) {
                tryExpectBufferOk(buffer.appendFmt("{s}", .{buffer_case.suffixSlice()}));
            } else {
                tryExpectBufferNoSpace(buffer.appendFmt("{s}", .{buffer_case.suffixSlice()}));
            }
        },
        .append_byte => {
            const byte = if (buffer_case.suffix_len == 0) 'x' else buffer_case.suffix[0];
            if (expected_success) {
                tryExpectBufferOk(buffer.appendByte(byte));
            } else {
                tryExpectBufferNoSpace(buffer.appendByte(byte));
            }
        },
    }

    var expected_bytes: [max_buffer_bytes]u8 = [_]u8{0} ** max_buffer_bytes;
    _ = support.copyBytes(expected_bytes[0..before_len], before_bytes[0..before_len]);
    var expected_len = before_len;
    if (expected_success) {
        switch (buffer_case.mode) {
            .append, .append_fmt => {
                _ = support.copyBytes(
                    expected_bytes[before_len .. before_len + buffer_case.suffix_len],
                    buffer_case.suffixSlice(),
                );
                expected_len += buffer_case.suffix_len;
            },
            .append_byte => {
                const byte = if (buffer_case.suffix_len == 0) 'x' else buffer_case.suffix[0];
                expected_bytes[before_len] = byte;
                expected_len += 1;
            },
        }
    }

    const digest = support.foldDigest(
        support.foldDigest(0x6275_6666_6572_0003, buffer_case.capacity),
        support.digestBytes(buffer.bytes()),
    );
    const checkpoint = checker.CheckpointDigest.init(@as(u128, digest));

    if (buffer.len() != expected_len) {
        return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 2 };
    }
    if (!std.mem.eql(u8, expected_bytes[0..expected_len], buffer.bytes())) {
        return .{ .violations = &text_violation, .checkpoint_digest = checkpoint, .event_count = 3 };
    }

    return .{ .checkpoint_digest = checkpoint, .event_count = 3 };
}

fn buildInvariantCase(seed_value: u64) TextCase {
    return switch (seed_value % 3) {
        0 => .{ .utf8 = buildUtf8Case(seed_value ^ 0x11) },
        1 => .{ .ascii = buildAsciiCase(seed_value ^ 0x22) },
        else => .{ .buffer = buildBufferCase(seed_value ^ 0x33) },
    };
}

fn buildUtf8Case(seed_value: u64) ByteCase {
    var byte_case = ByteCase{};
    switch (seed_value % 8) {
        0 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "ascii-header")),
        1 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "caf\xc3\xa9")),
        2 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xc3")),
        3 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xe2\x28\xa1")),
        4 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xed\xa0\x80")),
        5 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xc0\x80")),
        6 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xf4\x90\x80\x80")),
        else => {
            byte_case.len = @intCast(1 + (seed_value % max_text_bytes));
            support.fillSeedBytes(byte_case.bytes[0..byte_case.len], seed_value ^ 0x99);
        },
    }
    return byte_case;
}

fn buildAsciiCase(seed_value: u64) ByteCase {
    var byte_case = ByteCase{};
    switch (seed_value % 6) {
        0 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], " \tHEADER\r\n")),
        1 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "Mixed-Case-42")),
        2 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xc3\xa9clair")),
        3 => byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], " \ttrim me\r\n")),
        else => {
            byte_case.len = @intCast(1 + (seed_value % max_text_bytes));
            support.fillSeedBytes(byte_case.bytes[0..byte_case.len], seed_value ^ 0x44);
            for (byte_case.bytes[0..byte_case.len], 0..) |*byte, index| {
                if (((seed_value >> @intCast(index % 8)) & 1) == 0) {
                    byte.* = switch (byte.* % 8) {
                        0 => ' ',
                        1 => '\t',
                        2 => 'A' + @as(u8, @intCast(index % 26)),
                        3 => 'a' + @as(u8, @intCast(index % 26)),
                        4 => '-',
                        5 => '0' + @as(u8, @intCast(index % 10)),
                        6 => '_',
                        else => '.',
                    };
                }
            }
        },
    }
    return byte_case;
}

fn buildBufferCase(seed_value: u64) BufferCase {
    var buffer_case = BufferCase{};
    buffer_case.capacity = @intCast(1 + (seed_value % max_buffer_bytes));
    buffer_case.mode = switch ((seed_value >> 3) % 3) {
        0 => .append,
        1 => .append_fmt,
        else => .append_byte,
    };

    const prefix_source = support.tokenForIndex(seed_value ^ 0x55);
    const prefix_target_len = @min(prefix_source.len, @as(usize, buffer_case.capacity));
    buffer_case.prefix_len = @intCast(prefix_target_len);
    _ = support.copyBytes(buffer_case.prefix[0..prefix_target_len], prefix_source[0..prefix_target_len]);

    const suffix_source = support.tokenForIndex(seed_value ^ 0x66);
    const suffix_target_len = @min(suffix_source.len, max_buffer_bytes);
    buffer_case.suffix_len = @intCast(suffix_target_len);
    _ = support.copyBytes(buffer_case.suffix[0..suffix_target_len], suffix_source[0..suffix_target_len]);
    return buffer_case;
}

fn buildRetainedInvalidUtf8Case(seed_value: u64) RetainedInvalidUtf8Case {
    var byte_case = ByteCase{};
    const label = switch (seed_value % 3) {
        0 => blk: {
            byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xc3"));
            break :blk "truncated_two_byte";
        },
        1 => blk: {
            byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xed\xa0\x80"));
            break :blk "surrogate_half";
        },
        else => blk: {
            byte_case.len = @intCast(support.copyBytes(byte_case.bytes[0..], "\xf4\x90\x80\x80"));
            break :blk "out_of_range";
        },
    };
    return .{
        .label = label,
        .digest = @as(u128, support.foldDigest(0x7265_7461_696e_0004, support.digestBytes(byte_case.slice()))),
        .violations = &retained_invalid_utf8_violation,
        .byte_case = byte_case,
    };
}

fn tryExpectBufferOk(result: static_string.BufferError!void) void {
    if (result) |_| {
        assert(true);
    } else |_| unreachable;
}

fn tryExpectBufferNoSpace(result: static_string.BufferError!void) void {
    if (result) |_| unreachable else |err| {
        assert(err == error.NoSpaceLeft);
    }
}

fn referenceIsAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte > 0x7f) return false;
    }
    assert(bytes.len == 0 or bytes[0] <= 0xff);
    return true;
}

fn makeTraceMetadata(
    run_identity: identity.RunIdentity,
    event_count: u32,
    checkpoint_value: u128,
) trace.TraceMetadata {
    const base = run_identity.seed.value ^ @as(u64, @truncate(checkpoint_value));
    return .{
        .event_count = event_count,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 0,
        .last_sequence_no = if (event_count == 0) 0 else event_count - 1,
        .first_timestamp_ns = base,
        .last_timestamp_ns = base + event_count,
    };
}
