//! Demonstrates deterministic corpus persistence and replay-artifact reload.

const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();
    const output_dir_path = ".zig-cache/static_testing/examples/corpus_roundtrip";
    try deleteTreeIfPresent(cwd, io, output_dir_path);

    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer cleanupOutputDir(cwd, io, output_dir_path);
    defer output_dir.close(io);

    const run_identity = testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "corpus_roundtrip",
        .seed = .{ .value = 2026 },
        .build_mode = .debug,
        .case_index = 2,
        .run_index = 7,
    });
    const trace_metadata: testing.testing.trace.TraceMetadata = .{
        .event_count = 2,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = 10,
        .last_sequence_no = 11,
        .first_timestamp_ns = 1_000,
        .last_timestamp_ns = 2_000,
    };

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    const written = try testing.testing.corpus.writeCorpusEntry(
        io,
        output_dir,
        .{ .prefix = "phase2_corpus_example" },
        &entry_name_buffer,
        &artifact_buffer,
        run_identity,
        trace_metadata,
    );

    var read_buffer: [256]u8 = undefined;
    const read_entry = try testing.testing.corpus.readCorpusEntry(
        io,
        output_dir,
        written.entry_name,
        &read_buffer,
    );

    std.debug.assert(written.identity_hash == read_entry.meta.identity_hash);
    std.debug.assert(std.mem.eql(u8, read_entry.meta.entry_name, written.entry_name));
    std.debug.assert(read_entry.artifact.trace_metadata.event_count == trace_metadata.event_count);
    std.debug.assert(read_entry.artifact.trace_metadata.last_sequence_no == trace_metadata.last_sequence_no);
    std.debug.print("corpus entry: {s}\n", .{written.entry_name});
}

fn deleteTreeIfPresent(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) !void {
    try dir.deleteTree(io, sub_path);
}

fn cleanupOutputDir(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) void {
    dir.deleteTree(io, sub_path) catch |err| {
        std.log.warn("Best-effort cleanupOutputDir failed for {s}: {s}.", .{
            sub_path,
            @errorName(err),
        });
    };
}
