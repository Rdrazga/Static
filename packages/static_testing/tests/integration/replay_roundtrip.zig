const std = @import("std");
const testing = @import("static_testing");

test "replay artifact round-trip survives a file boundary" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var trace_storage: [2]testing.testing.trace.TraceEvent = undefined;
    var trace_buffer = try testing.testing.trace.TraceBuffer.init(&trace_storage, .{
        .max_events = 2,
        .start_sequence_no = 10,
    });
    try trace_buffer.append(.{
        .timestamp_ns = 50,
        .category = .info,
        .label = "boot",
    });
    try trace_buffer.append(.{
        .timestamp_ns = 100,
        .category = .check,
        .label = "verify",
        .value = 9,
    });

    const run_identity = testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "integration_roundtrip",
        .seed = .{ .value = 88 },
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 2,
    });
    const trace_metadata = trace_buffer.snapshot().metadata();

    var artifact_bytes: [256]u8 = undefined;
    const bytes_written = try testing.testing.replay_artifact.encodeReplayArtifact(
        &artifact_bytes,
        run_identity,
        trace_metadata,
    );

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const file_name = "static_testing_replay_roundtrip.bin";

    try tmp_dir.dir.writeFile(io, .{
        .sub_path = file_name,
        .data = artifact_bytes[0..bytes_written],
    });

    var readback_bytes: [256]u8 = undefined;
    const readback_slice = try tmp_dir.dir.readFile(io, file_name, &readback_bytes);
    const artifact_view = try testing.testing.replay_artifact.decodeReplayArtifact(
        readback_slice,
    );

    try std.testing.expectEqualStrings(run_identity.package_name, artifact_view.identity.package_name);
    try std.testing.expectEqualStrings(run_identity.run_name, artifact_view.identity.run_name);
    try std.testing.expectEqual(run_identity.seed.value, artifact_view.identity.seed.value);
    try std.testing.expectEqual(trace_metadata.last_timestamp_ns, artifact_view.trace_metadata.last_timestamp_ns);
}

test "failure bundle round-trip coexists with replay artifact storage" {
    // Goal: Prove the richer failure bundle can share one persistence directory
    // with the older replay-artifact format without breaking deterministic
    // naming or readback.
    //
    // Method: Write one replay artifact and one failure bundle for the same run
    // identity under the same deterministic prefix, then read both back and
    // assert they preserve the same replay identity and trace metadata.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const run_identity = testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "bundle_roundtrip",
        .seed = .{ .value = 144 },
        .build_mode = .debug,
        .case_index = 2,
        .run_index = 4,
    });
    const trace_metadata: testing.testing.trace.TraceMetadata = .{
        .event_count = 3,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 20,
        .last_sequence_no = 22,
        .first_timestamp_ns = 1_000,
        .last_timestamp_ns = 1_400,
    };
    const violations = [_]testing.testing.checker.Violation{
        .{ .code = "mismatch", .message = "bundle replay mismatch" },
    };

    var corpus_entry_name_buffer: [128]u8 = undefined;
    var corpus_artifact_buffer: [256]u8 = undefined;
    const corpus_meta = try testing.testing.corpus.writeCorpusEntry(
        io,
        tmp_dir.dir,
        .{ .prefix = "shared_failure" },
        &corpus_entry_name_buffer,
        &corpus_artifact_buffer,
        run_identity,
        trace_metadata,
    );

    var bundle_entry_name_buffer: [128]u8 = undefined;
    var bundle_artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;
    const bundle_meta = try testing.testing.failure_bundle.writeFailureBundle(.{
        .io = io,
        .dir = tmp_dir.dir,
        .naming = .{
            .prefix = "shared_failure",
            .extension = ".bundle",
        },
        .entry_name_buffer = &bundle_entry_name_buffer,
        .artifact_buffer = &bundle_artifact_buffer,
        .manifest_buffer = &manifest_buffer,
        .trace_buffer = &trace_buffer,
        .violations_buffer = &violations_buffer,
    }, run_identity, trace_metadata, testing.testing.checker.CheckResult.fail(
        &violations,
        testing.testing.checker.CheckpointDigest.init(33),
    ), .{
        .campaign_profile = "stress",
        .scenario_variant_id = 9,
        .scenario_variant_label = "seeded_same_tick",
        .base_seed = .init(88),
        .seed_lineage_run_index = run_identity.run_index,
    });

    try std.testing.expect(!std.mem.eql(u8, corpus_meta.entry_name, bundle_meta.entry_name));
    try std.testing.expect(std.mem.endsWith(u8, corpus_meta.entry_name, ".bin"));
    try std.testing.expect(std.mem.endsWith(u8, bundle_meta.entry_name, ".bundle"));

    var corpus_read_buffer: [256]u8 = undefined;
    const corpus_entry = try testing.testing.corpus.readCorpusEntry(
        io,
        tmp_dir.dir,
        corpus_meta.entry_name,
        &corpus_read_buffer,
    );

    var bundle_read_artifact_buffer: [256]u8 = undefined;
    var bundle_read_manifest_buffer: [testing.testing.failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var bundle_read_manifest_parse_buffer: [testing.testing.failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var bundle_read_trace_buffer: [testing.testing.failure_bundle.recommended_trace_source_len]u8 = undefined;
    var bundle_read_trace_parse_buffer: [testing.testing.failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var bundle_read_violations_buffer: [testing.testing.failure_bundle.recommended_violations_source_len]u8 = undefined;
    var bundle_read_violations_parse_buffer: [testing.testing.failure_bundle.recommended_violations_parse_len]u8 = undefined;
    const bundle_entry = try testing.testing.failure_bundle.readFailureBundle(
        io,
        tmp_dir.dir,
        bundle_meta.entry_name,
        .{
            .artifact_buffer = &bundle_read_artifact_buffer,
            .manifest_buffer = &bundle_read_manifest_buffer,
            .manifest_parse_buffer = &bundle_read_manifest_parse_buffer,
            .trace_buffer = &bundle_read_trace_buffer,
            .trace_parse_buffer = &bundle_read_trace_parse_buffer,
            .violations_buffer = &bundle_read_violations_buffer,
            .violations_parse_buffer = &bundle_read_violations_parse_buffer,
        },
    );

    try std.testing.expectEqual(corpus_meta.identity_hash, bundle_meta.identity_hash);
    try std.testing.expectEqualStrings(run_identity.run_name, corpus_entry.artifact.identity.run_name);
    try std.testing.expectEqualStrings(run_identity.run_name, bundle_entry.replay_artifact_view.identity.run_name);
    try std.testing.expectEqual(trace_metadata.last_timestamp_ns, corpus_entry.artifact.trace_metadata.last_timestamp_ns);
    try std.testing.expectEqual(trace_metadata.last_timestamp_ns, bundle_entry.replay_artifact_view.trace_metadata.last_timestamp_ns);
    try std.testing.expectEqualStrings("stress", bundle_entry.manifest_document.campaign_profile.?);
    try std.testing.expectEqualStrings("mismatch", bundle_entry.violations_document.violations[0].code);
}
