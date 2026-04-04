const std = @import("std");
const static_bits = @import("static_bits");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const corpus = static_testing.testing.corpus;
const failure_bundle = static_testing.testing.failure_bundle;
const fuzz_runner = static_testing.testing.fuzz_runner;
const identity = static_testing.testing.identity;
const replay_artifact = static_testing.testing.replay_artifact;
const replay_runner = static_testing.testing.replay_runner;
const trace = static_testing.testing.trace;

const invariant_case_count: u32 = 128;
const max_runtime_bytes: usize = 16;
const max_varint_bytes: usize = 10;

const uleb_violation = [_]checker.Violation{
    .{
        .code = "static_bits.uleb_runtime",
        .message = "unsigned varint runtime decode lost slice/cursor agreement",
    },
};

const sleb_violation = [_]checker.Violation{
    .{
        .code = "static_bits.sleb_runtime",
        .message = "signed varint runtime decode lost slice/cursor agreement",
    },
};

const endian_read_violation = [_]checker.Violation{
    .{
        .code = "static_bits.endian_read_runtime",
        .message = "endian runtime reads lost direct/cursor agreement",
    },
};

const endian_write_violation = [_]checker.Violation{
    .{
        .code = "static_bits.endian_write_runtime",
        .message = "endian runtime writes lost direct/cursor agreement",
    },
};

const bit_reader_violation = [_]checker.Violation{
    .{
        .code = "static_bits.bit_reader_runtime",
        .message = "bit-reader runtime bounds or model agreement regressed",
    },
};

const retained_truncated_violation = [_]checker.Violation{
    .{
        .code = "static_bits.retained_truncated_uleb",
        .message = "retained truncated unsigned varint reproducer",
    },
};

const retained_noncanonical_violation = [_]checker.Violation{
    .{
        .code = "static_bits.retained_noncanonical_sleb",
        .message = "retained non-canonical signed varint reproducer",
    },
};

const retained_nonterminating_violation = [_]checker.Violation{
    .{
        .code = "static_bits.retained_nonterminating_uleb",
        .message = "retained non-terminating unsigned varint reproducer",
    },
};

test "static_bits deterministic malformed runtime invariants stay replayable" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const summary = try (Runner{
        .config = .{
            .package_name = "static_bits",
            .run_name = "malformed_runtime_invariants",
            .base_seed = .init(0x51A71C0_20260320),
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
            .naming = .{ .prefix = "static_bits_runtime" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }).run();

    try expectNoFailureOrReplay(io, tmp_dir.dir, summary);
    try std.testing.expectEqual(invariant_case_count, summary.executed_case_count);
}

test "static_bits retained malformed varint bundles preserve replay metadata" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const summary = try (Runner{
        .config = .{
            .package_name = "static_bits",
            .run_name = "retained_malformed_varint",
            .base_seed = .init(0xB175_2026_0320_0001),
            .build_mode = .debug,
            .case_count_max = 8,
        },
        .target = .{
            .context = undefined,
            .run_fn = RetainedMalformedTarget.run,
        },
        .persistence = .{
            .io = io,
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_bits_retained" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }).run();

    try std.testing.expectEqual(@as(u32, 1), summary.executed_case_count);
    try std.testing.expect(summary.failed_case != null);
    const failed_case = summary.failed_case.?;
    try std.testing.expect(failed_case.persisted_entry_name != null);

    const retained_case = buildRetainedMalformedCase(failed_case.run_identity.seed.value);
    try assertRetainedMalformedCase(retained_case);

    var corpus_buffer: [512]u8 = undefined;
    const entry = try corpus.readCorpusEntry(
        io,
        tmp_dir.dir,
        failed_case.persisted_entry_name.?,
        &corpus_buffer,
    );
    try std.testing.expectEqual(
        failed_case.run_identity.seed.value,
        entry.artifact.identity.seed.value,
    );

    const replay_outcome = try replay_runner.runReplay(error{}, corpus_buffer[0..@as(usize, @intCast(entry.meta.artifact_bytes_len))], .{
        .context = undefined,
        .run_fn = RetainedMalformedTarget.replay,
    }, .{
        .expected_identity_hash = entry.meta.identity_hash,
    });
    try std.testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, replay_outcome);

    var bundle_entry_name_buffer: [128]u8 = undefined;
    var bundle_artifact_buffer: [512]u8 = undefined;
    var bundle_manifest_buffer: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var bundle_trace_buffer: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var bundle_violations_buffer: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    const bundle_meta = try failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{ .prefix = "static_bits_bundle" },
        .entry_name_buffer = &bundle_entry_name_buffer,
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &bundle_manifest_buffer,
        .trace_buffer = &bundle_trace_buffer,
        .violations_buffer = &bundle_violations_buffer,
    }, failed_case.run_identity, failed_case.trace_metadata, failed_case.check_result, .{
        .campaign_profile = "malformed_runtime",
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

    try std.testing.expectEqualStrings("static_bits", bundle.manifest_document.package_name);
    try std.testing.expectEqualStrings("retained_malformed_varint", bundle.manifest_document.run_name);
    try std.testing.expectEqualStrings(retained_case.label, bundle.manifest_document.scenario_variant_label.?);
    try std.testing.expectEqual(
        failed_case.run_identity.seed.value,
        bundle.replay_artifact_view.identity.seed.value,
    );
    try std.testing.expect(bundle.trace_document != null);
    try std.testing.expectEqualStrings(
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

const RetainedMalformedTarget = struct {
    fn run(
        _: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        const retained_case = buildRetainedMalformedCase(run_identity.seed.value);
        return .{
            .trace_metadata = makeTraceMetadata(
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
    ) error{}!replay_runner.ReplayExecution {
        const retained_case = buildRetainedMalformedCase(artifact.identity.seed.value);
        return .{
            .trace_metadata = makeTraceMetadata(
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
    violations: ?[]const checker.Violation,
    checkpoint_digest: checker.CheckpointDigest,
    event_count: u32,

    fn toCheckResult(self: Evaluation) checker.CheckResult {
        if (self.violations) |violations| {
            return checker.CheckResult.fail(violations, self.checkpoint_digest);
        }
        return checker.CheckResult.pass(self.checkpoint_digest);
    }
};

const CaseCheck = struct {
    digest: u64,
    violations: ?[]const checker.Violation = null,
};

const GeneratedBytes = struct {
    bytes: [max_runtime_bytes]u8 = [_]u8{0} ** max_runtime_bytes,
    len: usize,
};

const EndianWidth = enum {
    u16,
    u32,
};

const EndianReadCase = struct {
    bytes: [max_runtime_bytes]u8,
    len: usize,
    offset: usize,
    order: static_bits.endian.Endian,
    width: EndianWidth,
};

const EndianWriteCase = struct {
    bytes: [max_runtime_bytes]u8,
    len: usize,
    offset: usize,
    order: static_bits.endian.Endian,
    width: EndianWidth,
    value: u32,
};

const BitReadCase = struct {
    bytes: [8]u8,
    len: usize,
    bit_pos: usize,
    bit_count: u8,
};

const RetainedMalformedCase = struct {
    bytes: [max_varint_bytes]u8 = [_]u8{0} ** max_varint_bytes,
    len: usize,
    label: []const u8,
    violations: []const checker.Violation,
    digest: u128,
};

fn expectNoFailureOrReplay(
    io: std.Io,
    dir: std.Io.Dir,
    summary: fuzz_runner.FuzzRunSummary,
) !void {
    if (summary.failed_case) |failed_case| {
        try std.testing.expect(failed_case.persisted_entry_name != null);

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
        try std.testing.expectEqual(replay_runner.ReplayOutcome.violation_reproduced, outcome);
        return error.TestUnexpectedResult;
    }
}

fn evaluateInvariantCase(seed_value: u64) Evaluation {
    var digest: u128 = seed_value;
    var event_count: u32 = 0;

    const uleb_check = validateUlebDecodeCase(seed_value ^ 0xA11CE_0001);
    event_count += 1;
    digest = foldDigest(digest, uleb_check.digest);
    if (uleb_check.violations) |violations| {
        return .{
            .violations = violations,
            .checkpoint_digest = checker.CheckpointDigest.init(digest),
            .event_count = event_count,
        };
    }

    const sleb_check = validateSlebDecodeCase(seed_value ^ 0xA11CE_0002);
    event_count += 1;
    digest = foldDigest(digest, sleb_check.digest);
    if (sleb_check.violations) |violations| {
        return .{
            .violations = violations,
            .checkpoint_digest = checker.CheckpointDigest.init(digest),
            .event_count = event_count,
        };
    }

    const endian_read_check = validateEndianReadCase(seed_value ^ 0xA11CE_0003);
    event_count += 1;
    digest = foldDigest(digest, endian_read_check.digest);
    if (endian_read_check.violations) |violations| {
        return .{
            .violations = violations,
            .checkpoint_digest = checker.CheckpointDigest.init(digest),
            .event_count = event_count,
        };
    }

    const endian_write_check = validateEndianWriteCase(seed_value ^ 0xA11CE_0004);
    event_count += 1;
    digest = foldDigest(digest, endian_write_check.digest);
    if (endian_write_check.violations) |violations| {
        return .{
            .violations = violations,
            .checkpoint_digest = checker.CheckpointDigest.init(digest),
            .event_count = event_count,
        };
    }

    const bit_reader_check = validateBitReaderCase(seed_value ^ 0xA11CE_0005);
    event_count += 1;
    digest = foldDigest(digest, bit_reader_check.digest);
    if (bit_reader_check.violations) |violations| {
        return .{
            .violations = violations,
            .checkpoint_digest = checker.CheckpointDigest.init(digest),
            .event_count = event_count,
        };
    }

    return .{
        .violations = null,
        .checkpoint_digest = checker.CheckpointDigest.init(digest),
        .event_count = event_count,
    };
}

fn validateUlebDecodeCase(seed_value: u64) CaseCheck {
    const generated = buildUlebBytes(seed_value);
    var reader = static_bits.cursor.ByteReader.init(generated.bytes[0..generated.len]);
    const digest = digestBytes(generated.bytes[0..generated.len]) ^ 0x554C4542;
    const direct = static_bits.varint.decodeUleb128(generated.bytes[0..generated.len]);

    if (direct) |decoded| {
        const value = static_bits.varint.readUleb128(&reader) catch {
            return .{
                .digest = digest,
                .violations = &uleb_violation,
            };
        };
        if (value != decoded.value) {
            return .{
                .digest = digest ^ value ^ decoded.value,
                .violations = &uleb_violation,
            };
        }
        if (reader.position() != decoded.bytes_read) {
            return .{
                .digest = digest ^ reader.position() ^ decoded.bytes_read,
                .violations = &uleb_violation,
            };
        }

        var encoded: [max_varint_bytes]u8 = undefined;
        const encoded_len = static_bits.varint.encodeUleb128(&encoded, decoded.value) catch unreachable;
        if (encoded_len != decoded.bytes_read) {
            return .{
                .digest = digest ^ encoded_len ^ decoded.bytes_read,
                .violations = &uleb_violation,
            };
        }
        if (!std.mem.eql(u8, encoded[0..encoded_len], generated.bytes[0..encoded_len])) {
            return .{
                .digest = digest ^ digestBytes(encoded[0..encoded_len]),
                .violations = &uleb_violation,
            };
        }
        return .{ .digest = digest ^ decoded.value };
    } else |direct_err| {
        const reader_position_before = reader.position();
        _ = static_bits.varint.readUleb128(&reader) catch |reader_err| {
            if (reader_err != direct_err) {
                return .{
                    .digest = digest ^ reader_position_before,
                    .violations = &uleb_violation,
                };
            }
            if (reader.position() != reader_position_before) {
                return .{
                    .digest = digest ^ reader.position(),
                    .violations = &uleb_violation,
                };
            }
            return .{ .digest = digest ^ 0x11 };
        };
        return .{
            .digest = digest,
            .violations = &uleb_violation,
        };
    }
}

fn validateSlebDecodeCase(seed_value: u64) CaseCheck {
    const generated = buildSlebBytes(seed_value);
    var reader = static_bits.cursor.ByteReader.init(generated.bytes[0..generated.len]);
    const digest = digestBytes(generated.bytes[0..generated.len]) ^ 0x534C4542;
    const direct = static_bits.varint.decodeSleb128(generated.bytes[0..generated.len]);

    if (direct) |decoded| {
        const value = static_bits.varint.readSleb128(&reader) catch {
            return .{
                .digest = digest,
                .violations = &sleb_violation,
            };
        };
        if (value != decoded.value) {
            return .{
                .digest = digest ^ @as(u64, @bitCast(value)) ^ @as(u64, @bitCast(decoded.value)),
                .violations = &sleb_violation,
            };
        }
        if (reader.position() != decoded.bytes_read) {
            return .{
                .digest = digest ^ reader.position() ^ decoded.bytes_read,
                .violations = &sleb_violation,
            };
        }

        var encoded: [max_varint_bytes]u8 = undefined;
        const encoded_len = static_bits.varint.encodeSleb128(&encoded, decoded.value) catch unreachable;
        if (encoded_len != decoded.bytes_read) {
            return .{
                .digest = digest ^ encoded_len ^ decoded.bytes_read,
                .violations = &sleb_violation,
            };
        }
        if (!std.mem.eql(u8, encoded[0..encoded_len], generated.bytes[0..encoded_len])) {
            return .{
                .digest = digest ^ digestBytes(encoded[0..encoded_len]),
                .violations = &sleb_violation,
            };
        }
        return .{
            .digest = digest ^ @as(u64, @bitCast(decoded.value)),
        };
    } else |direct_err| {
        const reader_position_before = reader.position();
        _ = static_bits.varint.readSleb128(&reader) catch |reader_err| {
            if (reader_err != direct_err) {
                return .{
                    .digest = digest ^ reader_position_before,
                    .violations = &sleb_violation,
                };
            }
            if (reader.position() != reader_position_before) {
                return .{
                    .digest = digest ^ reader.position(),
                    .violations = &sleb_violation,
                };
            }
            return .{ .digest = digest ^ 0x22 };
        };
        return .{
            .digest = digest,
            .violations = &sleb_violation,
        };
    }
}

fn validateEndianReadCase(seed_value: u64) CaseCheck {
    const case_data = buildEndianReadCase(seed_value);
    return switch (case_data.width) {
        .u16 => validateEndianReadCaseFor(u16, case_data.bytes[0..case_data.len], case_data.offset, case_data.order),
        .u32 => validateEndianReadCaseFor(u32, case_data.bytes[0..case_data.len], case_data.offset, case_data.order),
    };
}

fn validateEndianReadCaseFor(
    comptime T: type,
    bytes: []const u8,
    offset: usize,
    order: static_bits.endian.Endian,
) CaseCheck {
    var reader = static_bits.cursor.ByteReader.init(bytes);
    const digest = digestBytes(bytes) ^ offset ^ (@as(u64, @sizeOf(T)) << 32) ^ orderDigest(order);

    reader.setPosition(offset) catch |set_err| {
        if (set_err != error.EndOfStream) {
            return .{
                .digest = digest,
                .violations = &endian_read_violation,
            };
        }
        _ = readEndianDirect(T, bytes, offset, order) catch |direct_err| {
            if (direct_err != error.EndOfStream) {
                return .{
                    .digest = digest,
                    .violations = &endian_read_violation,
                };
            }
            if (reader.position() != 0) {
                return .{
                    .digest = digest ^ reader.position(),
                    .violations = &endian_read_violation,
                };
            }
            return .{ .digest = digest ^ 0x33 };
        };
        return .{
            .digest = digest,
            .violations = &endian_read_violation,
        };
    };

    const before = reader.position();
    const direct = readEndianDirect(T, bytes, offset, order);
    if (direct) |direct_value| {
        const cursor_value = readEndianCursor(T, &reader, order) catch {
            return .{
                .digest = digest,
                .violations = &endian_read_violation,
            };
        };
        if (cursor_value != direct_value) {
            return .{
                .digest = digest ^ @as(u64, cursor_value) ^ @as(u64, direct_value),
                .violations = &endian_read_violation,
            };
        }
        if (reader.position() != before + @sizeOf(T)) {
            return .{
                .digest = digest ^ reader.position(),
                .violations = &endian_read_violation,
            };
        }
        return .{
            .digest = digest ^ @as(u64, direct_value),
        };
    } else |direct_err| {
        _ = readEndianCursor(T, &reader, order) catch |reader_err| {
            if (reader_err != direct_err) {
                return .{
                    .digest = digest,
                    .violations = &endian_read_violation,
                };
            }
            if (reader.position() != before) {
                return .{
                    .digest = digest ^ reader.position(),
                    .violations = &endian_read_violation,
                };
            }
            return .{ .digest = digest ^ 0x44 };
        };
        return .{
            .digest = digest,
            .violations = &endian_read_violation,
        };
    }
}

fn validateEndianWriteCase(seed_value: u64) CaseCheck {
    const case_data = buildEndianWriteCase(seed_value);
    return switch (case_data.width) {
        .u16 => validateEndianWriteCaseFor(u16, case_data.bytes, case_data.len, case_data.offset, @truncate(case_data.value), case_data.order),
        .u32 => validateEndianWriteCaseFor(u32, case_data.bytes, case_data.len, case_data.offset, case_data.value, case_data.order),
    };
}

fn validateEndianWriteCaseFor(
    comptime T: type,
    initial: [max_runtime_bytes]u8,
    len: usize,
    offset: usize,
    value: T,
    order: static_bits.endian.Endian,
) CaseCheck {
    var direct_buffer = initial;
    var writer_buffer = initial;
    var writer = static_bits.cursor.ByteWriter.init(writer_buffer[0..len]);
    const digest = digestBytes(initial[0..len]) ^ offset ^ (@as(u64, @sizeOf(T)) << 40) ^ orderDigest(order);

    writer.setPosition(offset) catch |set_err| {
        if (set_err != error.NoSpaceLeft) {
            return .{
                .digest = digest,
                .violations = &endian_write_violation,
            };
        }
        _ = writeEndianDirect(T, direct_buffer[0..len], offset, value, order) catch |direct_err| {
            if (direct_err != error.NoSpaceLeft) {
                return .{
                    .digest = digest,
                    .violations = &endian_write_violation,
                };
            }
            if (!std.mem.eql(u8, direct_buffer[0..], writer_buffer[0..])) {
                return .{
                    .digest = digest ^ digestBytes(writer_buffer[0..len]),
                    .violations = &endian_write_violation,
                };
            }
            if (writer.position() != 0) {
                return .{
                    .digest = digest ^ writer.position(),
                    .violations = &endian_write_violation,
                };
            }
            return .{ .digest = digest ^ 0x55 };
        };
        return .{
            .digest = digest,
            .violations = &endian_write_violation,
        };
    };

    if (offset > 0) @memset(direct_buffer[0..offset], 0);
    const before = writer.position();
    const direct = writeEndianDirect(T, direct_buffer[0..len], offset, value, order);
    if (direct) |_| {
        writeEndianCursor(T, &writer, value, order) catch {
            return .{
                .digest = digest,
                .violations = &endian_write_violation,
            };
        };
        if (writer.position() != before + @sizeOf(T)) {
            return .{
                .digest = digest ^ writer.position(),
                .violations = &endian_write_violation,
            };
        }
        if (!std.mem.eql(u8, direct_buffer[0..], writer_buffer[0..])) {
            return .{
                .digest = digest ^ digestBytes(writer_buffer[0..len]),
                .violations = &endian_write_violation,
            };
        }
        return .{
            .digest = digest ^ @as(u64, value),
        };
    } else |direct_err| {
        _ = writeEndianCursor(T, &writer, value, order) catch |writer_err| {
            if (writer_err != direct_err) {
                return .{
                    .digest = digest,
                    .violations = &endian_write_violation,
                };
            }
            if (writer.position() != before) {
                return .{
                    .digest = digest ^ writer.position(),
                    .violations = &endian_write_violation,
                };
            }
            if (!std.mem.eql(u8, direct_buffer[0..], writer_buffer[0..])) {
                return .{
                    .digest = digest ^ digestBytes(writer_buffer[0..len]),
                    .violations = &endian_write_violation,
                };
            }
            return .{ .digest = digest ^ 0x66 };
        };
        return .{
            .digest = digest,
            .violations = &endian_write_violation,
        };
    }
}

fn validateBitReaderCase(seed_value: u64) CaseCheck {
    const case_data = buildBitReadCase(seed_value);
    var reader = static_bits.cursor.BitReader.init(case_data.bytes[0..case_data.len]);
    const total_bits = case_data.len * 8;
    const digest = digestBytes(case_data.bytes[0..case_data.len]) ^
        (@as(u64, case_data.bit_pos) << 8) ^
        (@as(u64, case_data.bit_count) << 32);

    reader.setPositionBits(case_data.bit_pos) catch |set_err| {
        if (set_err != error.EndOfStream) {
            return .{
                .digest = digest,
                .violations = &bit_reader_violation,
            };
        }
        return .{ .digest = digest ^ 0x77 };
    };

    const before = reader.positionBits();
    if (case_data.bit_pos + case_data.bit_count > total_bits) {
        _ = reader.readBits(u16, case_data.bit_count) catch |read_err| {
            if (read_err != error.EndOfStream) {
                return .{
                    .digest = digest,
                    .violations = &bit_reader_violation,
                };
            }
            if (reader.positionBits() != before) {
                return .{
                    .digest = digest ^ reader.positionBits(),
                    .violations = &bit_reader_violation,
                };
            }
            return .{ .digest = digest ^ 0x88 };
        };
        return .{
            .digest = digest,
            .violations = &bit_reader_violation,
        };
    }

    const expected = readBitsModel(case_data.bytes[0..case_data.len], case_data.bit_pos, case_data.bit_count);
    const actual = reader.readBits(u16, case_data.bit_count) catch {
        return .{
            .digest = digest,
            .violations = &bit_reader_violation,
        };
    };
    if (actual != expected) {
        return .{
            .digest = digest ^ actual ^ expected,
            .violations = &bit_reader_violation,
        };
    }
    if (reader.positionBits() != before + case_data.bit_count) {
        return .{
            .digest = digest ^ reader.positionBits(),
            .violations = &bit_reader_violation,
        };
    }
    return .{
        .digest = digest ^ actual,
    };
}

fn buildUlebBytes(seed_value: u64) GeneratedBytes {
    var generated = GeneratedBytes{ .len = 0 };
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x55E7_0001);
    const random = prng.random();

    switch (seed_value & 3) {
        0 => {
            const value = random.int(u64);
            const encoded_len = static_bits.varint.encodeUleb128(generated.bytes[0..max_varint_bytes], value) catch unreachable;
            generated.len = encoded_len;
            const trailing = @as(usize, @intCast(random.int(u32) % 3));
            var index: usize = 0;
            while (index < trailing and generated.len < generated.bytes.len) : (index += 1) {
                generated.bytes[generated.len] = @truncate(random.int(u32));
                generated.len += 1;
            }
        },
        1 => {
            var encoded: [max_varint_bytes]u8 = undefined;
            const encoded_len = static_bits.varint.encodeUleb128(&encoded, random.int(u64) | 0x80) catch unreachable;
            std.debug.assert(encoded_len >= 2);
            @memcpy(generated.bytes[0..encoded_len], encoded[0..encoded_len]);
            generated.len = encoded_len - 1;
        },
        2 => {
            const invalid_cases = [_][]const u8{
                &.{ 0x80, 0x00 },
                &.{ 0x81, 0x00 },
                &.{ 0xFF, 0x00 },
            };
            const selected = invalid_cases[@as(usize, @intCast((seed_value >> 2) % invalid_cases.len))];
            @memcpy(generated.bytes[0..selected.len], selected);
            generated.len = selected.len;
        },
        else => {
            @memset(generated.bytes[0..max_varint_bytes], 0x80);
            generated.len = max_varint_bytes;
        },
    }

    return generated;
}

fn buildSlebBytes(seed_value: u64) GeneratedBytes {
    var generated = GeneratedBytes{ .len = 0 };
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x53E7_0002);
    const random = prng.random();

    switch (seed_value & 3) {
        0 => {
            const value = random.int(i64);
            const encoded_len = static_bits.varint.encodeSleb128(generated.bytes[0..max_varint_bytes], value) catch unreachable;
            generated.len = encoded_len;
            const trailing = @as(usize, @intCast(random.int(u32) % 3));
            var index: usize = 0;
            while (index < trailing and generated.len < generated.bytes.len) : (index += 1) {
                generated.bytes[generated.len] = @truncate(random.int(u32));
                generated.len += 1;
            }
        },
        1 => {
            const multi_byte_values = [_]i64{
                128,
                -129,
                624485,
                -624485,
                std.math.maxInt(i32),
                std.math.minInt(i32),
            };
            const value = multi_byte_values[@as(usize, @intCast((seed_value >> 3) % multi_byte_values.len))];
            var encoded: [max_varint_bytes]u8 = undefined;
            const encoded_len = static_bits.varint.encodeSleb128(&encoded, value) catch unreachable;
            std.debug.assert(encoded_len >= 2);
            @memcpy(generated.bytes[0..encoded_len], encoded[0..encoded_len]);
            generated.len = encoded_len - 1;
        },
        2 => {
            const invalid_cases = [_][]const u8{
                &.{ 0x80, 0x00 },
                &.{ 0xFF, 0x7F },
            };
            const selected = invalid_cases[@as(usize, @intCast((seed_value >> 2) % invalid_cases.len))];
            @memcpy(generated.bytes[0..selected.len], selected);
            generated.len = selected.len;
        },
        else => {
            @memset(generated.bytes[0..max_varint_bytes], 0x80);
            generated.len = max_varint_bytes;
        },
    }

    return generated;
}

fn buildEndianReadCase(seed_value: u64) EndianReadCase {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0xEAD1_0003);
    const random = prng.random();

    var bytes: [max_runtime_bytes]u8 = undefined;
    for (&bytes) |*byte| {
        byte.* = @truncate(random.int(u32));
    }

    return .{
        .bytes = bytes,
        .len = @as(usize, @intCast(random.int(u32) % (max_runtime_bytes + 1))),
        .offset = @as(usize, @intCast(random.int(u32) % (max_runtime_bytes + 3))),
        .order = if (random.boolean()) .little else .big,
        .width = if ((seed_value & 1) == 0) .u16 else .u32,
    };
}

fn buildEndianWriteCase(seed_value: u64) EndianWriteCase {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0xEAD1_0004);
    const random = prng.random();

    var bytes: [max_runtime_bytes]u8 = undefined;
    for (&bytes) |*byte| {
        byte.* = @truncate(random.int(u32));
    }

    return .{
        .bytes = bytes,
        .len = @as(usize, @intCast(random.int(u32) % (max_runtime_bytes + 1))),
        .offset = @as(usize, @intCast(random.int(u32) % (max_runtime_bytes + 3))),
        .order = if (random.boolean()) .little else .big,
        .width = if ((seed_value & 1) == 0) .u16 else .u32,
        .value = random.int(u32),
    };
}

fn buildBitReadCase(seed_value: u64) BitReadCase {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0xB17_0005);
    const random = prng.random();

    var bytes: [8]u8 = undefined;
    for (&bytes) |*byte| {
        byte.* = @truncate(random.int(u32));
    }

    return .{
        .bytes = bytes,
        .len = @as(usize, @intCast(random.int(u32) % (bytes.len + 1))),
        .bit_pos = @as(usize, @intCast(random.int(u32) % ((bytes.len * 8) + 5))),
        .bit_count = @as(u8, @intCast(random.int(u32) % 17)),
    };
}

fn buildRetainedMalformedCase(seed_value: u64) RetainedMalformedCase {
    var retained = RetainedMalformedCase{
        .len = 0,
        .label = "",
        .violations = &retained_truncated_violation,
        .digest = 0,
    };

    switch (seed_value % 3) {
        0 => {
            const encoded_len = static_bits.varint.encodeUleb128(retained.bytes[0..max_varint_bytes], 624485) catch unreachable;
            std.debug.assert(encoded_len == 3);
            retained.len = encoded_len - 1;
            retained.label = "truncated_uleb";
            retained.violations = &retained_truncated_violation;
        },
        1 => {
            const selected = [_]u8{ 0xFF, 0x7F };
            @memcpy(retained.bytes[0..selected.len], &selected);
            retained.len = selected.len;
            retained.label = "noncanonical_sleb";
            retained.violations = &retained_noncanonical_violation;
        },
        else => {
            @memset(retained.bytes[0..max_varint_bytes], 0x80);
            retained.len = max_varint_bytes;
            retained.label = "nonterminating_uleb";
            retained.violations = &retained_nonterminating_violation;
        },
    }

    retained.digest = foldSeedDigest(seed_value, digestBytes(retained.bytes[0..retained.len]));
    return retained;
}

fn assertRetainedMalformedCase(retained_case: RetainedMalformedCase) !void {
    if (std.mem.eql(u8, retained_case.label, "truncated_uleb")) {
        try std.testing.expectError(
            error.EndOfStream,
            static_bits.varint.decodeUleb128(retained_case.bytes[0..retained_case.len]),
        );
        var reader = static_bits.cursor.ByteReader.init(retained_case.bytes[0..retained_case.len]);
        try std.testing.expectError(error.EndOfStream, static_bits.varint.readUleb128(&reader));
        try std.testing.expectEqual(@as(usize, 0), reader.position());
        return;
    }

    if (std.mem.eql(u8, retained_case.label, "noncanonical_sleb")) {
        try std.testing.expectError(
            error.InvalidEncoding,
            static_bits.varint.decodeSleb128(retained_case.bytes[0..retained_case.len]),
        );
        var reader = static_bits.cursor.ByteReader.init(retained_case.bytes[0..retained_case.len]);
        try std.testing.expectError(error.InvalidEncoding, static_bits.varint.readSleb128(&reader));
        try std.testing.expectEqual(@as(usize, 0), reader.position());
        return;
    }

    try std.testing.expectEqualStrings("nonterminating_uleb", retained_case.label);
    try std.testing.expectError(
        error.InvalidEncoding,
        static_bits.varint.decodeUleb128(retained_case.bytes[0..retained_case.len]),
    );
    var reader = static_bits.cursor.ByteReader.init(retained_case.bytes[0..retained_case.len]);
    try std.testing.expectError(error.InvalidEncoding, static_bits.varint.readUleb128(&reader));
    try std.testing.expectEqual(@as(usize, 0), reader.position());
}

fn makeTraceMetadata(
    run_identity: identity.RunIdentity,
    event_count: u32,
    checkpoint_value: u128,
) trace.TraceMetadata {
    const timestamp_base = run_identity.seed.value ^ @as(u64, @truncate(checkpoint_value));
    return .{
        .event_count = event_count,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 0,
        .last_sequence_no = event_count - 1,
        .first_timestamp_ns = timestamp_base,
        .last_timestamp_ns = timestamp_base + event_count,
    };
}

fn foldSeedDigest(seed: u64, value: u64) u128 {
    return @as(u128, mix64(seed ^ value));
}

fn foldDigest(acc: u128, value: u64) u128 {
    const upper = @as(u64, @truncate(acc >> 64));
    const lower = @as(u64, @truncate(acc));
    const mixed = mix64(upper ^ value);
    return (@as(u128, mixed) << 64) | (lower ^ value);
}

fn digestBytes(bytes: []const u8) u64 {
    var state: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes, 0..) |byte, index| {
        state ^= @as(u64, byte) | (@as(u64, @intCast(index)) << 32);
        state *%= 0x1000_0000_01b3;
    }
    return mix64(state ^ bytes.len);
}

fn mix64(value: u64) u64 {
    var mixed = value ^ (value >> 33);
    mixed *%= 0xff51_afd7_ed55_8ccd;
    mixed ^= mixed >> 33;
    mixed *%= 0xc4ce_b9fe_1a85_ec53;
    mixed ^= mixed >> 33;
    return mixed;
}

fn orderDigest(order: static_bits.endian.Endian) u64 {
    return switch (order) {
        .little => 0x6c69_7474_6c65,
        .big => 0x6269_6700_0000,
    };
}

fn readEndianDirect(
    comptime T: type,
    bytes: []const u8,
    offset: usize,
    order: static_bits.endian.Endian,
) static_bits.endian.ReadError!T {
    return switch (order) {
        .little => static_bits.endian.readInt(bytes, offset, T, .little),
        .big => static_bits.endian.readInt(bytes, offset, T, .big),
    };
}

fn writeEndianDirect(
    comptime T: type,
    bytes: []u8,
    offset: usize,
    value: T,
    order: static_bits.endian.Endian,
) static_bits.endian.WriteError!void {
    switch (order) {
        .little => try static_bits.endian.writeInt(bytes, offset, value, .little),
        .big => try static_bits.endian.writeInt(bytes, offset, value, .big),
    }
}

fn readEndianCursor(
    comptime T: type,
    reader: *static_bits.cursor.ByteReader,
    order: static_bits.endian.Endian,
) static_bits.cursor.ReaderError!T {
    return switch (order) {
        .little => reader.readInt(T, .little),
        .big => reader.readInt(T, .big),
    };
}

fn writeEndianCursor(
    comptime T: type,
    writer: *static_bits.cursor.ByteWriter,
    value: T,
    order: static_bits.endian.Endian,
) static_bits.cursor.WriterError!void {
    switch (order) {
        .little => try writer.writeInt(value, .little),
        .big => try writer.writeInt(value, .big),
    }
}

fn readBitsModel(bytes: []const u8, bit_pos: usize, bit_count: u8) u16 {
    var value: u16 = 0;
    var index: u8 = 0;
    while (index < bit_count) : (index += 1) {
        const absolute_bit = bit_pos + index;
        const byte_index = absolute_bit / 8;
        const bit_offset: u3 = @intCast(absolute_bit % 8);
        const bit = (bytes[byte_index] >> bit_offset) & 0x01;
        const shift: u4 = @intCast(index);
        value |= @as(u16, bit) << shift;
    }
    return value;
}
